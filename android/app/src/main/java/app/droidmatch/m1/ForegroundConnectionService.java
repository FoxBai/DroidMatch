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

    private static final String CHANNEL_ID = "droidmatch_connection";
    private static final int NOTIFICATION_ID = 1001;

    private final Binder binder = new Binder();
    private DiagnosticsReporter diagnosticsReporter;
    private AdbEndpoint adbEndpoint;

    @Override
    public void onCreate() {
        super.onCreate();
        diagnosticsReporter = new DiagnosticsReporter();
        PermissionStateProvider permissionStateProvider = new PermissionStateProvider(this);
        AndroidDeviceInfoProvider deviceInfoProvider = new AndroidDeviceInfoProvider(this, permissionStateProvider);
        DmFileProvider fileProvider = new DmFileProvider(this, permissionStateProvider);
        AndroidPairingCredentialStore pairingCredentialStore = new AndroidPairingCredentialStore(this);
        PairingApprovalController pairingApprovals = ((DroidMatchApplication) getApplication())
                .pairingApprovalController();
        RpcDispatcher dispatcher = new RpcDispatcher(
                diagnosticsReporter,
                permissionStateProvider,
                fileProvider,
                deviceInfoProvider,
                // Ordinary M1 control sessions remain correlation-only until
                // rate-limit and real-device credential evidence are closed out.
                // The same dispatcher still admits UI-gated first-pairing RPCs.
                SessionAuthenticationMode.NONCE_ONLY,
                pairingCredentialStore,
                pairingCredentialStore,
                pairingApprovals,
                new AndroidDeviceIdentity()
        );
        adbEndpoint = new AdbEndpoint(dispatcher, diagnosticsReporter);
        startForeground(NOTIFICATION_ID, buildNotification());
        diagnosticsReporter.recordState("service.created");
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_START_ADB_ENDPOINT.equals(intent.getAction())) {
            int port = intent.getIntExtra(EXTRA_PORT, 0);
            adbEndpoint.start(port);
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
        if (adbEndpoint != null) {
            adbEndpoint.stop();
        }
        stopSelf(startId);
    }

    @Override
    public void onDestroy() {
        if (adbEndpoint != null) {
            adbEndpoint.shutdown();
        }
        if (diagnosticsReporter != null) {
            diagnosticsReporter.recordState("service.destroyed");
        }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
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
