package app.droidmatch.m1;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;

public final class PermissionStateProvider {
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
        return publicMediaLibraryAccess() == MediaPermissionPolicy.LibraryAccess.DENIED
                ? PermissionState.NEEDS_USER_ACTION
                : PermissionState.GRANTED;
    }

    PermissionState publicMediaReadState(DmFileProvider.RootKind rootKind) {
        return publicMediaReadAccess(rootKind) == MediaReadAccess.DENIED
                ? PermissionState.NEEDS_USER_ACTION
                : PermissionState.GRANTED;
    }

    MediaReadAccess publicMediaReadAccess(DmFileProvider.RootKind rootKind) {
        String permission = MediaPermissionPolicy.readPermission(
                Build.VERSION.SDK_INT,
                rootKind
        );
        if (permission == null) {
            return MediaReadAccess.DENIED;
        }
        boolean rootPermissionGranted = context.checkSelfPermission(permission)
                == PackageManager.PERMISSION_GRANTED;
        return MediaPermissionPolicy.rootAccess(
                Build.VERSION.SDK_INT,
                rootPermissionGranted,
                hasSelectedVisualMediaAccess()
        );
    }

    MediaPermissionPolicy.LibraryAccess publicMediaLibraryAccess() {
        return MediaPermissionPolicy.libraryAccess(
                publicMediaReadAccess(DmFileProvider.RootKind.MEDIA_IMAGES),
                publicMediaReadAccess(DmFileProvider.RootKind.MEDIA_VIDEOS)
        );
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
                && context.checkSelfPermission(MediaPermissionPolicy.READ_MEDIA_VISUAL_USER_SELECTED)
                == PackageManager.PERMISSION_GRANTED;
    }
}
