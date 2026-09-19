package app.droidmatch.m1;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.net.Uri;
import android.provider.Settings;

/** Activity-owned gestures and dialogs; the runtime owns installation work. */
final class ActivityApkInstalls implements ActivityScreenApkInstalls.Actions {
    private final Activity activity;
    private final ApkInstallRuntime runtime;

    ActivityApkInstalls(Activity activity, ApkInstallRuntime runtime) {
        this.activity = activity;
        this.runtime = runtime;
    }

    @Override public void toggleIncoming() { runtime.toggleIncoming(); }
    @Override public void approve(String id) { runtime.approve(id); }
    @Override public void cancel(String id) { runtime.cancel(id); }
    @Override public void continueInstallation(String id) { runtime.continueOnAndroid(activity, id); }

    @Override public void sourceSettings() {
        try {
            activity.startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:" + activity.getPackageName())));
        } catch (RuntimeException unavailable) {
            new AlertDialog.Builder(activity).setMessage(R.string.apk_install_settings_unavailable)
                    .setPositiveButton(android.R.string.ok, null).show();
        }
    }

    @Override public void dismissUnknown(String id) {
        new AlertDialog.Builder(activity).setTitle(R.string.apk_install_unknown_title)
                .setMessage(R.string.apk_install_unknown_explanation)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.apk_install_acknowledge, (dialog, which) -> runtime.dismissUnknown(id))
                .show();
    }

    @Override public void cleanUntracked() {
        new AlertDialog.Builder(activity).setTitle(R.string.apk_install_cleanup_title)
                .setMessage(R.string.apk_install_cleanup_explanation)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.apk_install_cleanup, (dialog, which) -> runtime.cleanUntracked())
                .show();
    }
}
