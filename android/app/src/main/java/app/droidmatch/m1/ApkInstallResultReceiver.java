package app.droidmatch.m1;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Explicit, non-exported callback target; all identity checks live in the adapter. */
public final class ApkInstallResultReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        PendingResult pending = goAsync();
        try {
            ((DroidMatchApplication) context.getApplicationContext()).apkInstalls()
                    .receive(intent, pending::finish);
        } catch (RuntimeException unavailable) {
            pending.finish();
        }
    }
}
