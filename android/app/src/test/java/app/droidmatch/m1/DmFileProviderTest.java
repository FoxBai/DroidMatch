package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.fail;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.FileEntry;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;
import app.droidmatch.proto.v1.SortField;
import app.droidmatch.proto.v1.ThumbnailRequest;
import app.droidmatch.proto.v1.ThumbnailResponse;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Collections;

import org.junit.Test;

public final class DmFileProviderTest {
    @Test
    public void thumbnailRoutesOpaqueMediaIdAndEnforcesDimensionBounds() {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        DmFileProvider provider = new DmFileProvider(catalog);

        ThumbnailResponse response = provider.thumbnail(ThumbnailRequest.newBuilder()
                .setPath("dm://media-images/media/42")
                .setMaxDimensionPx(128)
                .build());

        assertFalse(response.hasError());
        assertEquals(DmFileProvider.RootKind.MEDIA_IMAGES, catalog.readRootKind);
        assertEquals(42, catalog.mediaId);
        assertEquals(128, catalog.thumbnailDimension);
        assertEquals(3, response.getEncodedImage().size());
        assertEquals("image/jpeg", response.getMimeType());
        assertEquals(80, response.getWidthPx());
        assertEquals(60, response.getHeightPx());

        ThumbnailResponse invalid = provider.thumbnail(ThumbnailRequest.newBuilder()
                .setPath("dm://media-images/media/42")
                .setMaxDimensionPx(1024)
                .build());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, invalid.getError().getCode());

