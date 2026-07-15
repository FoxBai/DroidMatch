package app.droidmatch.m1;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;

public final class PermissionStateProvider {
    private static final String READ_MEDIA_VISUAL_USER_SELECTED =
            "android.permission.READ_MEDIA_VISUAL_USER_SELECTED";

    public enum PermissionState {
        GRANTED,
        DENIED,
        NEEDS_USER_ACTION,
        NOT_APPLICABLE
    }

    enum MediaReadAccess {
        FULL,
        SELECTED,
        DENIED
    }

    private final Context context;

    public PermissionStateProvider(Context context) {
        this.context = context.getApplicationContext();
    }

    public PermissionState publicMediaReadState() {
        if (Build.VERSION.SDK_INT >= 33) {
            boolean granted = context.checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED
                    || context.checkSelfPermission(Manifest.permission.READ_MEDIA_VIDEO) == PackageManager.PERMISSION_GRANTED
                    || hasSelectedVisualMediaAccess();
            return granted ? PermissionState.GRANTED : PermissionState.NEEDS_USER_ACTION;
        }

        boolean granted = context.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED;
        return granted ? PermissionState.GRANTED : PermissionState.NEEDS_USER_ACTION;
    }

    PermissionState publicMediaReadState(DmFileProvider.RootKind rootKind) {
        return publicMediaReadAccess(rootKind) == MediaReadAccess.DENIED
                ? PermissionState.NEEDS_USER_ACTION
                : PermissionState.GRANTED;
    }

    MediaReadAccess publicMediaReadAccess(DmFileProvider.RootKind rootKind) {
        if (Build.VERSION.SDK_INT < 33) {
            return context.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE)
                    == PackageManager.PERMISSION_GRANTED
                    ? MediaReadAccess.FULL
                    : MediaReadAccess.DENIED;
        }
        String permission = rootKind == DmFileProvider.RootKind.MEDIA_VIDEOS
                ? Manifest.permission.READ_MEDIA_VIDEO
                : Manifest.permission.READ_MEDIA_IMAGES;
        if (context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            return MediaReadAccess.FULL;
        }
        return hasSelectedVisualMediaAccess()
                ? MediaReadAccess.SELECTED
                : MediaReadAccess.DENIED;
    }

    public PermissionState notificationPostState() {
        if (Build.VERSION.SDK_INT < 33) {
            return PermissionState.NOT_APPLICABLE;
        }
        boolean granted = context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                == PackageManager.PERMISSION_GRANTED;
        return granted ? PermissionState.GRANTED : PermissionState.NEEDS_USER_ACTION;
    }

    public int persistedSafRootCount() {
        return context.getContentResolver().getPersistedUriPermissions().size();
    }

    private boolean hasSelectedVisualMediaAccess() {
        return Build.VERSION.SDK_INT >= 34
                && context.checkSelfPermission(READ_MEDIA_VISUAL_USER_SELECTED) == PackageManager.PERMISSION_GRANTED;
    }
}
