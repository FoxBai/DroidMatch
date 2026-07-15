package app.droidmatch.m1;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;

/**
 * Executes only user-initiated media permission actions for the product Activity.
 *
 * <p>The permission state itself is never cached. Android 14 selected-media
 * access can change while the Activity is backgrounded, so callers must render
 * a fresh {@link PermissionStateProvider} result from {@code onResume()}.</p>
 */
final class MediaPermissionController {
    static final int REQUEST_MEDIA_READ = 1003;

    private final Activity activity;
    private final PermissionStateProvider permissionStateProvider;

    MediaPermissionController(
            Activity activity,
            PermissionStateProvider permissionStateProvider
    ) {
        this.activity = activity;
        this.permissionStateProvider = permissionStateProvider;
    }

    boolean manageAccess(boolean preferSettings) {
        MediaPermissionPolicy.LibraryAccess access =
                permissionStateProvider.publicMediaLibraryAccess();
        if (preferSettings || MediaPermissionPolicy.managementAction(access)
                == MediaPermissionPolicy.ManagementAction.OPEN_APP_SETTINGS) {
            return openAppSettings();
        }
        activity.requestPermissions(
                MediaPermissionPolicy.requestPermissions(Build.VERSION.SDK_INT),
                REQUEST_MEDIA_READ
        );
        return true;
    }

    boolean requestNeedsSettingsFallback(String[] permissions, int[] grantResults) {
        String[] expected = MediaPermissionPolicy.requestPermissions(Build.VERSION.SDK_INT);
        boolean callbackComplete = MediaPermissionPolicy.permissionCallbackComplete(
                expected,
                permissions,
                grantResults
        );
        return settingsFallbackAppropriate(callbackComplete);
    }

    boolean settingsFallbackStillAppropriate() {
        return settingsFallbackAppropriate(true);
    }

    private boolean settingsFallbackAppropriate(boolean requestEstablished) {
        String[] expected = MediaPermissionPolicy.requestPermissions(Build.VERSION.SDK_INT);
        boolean selectedAccessGranted = Build.VERSION.SDK_INT >= 34
                && activity.checkSelfPermission(
                        MediaPermissionPolicy.READ_MEDIA_VISUAL_USER_SELECTED
                ) == PackageManager.PERMISSION_GRANTED;
        boolean hasDeniedBroadPermission = false;
        boolean anyDeniedPermissionShowsRationale = false;
        for (String permission : expected) {
            if (MediaPermissionPolicy.READ_MEDIA_VISUAL_USER_SELECTED.equals(permission)) {
                continue;
            }
            if (activity.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
                hasDeniedBroadPermission = true;
                anyDeniedPermissionShowsRationale |=
                        activity.shouldShowRequestPermissionRationale(permission);
            }
        }
        return MediaPermissionPolicy.shouldRecommendSettingsFallback(
                requestEstablished,
                selectedAccessGranted,
                hasDeniedBroadPermission,
                anyDeniedPermissionShowsRationale
        );
    }

    boolean openAppSettings() {
        Intent intent = new Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", activity.getPackageName(), null)
        );
        try {
            activity.startActivity(intent);
            return true;
        } catch (ActivityNotFoundException | SecurityException exception) {
            // Some OEM builds omit or restrict this Settings activity. Keep the
            // product UI alive and let the Activity explain the unavailable action.
            return false;
        }
    }
}
