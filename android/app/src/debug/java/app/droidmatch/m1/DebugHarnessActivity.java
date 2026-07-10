package app.droidmatch.m1;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.view.WindowManager;
import android.widget.TextView;

public final class DebugHarnessActivity extends Activity {
    private int endpointPort = ForegroundConnectionService.DEFAULT_ADB_ENDPOINT_PORT;
    private boolean endpointStarted;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        endpointPort = getIntent().getIntExtra(
                ForegroundConnectionService.EXTRA_PORT,
                ForegroundConnectionService.DEFAULT_ADB_ENDPOINT_PORT
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
                .putExtra(ForegroundConnectionService.EXTRA_PORT, endpointPort)
                // Debug/M1 evidence remains correlation-only. The product
                // DiagnosticsActivity explicitly requests paired authentication.
                .putExtra(
                        ForegroundConnectionService.EXTRA_SESSION_AUTHENTICATION_MODE,
                        ForegroundConnectionService.AUTHENTICATION_MODE_NONCE_ONLY
                );
        // DroidMatch's minSdk is API 26, so every supported device requires the
        // foreground-service start path for a background-capable endpoint.
        startForegroundService(serviceIntent);

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
