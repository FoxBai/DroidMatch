package app.droidmatch.m1;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.os.Build;

final class NotificationPermissionRequester {
    static final int REQUEST_POST_NOTIFICATIONS = 1002;

    private NotificationPermissionRequester() {}

    static boolean requestIfNeeded(Activity activity) {
        if (Build.VERSION.SDK_INT < 33) {
            return false;
        }
        if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                == PackageManager.PERMISSION_GRANTED) {
            return false;
        }
        activity.requestPermissions(
                new String[] { Manifest.permission.POST_NOTIFICATIONS },
                REQUEST_POST_NOTIFICATIONS
        );
        return true;
    }
}
