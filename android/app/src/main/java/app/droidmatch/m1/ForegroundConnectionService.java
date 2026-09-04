package app.droidmatch.m1;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.Binder;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;

public final class ForegroundConnectionService extends Service {
    public static final String ACTION_START_ADB_ENDPOINT = "app.droidmatch.m1.START_ADB_ENDPOINT";
    public static final String EXTRA_PORT = "port";
    public static final String EXTRA_SESSION_AUTHENTICATION_MODE = "session_authentication_mode";
    public static final int AUTHENTICATION_MODE_NONCE_ONLY = 0;
    public static final int AUTHENTICATION_MODE_PAIRED_REQUIRED = 1;
    public static final int DEFAULT_ADB_ENDPOINT_PORT = 39001;
    private static final long TRUST_MUTATION_SHUTDOWN_TIMEOUT_MILLIS = 1_500;

    private static final String CHANNEL_ID = "droidmatch_connection";
    private static final int NOTIFICATION_ID = 1001;

    private final Binder binder = new Binder();
    private DiagnosticsReporter diagnosticsReporter;
    private PermissionStateProvider permissionStateProvider;
    private AndroidDeviceInfoProvider deviceInfoProvider;
    private DmFileProvider fileProvider;
    private PairingCredentialRepository pairingCredentialStore;
    private PairingApprovalController pairingApprovals;
    private ConnectionStatusController connectionStatus;
    private ForegroundEndpointLifecycle endpointLifecycle;
    private Handler mainHandler;
    private AdbEndpoint adbEndpoint;
    private final EndpointDrain endpointDrain = new EndpointDrain();
    private boolean destroyed;
    private SessionAuthenticationMode currentAuthenticationMode;
    private int currentRequestedPort = -1;
    private ConnectionShutdownCoordinator shutdownCoordinator;
    private boolean preserveFailureStateOnDestroy;

