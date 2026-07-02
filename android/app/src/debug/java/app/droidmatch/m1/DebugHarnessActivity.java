package app.droidmatch.m1;

import android.app.Activity;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.view.WindowManager;
import android.widget.TextView;

public final class DebugHarnessActivity extends Activity {
    private static final int DEFAULT_ADB_ENDPOINT_PORT = 39001;

    private int endpointPort = DEFAULT_ADB_ENDPOINT_PORT;
    private boolean endpointStarted;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        endpointPort = getIntent().getIntExtra(
                ForegroundConnectionService.EXTRA_PORT,
                DEFAULT_ADB_ENDPOINT_PORT
        );
        if (NotificationPermissionRequester.requestIfNeeded(this)) {
            showStatus("DroidMatch debug harness waiting for notification permission");
            return;
        }
        startEndpoint();
    }

    private void startEndpoint() {
        if (endpointStarted) {
            return;
        }
        endpointStarted = true;
        Intent serviceIntent = new Intent(this, ForegroundConnectionService.class)
                .setAction(ForegroundConnectionService.ACTION_START_ADB_ENDPOINT)
                .putExtra(ForegroundConnectionService.EXTRA_PORT, endpointPort);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent);
        } else {
            startService(serviceIntent);
        }

        showStatus("DroidMatch debug harness active on ADB endpoint port " + endpointPort);
    }

    private void showStatus(String message) {
        TextView textView = new TextView(this);
        textView.setText(message);
        textView.setTextSize(18);
        textView.setPadding(48, 48, 48, 48);
        setContentView(textView);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == NotificationPermissionRequester.REQUEST_POST_NOTIFICATIONS) {
            startEndpoint();
        }
    }
}
