package app.droidmatch.m1;

import android.app.Activity;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.view.WindowManager;
import android.widget.TextView;

public final class DebugHarnessActivity extends Activity {
    private static final int DEFAULT_ADB_ENDPOINT_PORT = 39001;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        int port = getIntent().getIntExtra(
                ForegroundConnectionService.EXTRA_PORT,
                DEFAULT_ADB_ENDPOINT_PORT
        );
        Intent serviceIntent = new Intent(this, ForegroundConnectionService.class)
                .setAction(ForegroundConnectionService.ACTION_START_ADB_ENDPOINT)
                .putExtra(ForegroundConnectionService.EXTRA_PORT, port);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent);
        } else {
            startService(serviceIntent);
        }

        TextView textView = new TextView(this);
        textView.setText("DroidMatch debug harness active on ADB endpoint port " + port);
        textView.setTextSize(18);
        textView.setPadding(48, 48, 48, 48);
        setContentView(textView);
    }
}