    @Override
    public void onCreate() {
        super.onCreate();
        diagnosticsReporter = new DiagnosticsReporter();
        permissionStateProvider = new PermissionStateProvider(this);
        deviceInfoProvider = new AndroidDeviceInfoProvider(this, permissionStateProvider);
        fileProvider = new DmFileProvider(this, permissionStateProvider);
        pairingCredentialStore = ((DroidMatchApplication) getApplication())
                .pairingCredentialRepository();
        DroidMatchApplication application = (DroidMatchApplication) getApplication();
        pairingApprovals = application.pairingApprovalController();
        connectionStatus = application.connectionStatusController();
        shutdownCoordinator = application.connectionShutdownCoordinator();
        mainHandler = new Handler(Looper.getMainLooper());
        endpointLifecycle = new ForegroundEndpointLifecycle(
                connectionStatus,
                new ForegroundEndpointLifecycle.Actions() {
                    @Override
                    public void showNotification(
                            ForegroundEndpointLifecycle.NotificationState state
                    ) {
                        updateNotification(state);
                    }

                    @Override
                    public void stopAfterEndpointExit() {
                        ForegroundConnectionService.this.stopAfterEndpointExit();
                    }
                },
                action -> shutdownCoordinator.runIfRegistered(this, () -> {
                    if (!destroyed && !endpointDrain.blocksStart()) {
                        action.run();
                    }
                })
        );
        startForeground(
                NOTIFICATION_ID,
                buildNotification(R.string.foreground_service_starting_text)
        );
        try {
            shutdownCoordinator.register(this, this::retireEndpointAndAwaitClients);
        } catch (RuntimeException error) {
            // The old owner's pending drain remains authoritative. This instance
            // fulfilled the foreground launch contract but cannot admit a start.
            // 中文：旧 owner 的排空仍有权威性；新实例不能接受启动。
            endpointDrain.retire();
            diagnosticsReporter.recordError("adb.endpoint.owner_registration_failed", error);
            stopSelf();
            return;
        }
        diagnosticsReporter.recordState("service.created");
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_START_ADB_ENDPOINT.equals(intent.getAction())) {
            int port = intent.getIntExtra(EXTRA_PORT, DEFAULT_ADB_ENDPOINT_PORT);
            SessionAuthenticationMode authenticationMode = authenticationMode(intent);
            startEndpoint(port, authenticationMode);
        }
        // A killed connection must be re-established explicitly. START_STICKY can
        // recreate an idle foreground service without the endpoint-start intent,
        // wasting Android's dataSync foreground-service time budget.
        return START_NOT_STICKY;
    }

    @Override
    public void onTimeout(int startId, int fgsType) {
        // Android 15 limits background dataSync foreground services to six hours
        // per 24-hour window. Release the socket immediately, then stop within the
        // platform's grace period instead of waiting for normal process teardown.
        if (diagnosticsReporter != null) {
            diagnosticsReporter.recordState("service.timeout:data_sync:" + fgsType);
        }
        boolean currentOwner = retireEndpoint();
        if (currentOwner) {
            // This instance is terminal, so a newer queued start must not keep the
            // timed-out foreground service alive or reopen its listener.
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
        }
    }

    @Override
    public void onDestroy() {
        destroyed = true;
        try {
            retireEndpoint();
            try {
                endpointDrain.await(TRUST_MUTATION_SHUTDOWN_TIMEOUT_MILLIS);
            } catch (RuntimeException error) {
                if (diagnosticsReporter != null) {
                    diagnosticsReporter.recordError("adb.endpoint.destroy_drain_failed", error);
                }
            }
            if (diagnosticsReporter != null) {
                diagnosticsReporter.recordState("service.destroyed");
            }
        } finally {
            if (shutdownCoordinator != null && endpointDrain.drainComplete()) {
                shutdownCoordinator.unregister(this);
            }
            super.onDestroy();
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }

    private SessionAuthenticationMode authenticationMode(Intent intent) {
        int value = intent.getIntExtra(
                EXTRA_SESSION_AUTHENTICATION_MODE,
                AUTHENTICATION_MODE_PAIRED_REQUIRED
        );
        return value == AUTHENTICATION_MODE_NONCE_ONLY
                ? SessionAuthenticationMode.NONCE_ONLY
                : SessionAuthenticationMode.PAIRED_REQUIRED;
    }

    private void startEndpoint(int requestedPort, SessionAuthenticationMode authenticationMode) {
        if (shutdownCoordinator != null && !shutdownCoordinator.isRegistered(this)) {
            diagnosticsReporter.recordState("adb.endpoint.service_replaced");
            return;
        }
        if (endpointDrain.blocksStart()) {
            diagnosticsReporter.recordState("adb.endpoint.drain_pending");
            return;
        }
        ConnectionStatusController.Snapshot snapshot = connectionStatus.snapshot();
        if (adbEndpoint != null
                && currentRequestedPort == requestedPort
                && currentAuthenticationMode == authenticationMode
                && (snapshot.state() == ConnectionStatusController.State.STARTING
                || snapshot.state() == ConnectionStatusController.State.LISTENING)) {
            return;
        }

        preserveFailureStateOnDestroy = false;
        long generation = endpointLifecycle.begin(authenticationMode, requestedPort);
        AdbEndpoint previousEndpoint = adbEndpoint;
        adbEndpoint = null;
        if (previousEndpoint != null) {
            try {
                endpointDrain.begin(previousEndpoint);
                endpointDrain.await(TRUST_MUTATION_SHUTDOWN_TIMEOUT_MILLIS);
            } catch (RuntimeException error) {
                diagnosticsReporter.recordError("adb.endpoint.drain_failed", error);
                // Drain-pending callbacks are intentionally inadmissible; settle
                // this synchronous replacement failure before retiring the owner.
                // 中文：排空期间拒绝回调；同步替换失败需先记录再退役。
                connectionStatus.markFailed(generation);
                stopAfterEndpointExit();
                return;
            }
        }
        if (authenticationMode != SessionAuthenticationMode.PAIRED_REQUIRED) {
            pairingApprovals.closeWindow();
        }

        try {
            RpcDispatcher dispatcher = new RpcDispatcher(
                    diagnosticsReporter,
                    permissionStateProvider,
                    fileProvider,
                    deviceInfoProvider,
                    authenticationMode,
                    pairingCredentialStore,
                    pairingCredentialStore,
                    pairingApprovals,
                    new AndroidDeviceIdentity()
            );
            AdbEndpoint nextEndpoint = new AdbEndpoint(
                    dispatcher,
                    diagnosticsReporter,
                    new AdbEndpoint.LifecycleListener() {
                        @Override
                        public void onListening(int actualPort) {
                            mainHandler.post(
                                    () -> endpointLifecycle.onListening(generation, actualPort)
                            );
                        }

                        @Override
                        public void onFailed() {
                            mainHandler.post(() -> endpointLifecycle.onFailed(generation));
                        }

                        @Override
                        public void onStopped() {
                            mainHandler.post(() -> endpointLifecycle.onStopped(generation));
                        }
                    }
            );
            currentRequestedPort = requestedPort;
            currentAuthenticationMode = authenticationMode;
            adbEndpoint = nextEndpoint;
            diagnosticsReporter.recordState("adb.endpoint.mode:" + authenticationMode.name());
            nextEndpoint.start(requestedPort);
        } catch (RuntimeException error) {
            // Keep configuration/Keystore failures visible to the product surface
            // instead of leaving a permanent, misleading STARTING state.
            diagnosticsReporter.recordError("adb.endpoint.configuration_failed", error);
            endpointLifecycle.onFailed(generation);
        }
    }

    private boolean retireEndpoint() {
        endpointDrain.retire();
        boolean currentOwner = shutdownCoordinator != null
                && shutdownCoordinator.runIfRegistered(this, () -> {
                    if (!preserveFailureStateOnDestroy) {
                        connectionStatus.stop();
                    }
                    pairingApprovals.closeWindow();
                });
        stopLocalEndpoint();
        return currentOwner;
    }

    private void stopLocalEndpoint() {
        AdbEndpoint endpoint = adbEndpoint;
        adbEndpoint = null;
        currentRequestedPort = -1;
        currentAuthenticationMode = null;
        if (endpoint != null) {
            endpointDrain.begin(endpoint);
        }
    }

    private void retireEndpointAndAwaitClients() {
        retireEndpoint();
        endpointDrain.await(TRUST_MUTATION_SHUTDOWN_TIMEOUT_MILLIS);
        if (destroyed && shutdownCoordinator != null) {
            shutdownCoordinator.unregister(this);
        }
    }

    private void stopAfterEndpointExit() {
        shutdownCoordinator.runIfRegistered(this, () -> {
            preserveFailureStateOnDestroy = connectionStatus.snapshot().state()
                    == ConnectionStatusController.State.FAILED;
            retireEndpoint();
            stopForeground(STOP_FOREGROUND_REMOVE);
            // Retirement is permanent, including queued newer start commands.
            // 中文：本实例永久退役，排队中的新 start 也不能复活它。
            stopSelf();
        });
    }

    private void updateNotification(ForegroundEndpointLifecycle.NotificationState state) {
        int textResource = state == ForegroundEndpointLifecycle.NotificationState.READY
                ? R.string.foreground_service_ready_text
                : R.string.foreground_service_starting_text;
        // This is also the retry path after a failed endpoint removed its old
        // notification; startForeground is idempotent for an active service.
        startForeground(NOTIFICATION_ID, buildNotification(textResource));
    }

    private Notification buildNotification(int textResource) {
        PendingIntent diagnosticsIntent = PendingIntent.getActivity(
                this,
                0,
                new Intent(this, DroidMatchActivity.class),
                PendingIntent.FLAG_IMMUTABLE
        );

        NotificationManager manager = notificationManager();
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                getString(R.string.connection_channel_name),
                NotificationManager.IMPORTANCE_LOW
        );
        manager.createNotificationChannel(channel);
        return new Notification.Builder(this, CHANNEL_ID)
                .setContentTitle(getString(R.string.foreground_service_title))
                .setContentText(getString(textResource))
                .setContentIntent(diagnosticsIntent)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .build();
    }

    private NotificationManager notificationManager() {
        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager == null) {
            throw new IllegalStateException("NotificationManager is unavailable");
        }
        return manager;
    }
}
