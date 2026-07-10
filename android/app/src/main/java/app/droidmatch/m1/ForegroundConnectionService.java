package app.droidmatch.m1;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.Binder;
import android.os.IBinder;

public final class ForegroundConnectionService extends Service {
    public static final String ACTION_START_ADB_ENDPOINT = "app.droidmatch.m1.START_ADB_ENDPOINT";
    public static final String EXTRA_PORT = "port";
    public static final String EXTRA_SESSION_AUTHENTICATION_MODE = "session_authentication_mode";
    public static final int AUTHENTICATION_MODE_NONCE_ONLY = 0;
    public static final int AUTHENTICATION_MODE_PAIRED_REQUIRED = 1;
    public static final int DEFAULT_ADB_ENDPOINT_PORT = 39001;

    private static final String CHANNEL_ID = "droidmatch_connection";
    private static final int NOTIFICATION_ID = 1001;

    private final Binder binder = new Binder();
    private DiagnosticsReporter diagnosticsReporter;
    private PermissionStateProvider permissionStateProvider;
    private AndroidDeviceInfoProvider deviceInfoProvider;
    private DmFileProvider fileProvider;
    private AndroidPairingCredentialStore pairingCredentialStore;
    private PairingApprovalController pairingApprovals;
    private ConnectionStatusController connectionStatus;
    private AdbEndpoint adbEndpoint;
    private SessionAuthenticationMode currentAuthenticationMode;
    private int currentRequestedPort = -1;

    @Override
    public void onCreate() {
        super.onCreate();
        diagnosticsReporter = new DiagnosticsReporter();
        permissionStateProvider = new PermissionStateProvider(this);
        deviceInfoProvider = new AndroidDeviceInfoProvider(this, permissionStateProvider);
        fileProvider = new DmFileProvider(this, permissionStateProvider);
        pairingCredentialStore = new AndroidPairingCredentialStore(this);
        DroidMatchApplication application = (DroidMatchApplication) getApplication();
        pairingApprovals = application.pairingApprovalController();
        connectionStatus = application.connectionStatusController();
        startForeground(NOTIFICATION_ID, buildNotification());
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
        stopEndpoint();
        stopSelf(startId);
    }

    @Override
    public void onDestroy() {
        stopEndpoint();
        pairingApprovals.closeWindow();
        if (diagnosticsReporter != null) {
            diagnosticsReporter.recordState("service.destroyed");
        }
        super.onDestroy();
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
        ConnectionStatusController.Snapshot snapshot = connectionStatus.snapshot();
        if (adbEndpoint != null
                && currentRequestedPort == requestedPort
                && currentAuthenticationMode == authenticationMode
                && (snapshot.state() == ConnectionStatusController.State.STARTING
                || snapshot.state() == ConnectionStatusController.State.LISTENING)) {
            return;
        }

        long generation = connectionStatus.begin(authenticationMode, requestedPort);
        AdbEndpoint previousEndpoint = adbEndpoint;
        adbEndpoint = null;
        if (previousEndpoint != null) {
            previousEndpoint.shutdown();
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
                            connectionStatus.markListening(generation, actualPort);
                        }

                        @Override
                        public void onFailed() {
                            connectionStatus.markFailed(generation);
                        }

                        @Override
                        public void onStopped() {
                            connectionStatus.markStopped(generation);
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
            currentRequestedPort = -1;
            currentAuthenticationMode = null;
            adbEndpoint = null;
            connectionStatus.markFailed(generation);
            diagnosticsReporter.recordError("adb.endpoint.configuration_failed", error);
        }
    }

    private void stopEndpoint() {
        connectionStatus.stop();
        AdbEndpoint endpoint = adbEndpoint;
        adbEndpoint = null;
        currentRequestedPort = -1;
        currentAuthenticationMode = null;
        if (endpoint != null) {
            endpoint.shutdown();
        }
    }

    private Notification buildNotification() {
        PendingIntent diagnosticsIntent = PendingIntent.getActivity(
                this,
                0,
                new Intent(this, DiagnosticsActivity.class),
                PendingIntent.FLAG_IMMUTABLE
        );

        NotificationManager manager = getSystemService(NotificationManager.class);
        if (manager == null) {
            throw new IllegalStateException("NotificationManager is unavailable");
        }
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                getString(R.string.connection_channel_name),
                NotificationManager.IMPORTANCE_LOW
        );
        manager.createNotificationChannel(channel);
        return new Notification.Builder(this, CHANNEL_ID)
                .setContentTitle(getString(R.string.foreground_service_title))
                .setContentText(getString(R.string.foreground_service_text))
                .setContentIntent(diagnosticsIntent)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .build();
    }
}
