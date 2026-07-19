package app.droidmatch.m1;

import android.Manifest;
import android.annotation.SuppressLint;

import java.util.Arrays;

/** Pure API-level policy for product media permission state and user actions. */
final class MediaPermissionPolicy {
    static final String READ_MEDIA_VISUAL_USER_SELECTED =
            "android.permission.READ_MEDIA_VISUAL_USER_SELECTED";

    enum LibraryAccess {
        FULL,
        LIMITED,
        DENIED
    }

    enum AccessDetail {
        ALL_ITEMS,
        SELECTED_ITEMS,
        OFF
    }

    enum ManagementAction {
        REQUEST_PERMISSIONS,
        OPEN_APP_SETTINGS
    }

    private MediaPermissionPolicy() {
    }

    @SuppressLint("InlinedApi") // Permission names are inlined strings and SDK-gated below.
    static String[] requestPermissions(int sdkInt) {
        if (sdkInt >= 34) {
            return new String[] {
                    Manifest.permission.READ_MEDIA_IMAGES,
                    Manifest.permission.READ_MEDIA_VIDEO,
                    READ_MEDIA_VISUAL_USER_SELECTED
            };
        }
        if (sdkInt >= 33) {
            return new String[] {
                    Manifest.permission.READ_MEDIA_IMAGES,
                    Manifest.permission.READ_MEDIA_VIDEO
            };
        }
        return new String[] { Manifest.permission.READ_EXTERNAL_STORAGE };
    }

    @SuppressLint("InlinedApi") // Permission names are inlined strings and SDK-gated below.
    static String readPermission(int sdkInt, DmFileProvider.RootKind rootKind) {
        if (rootKind == null) {
            return null;
        }
        if (sdkInt < 33) {
            return isMediaRoot(rootKind)
                    ? Manifest.permission.READ_EXTERNAL_STORAGE
                    : null;
        }
        switch (rootKind) {
            case MEDIA_IMAGES:
            case MEDIA_IMAGE_ALBUMS:
                return Manifest.permission.READ_MEDIA_IMAGES;
            case MEDIA_VIDEOS:
                return Manifest.permission.READ_MEDIA_VIDEO;
            case APP_SANDBOX:
            default:
                return null;
        }
    }

    static PermissionStateProvider.MediaReadAccess rootAccess(
            int sdkInt,
            boolean rootPermissionGranted,
            boolean selectedPermissionGranted
    ) {
        if (rootPermissionGranted) {
            return PermissionStateProvider.MediaReadAccess.FULL;
        }
        return sdkInt >= 34 && selectedPermissionGranted
                ? PermissionStateProvider.MediaReadAccess.SELECTED
                : PermissionStateProvider.MediaReadAccess.DENIED;
    }

    static boolean canWriteMedia(int sdkInt) {
        // DroidMatch deliberately does not request legacy WRITE_EXTERNAL_STORAGE.
        // Scoped MediaStore inserts owned by this app are available from API 29.
        return sdkInt >= 29;
    }

    static LibraryAccess libraryAccess(
            PermissionStateProvider.MediaReadAccess imageAccess,
            PermissionStateProvider.MediaReadAccess videoAccess
    ) {
        if (imageAccess == PermissionStateProvider.MediaReadAccess.FULL
                && videoAccess == PermissionStateProvider.MediaReadAccess.FULL) {
            return LibraryAccess.FULL;
        }
        if (imageAccess == PermissionStateProvider.MediaReadAccess.DENIED
                && videoAccess == PermissionStateProvider.MediaReadAccess.DENIED) {
            return LibraryAccess.DENIED;
        }
        return LibraryAccess.LIMITED;
    }

    static AccessDetail accessDetail(PermissionStateProvider.MediaReadAccess access) {
        if (access == PermissionStateProvider.MediaReadAccess.FULL) {
            return AccessDetail.ALL_ITEMS;
        }
        if (access == PermissionStateProvider.MediaReadAccess.SELECTED) {
            return AccessDetail.SELECTED_ITEMS;
        }
        return AccessDetail.OFF;
    }

    static ManagementAction managementAction(LibraryAccess access) {
        return access == LibraryAccess.FULL
                ? ManagementAction.OPEN_APP_SETTINGS
                : ManagementAction.REQUEST_PERMISSIONS;
    }

    static boolean shouldRecommendSettingsFallback(
            boolean requestEstablished,
            boolean selectedAccessGranted,
            boolean hasDeniedBroadPermission,
            boolean anyDeniedPermissionShowsRationale
    ) {
        return requestEstablished
                && !selectedAccessGranted
                && hasDeniedBroadPermission
                && !anyDeniedPermissionShowsRationale;
    }

    static boolean permissionCallbackComplete(
            String[] expectedPermissions,
            String[] callbackPermissions,
            int[] grantResults
    ) {
        return expectedPermissions != null
                && expectedPermissions.length > 0
                && callbackPermissions != null
                && grantResults != null
                && Arrays.equals(expectedPermissions, callbackPermissions)
                && grantResults.length == expectedPermissions.length;
    }

    private static boolean isMediaRoot(DmFileProvider.RootKind rootKind) {
        return rootKind == DmFileProvider.RootKind.MEDIA_IMAGES
                || rootKind == DmFileProvider.RootKind.MEDIA_IMAGE_ALBUMS
                || rootKind == DmFileProvider.RootKind.MEDIA_VIDEOS;
    }
}
