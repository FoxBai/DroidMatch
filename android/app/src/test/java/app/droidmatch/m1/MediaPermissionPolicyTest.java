package app.droidmatch.m1;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import android.Manifest;

import org.junit.Test;

public final class MediaPermissionPolicyTest {
    @Test
    public void requestPermissionsMatchApi32Api33AndApi34Boundaries() {
        assertArrayEquals(
                new String[] { Manifest.permission.READ_EXTERNAL_STORAGE },
                MediaPermissionPolicy.requestPermissions(26)
        );
        assertArrayEquals(
                new String[] { Manifest.permission.READ_EXTERNAL_STORAGE },
                MediaPermissionPolicy.requestPermissions(32)
        );
        assertArrayEquals(
                new String[] {
                        Manifest.permission.READ_MEDIA_IMAGES,
                        Manifest.permission.READ_MEDIA_VIDEO
                },
                MediaPermissionPolicy.requestPermissions(33)
        );
        assertArrayEquals(
                new String[] {
                        Manifest.permission.READ_MEDIA_IMAGES,
                        Manifest.permission.READ_MEDIA_VIDEO,
                        MediaPermissionPolicy.READ_MEDIA_VISUAL_USER_SELECTED
                },
                MediaPermissionPolicy.requestPermissions(34)
        );
        assertArrayEquals(
                MediaPermissionPolicy.requestPermissions(34),
                MediaPermissionPolicy.requestPermissions(35)
        );

        String[] expected = MediaPermissionPolicy.requestPermissions(34);
        assertFalse(MediaPermissionPolicy.permissionCallbackComplete(
                expected, new String[0], new int[0]
        ));
        assertFalse(MediaPermissionPolicy.permissionCallbackComplete(
                expected, expected, new int[0]
        ));
        assertTrue(MediaPermissionPolicy.permissionCallbackComplete(
                expected, expected, new int[] {0, -1, -1}
        ));
    }

    @Test
    public void rootPermissionMappingIsMediaSpecificAndFailsClosed() {
        assertEquals(
                Manifest.permission.READ_EXTERNAL_STORAGE,
                MediaPermissionPolicy.readPermission(32, DmFileProvider.RootKind.MEDIA_IMAGES)
        );
        assertEquals(
                Manifest.permission.READ_EXTERNAL_STORAGE,
                MediaPermissionPolicy.readPermission(32, DmFileProvider.RootKind.MEDIA_VIDEOS)
        );
        assertEquals(
                Manifest.permission.READ_MEDIA_IMAGES,
                MediaPermissionPolicy.readPermission(33, DmFileProvider.RootKind.MEDIA_IMAGES)
        );
        assertEquals(
                Manifest.permission.READ_MEDIA_IMAGES,
                MediaPermissionPolicy.readPermission(34, DmFileProvider.RootKind.MEDIA_IMAGE_ALBUMS)
        );
        assertEquals(
                Manifest.permission.READ_MEDIA_VIDEO,
                MediaPermissionPolicy.readPermission(33, DmFileProvider.RootKind.MEDIA_VIDEOS)
        );
        assertNull(MediaPermissionPolicy.readPermission(
                34,
                DmFileProvider.RootKind.APP_SANDBOX
        ));

        assertEquals(
                PermissionStateProvider.MediaReadAccess.DENIED,
                MediaPermissionPolicy.rootAccess(33, false, true)
        );
        assertEquals(
                PermissionStateProvider.MediaReadAccess.SELECTED,
                MediaPermissionPolicy.rootAccess(34, false, true)
        );
        assertEquals(
                PermissionStateProvider.MediaReadAccess.FULL,
                MediaPermissionPolicy.rootAccess(34, true, true)
        );
        assertFalse(MediaPermissionPolicy.canWriteMedia(28));
        assertTrue(MediaPermissionPolicy.canWriteMedia(29));
    }

    @Test
    public void librarySummaryKeepsPartialAccessDistinctFromFull() {
        assertAccess(
                PermissionStateProvider.MediaReadAccess.FULL,
                PermissionStateProvider.MediaReadAccess.FULL,
                MediaPermissionPolicy.LibraryAccess.FULL,
                MediaPermissionPolicy.ManagementAction.OPEN_APP_SETTINGS
        );
        assertAccess(
                PermissionStateProvider.MediaReadAccess.FULL,
                PermissionStateProvider.MediaReadAccess.DENIED,
                MediaPermissionPolicy.LibraryAccess.LIMITED,
                MediaPermissionPolicy.ManagementAction.REQUEST_PERMISSIONS
        );
        assertAccess(
                PermissionStateProvider.MediaReadAccess.SELECTED,
                PermissionStateProvider.MediaReadAccess.SELECTED,
                MediaPermissionPolicy.LibraryAccess.LIMITED,
                MediaPermissionPolicy.ManagementAction.REQUEST_PERMISSIONS
        );
        assertAccess(
                PermissionStateProvider.MediaReadAccess.DENIED,
                PermissionStateProvider.MediaReadAccess.DENIED,
                MediaPermissionPolicy.LibraryAccess.DENIED,
                MediaPermissionPolicy.ManagementAction.REQUEST_PERMISSIONS
        );
        assertEquals(
                MediaPermissionPolicy.AccessDetail.ALL_ITEMS,
                MediaPermissionPolicy.accessDetail(PermissionStateProvider.MediaReadAccess.FULL)
        );
        assertEquals(
                MediaPermissionPolicy.AccessDetail.SELECTED_ITEMS,
                MediaPermissionPolicy.accessDetail(PermissionStateProvider.MediaReadAccess.SELECTED)
        );
        assertEquals(
                MediaPermissionPolicy.AccessDetail.OFF,
                MediaPermissionPolicy.accessDetail(PermissionStateProvider.MediaReadAccess.DENIED)
        );

        assertFalse(MediaPermissionPolicy.shouldRecommendSettingsFallback(
                false, false, true, false
        ));
        assertFalse(MediaPermissionPolicy.shouldRecommendSettingsFallback(
                true, true, true, false
        ));
        assertFalse(MediaPermissionPolicy.shouldRecommendSettingsFallback(
                true, false, true, true
        ));
        assertTrue(MediaPermissionPolicy.shouldRecommendSettingsFallback(
                true, false, true, false
        ));
    }

    private static void assertAccess(
            PermissionStateProvider.MediaReadAccess imageAccess,
            PermissionStateProvider.MediaReadAccess videoAccess,
            MediaPermissionPolicy.LibraryAccess expectedAccess,
            MediaPermissionPolicy.ManagementAction expectedAction
    ) {
        MediaPermissionPolicy.LibraryAccess access = MediaPermissionPolicy.libraryAccess(
                imageAccess,
                videoAccess
        );
        assertEquals(expectedAccess, access);
        assertEquals(expectedAction, MediaPermissionPolicy.managementAction(access));
    }
}
