package app.droidmatch.m1;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.Binder;
import android.os.Build;
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
        DmFileProvider fileProvider = new DmFileProvider(this);
        RpcDispatcher dispatcher = new RpcDispatcher(
                diagnosticsReporter,
                permissionStateProvider,
                fileProvider,
                deviceInfoProvider
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
        return START_STICKY;
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

    @SuppressWarnings("deprecation")
    private Notification buildNotification() {
        PendingIntent diagnosticsIntent = PendingIntent.getActivity(
                this,
                0,
                new Intent(this, DiagnosticsActivity.class),
                PendingIntent.FLAG_IMMUTABLE
        );

        NotificationManager manager = getSystemService(NotificationManager.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager != null) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID,
                    "DroidMatch connection",
                    NotificationManager.IMPORTANCE_LOW
            );
            manager.createNotificationChannel(channel);
            return new Notification.Builder(this, CHANNEL_ID)
                    .setContentTitle("DroidMatch connection active")
                    .setContentText("USB harness endpoint is ready. Tap to add a folder.")
                    .setContentIntent(diagnosticsIntent)
                    .setSmallIcon(android.R.drawable.stat_sys_upload)
                    .build();
        }

        return new Notification.Builder(this)
                .setContentTitle("DroidMatch connection active")
                .setContentText("USB harness endpoint is ready. Tap to add a folder.")
                .setContentIntent(diagnosticsIntent)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .build();
    }
}