        ThumbnailResponse album = provider.thumbnail(ThumbnailRequest.newBuilder()
                .setPath("dm://media-images/albums/0123456789abcdef01234567/")
                .setMaxDimensionPx(128)
                .build());
        assertFalse(album.hasError());
        assertEquals("0123456789abcdef01234567", catalog.albumToken);
    }

    @Test
    public void thumbnailErrorDoesNotEchoProviderMessage() {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.exception = new DmFileProvider.ProviderCatalogException(
                ErrorCode.ERROR_CODE_NOT_FOUND,
                "content://media/external/images/private/secret.jpg is gone"
        );
        DmFileProvider provider = new DmFileProvider(catalog);

        ThumbnailResponse response = provider.thumbnail(ThumbnailRequest.newBuilder()
                .setPath("dm://media-images/media/42")
                .setMaxDimensionPx(128)
                .build());

        assertTrue(response.hasError());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, response.getError().getCode());
        assertEquals("media item is not available", response.getError().getMessage());
        assertFalse(response.getError().getMessage().contains("secret.jpg"));
        assertFalse(response.getError().getMessage().contains("content://"));
    }

    @Test
    public void rootsPathListsVirtualProviderRoots() {
        DmFileProvider provider = new DmFileProvider();

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .build());

        assertFalse(response.hasError());
        assertEquals(4, response.getEntriesCount());
        FileEntry first = response.getEntries(0);
        assertEquals("dm://media-images/", first.getPath());
        assertEquals("Images", first.getName());
        assertEquals(FileKind.FILE_KIND_VIRTUAL, first.getKind());
        assertFalse(first.getCanRead());
        assertFalse(first.getCanWrite());
        FileEntry albums = response.getEntries(1);
        assertEquals("dm://media-images/albums/", albums.getPath());
        assertEquals("Image Albums", albums.getName());
        FileEntry appSandbox = response.getEntries(3);
        assertEquals("dm://app-sandbox/", appSandbox.getPath());
        assertEquals("App Sandbox", appSandbox.getName());
        assertTrue(appSandbox.getCanRead());
        assertTrue(appSandbox.getCanWrite());
    }

    @Test
    public void rootsPathReflectsLiveImageAndVideoReadCapabilities() {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.canReadImages = false;
        catalog.canReadVideos = true;
        DmFileProvider provider = new DmFileProvider(catalog);

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .build());

        assertFalse(response.hasError());
        assertFalse(response.getEntries(0).getCanRead());
        assertFalse(response.getEntries(1).getCanRead());
        assertTrue(response.getEntries(2).getCanRead());
        assertTrue(response.getEntries(3).getCanRead());
    }

    @Test
    public void imageAlbumsListOpaqueDirectoriesAndCanonicalMediaItems() {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.albumPage = new ProviderAlbumPage(
                Collections.singletonList(new ProviderAlbum(
                        "0123456789abcdef01234567", "Camera", 1_700_000_000_000L, 20
                )),
                false
        );
        DmFileProvider provider = new DmFileProvider(catalog);

        ListDirResponse albums = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_IMAGE_ALBUMS_PATH)
                .build());
        assertFalse(albums.hasError());
        assertEquals("dm://media-images/albums/0123456789abcdef01234567/", albums.getEntries(0).getPath());
        assertEquals(FileKind.FILE_KIND_DIRECTORY, albums.getEntries(0).getKind());

        catalog.page = new DmFileProvider.MediaPage(
                Collections.singletonList(new DmFileProvider.MediaItem(
                        42, "IMG_0042.jpg", 1024, 1_700_000_000_000L, "image/jpeg", 0
                )),
                false
        );
        ListDirResponse media = provider.listDir(ListDirRequest.newBuilder()
                .setPath("dm://media-images/albums/0123456789abcdef01234567/")
                .build());
        assertFalse(media.hasError());
        assertEquals("0123456789abcdef01234567", catalog.albumToken);
        assertEquals("dm://media-images/media/42", media.getEntries(0).getPath());
    }

    @Test
    public void rootsPathAdvertisesWritableMediaWhenCatalogSupportsUpload() {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.canUploadMedia = true;
        DmFileProvider provider = new DmFileProvider(catalog);

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .build());

        assertFalse(response.hasError());
        assertTrue(response.getEntries(0).getCanWrite());
        assertFalse(response.getEntries(1).getCanWrite());
        assertTrue(response.getEntries(2).getCanWrite());
    }

    @Test
    public void malformedAlbumTokenIsRejectedBeforeCatalogLookup() {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        DmFileProvider provider = new DmFileProvider(catalog);

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath("dm://media-images/albums/not-a-token/")
                .build());

        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, response.getError().getCode());
        assertEquals(null, catalog.albumToken);
    }

    @Test
    public void rootListingUsesBoundedOpaquePagination() {
        DmFileProvider provider = new DmFileProvider();

        ListDirResponse first = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .setPageSize(2)
                .build());

        assertFalse(first.hasError());
        assertEquals(2, first.getEntriesCount());
        assertTrue(first.getNextPageToken().matches("v1:2:[0-9a-f]{16}"));

        ListDirResponse second = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .setPageSize(2)
                .setPageToken(first.getNextPageToken())
                .build());

        assertFalse(second.hasError());
        assertEquals(2, second.getEntriesCount());
        assertTrue(second.getNextPageToken().isEmpty());

        ListDirResponse invalid = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .setPageSize(2)
                .setPageToken("opaque")
                .build());
        assertTrue(invalid.hasError());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, invalid.getError().getCode());

        ListDirResponse ascending = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .setPageSize(4)
                .setSortField(SortField.SORT_FIELD_NAME)
                .build());
        assertEquals("App Sandbox", ascending.getEntries(0).getName());
        assertEquals("Image Albums", ascending.getEntries(1).getName());
        assertEquals("Images", ascending.getEntries(2).getName());
        assertEquals("Videos", ascending.getEntries(3).getName());

        ListDirResponse descending = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .setPageSize(4)
                .setSortField(SortField.SORT_FIELD_NAME)
                .setDescending(true)
                .build());
        assertEquals("Videos", descending.getEntries(0).getName());
        assertEquals("Images", descending.getEntries(1).getName());
        assertEquals("Image Albums", descending.getEntries(2).getName());
        assertEquals("App Sandbox", descending.getEntries(3).getName());
    }

    @Test
    public void unknownPathsReturnNotFound() {
        DmFileProvider provider = new DmFileProvider();

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath("dm://does-not-exist/private-report.txt")
                .build());

        assertTrue(response.hasError());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, response.getError().getCode());
        assertEquals("unknown DroidMatch provider path", response.getError().getMessage());
        assertFalse(response.getError().getMessage().contains("private-report.txt"));
    }

    @Test
    public void mediaImageRootListsCatalogPage() {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.page = new DmFileProvider.MediaPage(
                Arrays.asList(
                        new DmFileProvider.MediaItem(42, "IMG_0042.jpg", 1024, 1_700_000_000_000L, "image/jpeg", 999),
                        new DmFileProvider.MediaItem(43, "IMG_0043.png", 2048, 1_700_000_001_000L, "image/png", 0)
                ),
                true
        );
        DmFileProvider provider = new DmFileProvider(catalog);

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_IMAGES_PATH)
                .setPageSize(2)
                .setSortField(SortField.SORT_FIELD_NAME)
                .setDescending(false)
                .build());

        assertFalse(response.hasError());
        assertEquals(DmFileProvider.RootKind.MEDIA_IMAGES, catalog.rootKind);
        assertEquals(0, catalog.query.offset());
        assertEquals(2, catalog.query.limit());
        assertEquals(SortField.SORT_FIELD_NAME, catalog.query.sortField());
        assertFalse(catalog.query.descending());
        assertTrue(response.getNextPageToken().matches("v1:2:[0-9a-f]{16}"));
        assertEquals(2, response.getEntriesCount());
        FileEntry first = response.getEntries(0);
        assertEquals("dm://media-images/media/42", first.getPath());
        assertEquals("IMG_0042.jpg", first.getName());
        assertEquals(FileKind.FILE_KIND_FILE, first.getKind());
        assertEquals(1024, first.getSizeBytes());
        assertEquals(1_700_000_000_000L, first.getModifiedUnixMillis());
        assertEquals("image/jpeg", first.getMimeType());
        assertEquals(0L, first.getDurationMillis());
        assertTrue(first.getCanRead());
        assertFalse(first.getCanWrite());
    }

    @Test
    public void mediaRootUsesPageTokenAndDefaultSort() {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.page = new DmFileProvider.MediaPage(Arrays.asList(
                new DmFileProvider.MediaItem(
                        44, "VID_0044.mp4", 4096, 1_700_000_002_000L,
                        "video/mp4", 123_456
                ),
                new DmFileProvider.MediaItem(
                        45, "misclassified.jpg", 2048, 1_700_000_003_000L,
                        "image/jpeg", 654_321
                ),
                new DmFileProvider.MediaItem(
                        46, "malformed.mp4", 1024, 1_700_000_004_000L,
                        "video/mp4; charset=utf-8", 222_222
                ),
                new DmFileProvider.MediaItem(
                        47, "uppercase.mp4", 512, 1_700_000_005_000L,
                        "VIDEO/MP4", 333_333
                )
        ), true);
        DmFileProvider provider = new DmFileProvider(catalog);

        ListDirResponse firstPage = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_VIDEOS_PATH)
                .build());
        catalog.page = new DmFileProvider.MediaPage(Collections.emptyList(), false);
        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_VIDEOS_PATH)
                .setPageToken(firstPage.getNextPageToken())
                .build());

        assertFalse(firstPage.hasError());
        assertEquals(123_456L, firstPage.getEntries(0).getDurationMillis());
        assertEquals(0L, firstPage.getEntries(1).getDurationMillis());
        assertEquals(0L, firstPage.getEntries(2).getDurationMillis());
        assertEquals(333_333L, firstPage.getEntries(3).getDurationMillis());
        assertFalse(response.hasError());
        assertEquals(DmFileProvider.RootKind.MEDIA_VIDEOS, catalog.rootKind);
        assertEquals(200, catalog.query.offset());
        assertEquals(200, catalog.query.limit());
        assertEquals(SortField.SORT_FIELD_MODIFIED_TIME, catalog.query.sortField());
        assertTrue(catalog.query.descending());
        assertEquals("", response.getNextPageToken());
    }

    @Test
    public void mediaPageSizeIsCappedAsUnsignedUint32() {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.page = new DmFileProvider.MediaPage(Collections.emptyList(), false);
        DmFileProvider provider = new DmFileProvider(catalog);

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_IMAGES_PATH)
                .setPageSize(-1)
                .build());

        assertFalse(response.hasError());
        assertEquals(1_000, catalog.query.limit());
    }

    @Test
    public void invalidMediaPageTokenIsRejected() {
        DmFileProvider provider = new DmFileProvider();

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_IMAGES_PATH)
                .setPageToken("not-an-offset")
                .build());

        assertTrue(response.hasError());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, response.getError().getCode());
    }

    @Test
    public void mediaPageTokenIsRejectedWhenQueryChanges() {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.page = new DmFileProvider.MediaPage(Collections.emptyList(), true);
        DmFileProvider provider = new DmFileProvider(catalog);

        ListDirResponse firstPage = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_IMAGES_PATH)
                .setPageSize(2)
                .setSortField(SortField.SORT_FIELD_NAME)
                .build());
        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_IMAGES_PATH)
                .setPageSize(3)
                .setSortField(SortField.SORT_FIELD_NAME)
                .setPageToken(firstPage.getNextPageToken())
                .build());

        assertFalse(firstPage.hasError());
        assertTrue(response.hasError());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, response.getError().getCode());
    }

    @Test
    public void mediaCatalogPermissionErrorsFlowIntoListDirResponse() {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.exception = new DmFileProvider.ProviderCatalogException(
                ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                "private-report.txt: media permission is required"
        );
        DmFileProvider provider = new DmFileProvider(catalog);

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_IMAGES_PATH)
                .build());

        assertTrue(response.hasError());
        assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, response.getError().getCode());
        assertEquals("media permission is required", response.getError().getMessage());
        assertFalse(response.getError().getMessage().contains("private-report.txt"));
    }

}
