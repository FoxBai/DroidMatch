package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.FileEntry;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;
import app.droidmatch.proto.v1.SortField;

import java.util.Arrays;
import java.util.Collections;

import org.junit.Test;

public final class DmFileProviderTest {
    @Test
    public void rootsPathListsVirtualProviderRoots() {
        DmFileProvider provider = new DmFileProvider();

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .build());

        assertFalse(response.hasError());
        assertEquals(3, response.getEntriesCount());
        FileEntry first = response.getEntries(0);
        assertEquals("dm://media-images/", first.getPath());
        assertEquals("Images", first.getName());
        assertEquals(FileKind.FILE_KIND_VIRTUAL, first.getKind());
        assertTrue(first.getCanRead());
        for (FileEntry entry : response.getEntriesList()) {
            assertFalse(entry.getCanWrite());
        }
    }

    @Test
    public void pageTokensAreRejectedUntilPagingIsImplemented() {
        DmFileProvider provider = new DmFileProvider();

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .setPageToken("opaque")
                .build());

        assertTrue(response.hasError());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, response.getError().getCode());
    }

    @Test
    public void unknownPathsReturnNotFound() {
        DmFileProvider provider = new DmFileProvider();

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath("dm://does-not-exist/")
                .build());

        assertTrue(response.hasError());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, response.getError().getCode());
    }

    @Test
    public void mediaImageRootListsCatalogPage() {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.page = new DmFileProvider.MediaPage(
                Arrays.asList(
                        new DmFileProvider.MediaItem(42, "IMG_0042.jpg", 1024, 1_700_000_000_000L, "image/jpeg"),
                        new DmFileProvider.MediaItem(43, "IMG_0043.png", 2048, 1_700_000_001_000L, "image/png")
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
        assertEquals("2", response.getNextPageToken());
        assertEquals(2, response.getEntriesCount());
        FileEntry first = response.getEntries(0);
        assertEquals("dm://media-images/media/42", first.getPath());
        assertEquals("IMG_0042.jpg", first.getName());
        assertEquals(FileKind.FILE_KIND_FILE, first.getKind());
        assertEquals(1024, first.getSizeBytes());
        assertEquals(1_700_000_000_000L, first.getModifiedUnixMillis());
        assertEquals("image/jpeg", first.getMimeType());
        assertTrue(first.getCanRead());
        assertFalse(first.getCanWrite());
    }

    @Test
    public void mediaRootUsesPageTokenAndDefaultSort() {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.page = new DmFileProvider.MediaPage(Collections.emptyList(), false);
        DmFileProvider provider = new DmFileProvider(catalog);

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_VIDEOS_PATH)
                .setPageToken("200")
                .build());

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
    public void mediaCatalogPermissionErrorsFlowIntoListDirResponse() {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.exception = new DmFileProvider.MediaCatalogException(
                ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                "media permission is required"
        );
        DmFileProvider provider = new DmFileProvider(catalog);

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_IMAGES_PATH)
                .build());

        assertTrue(response.hasError());
        assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, response.getError().getCode());
    }

    @Test
    public void appSandboxRootIsEmptyUntilProviderIsImplemented() {
        DmFileProvider provider = new DmFileProvider();

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.APP_SANDBOX_PATH)
                .build());

        assertFalse(response.hasError());
        assertEquals(0, response.getEntriesCount());
    }

    private static final class FakeMediaCatalog implements DmFileProvider.MediaCatalog {
        private DmFileProvider.RootKind rootKind;
        private DmFileProvider.MediaQuery query;
        private DmFileProvider.MediaPage page = new DmFileProvider.MediaPage(Collections.emptyList(), false);
        private DmFileProvider.MediaCatalogException exception;

        @Override
        public DmFileProvider.MediaPage listMedia(
                DmFileProvider.RootKind rootKind,
                DmFileProvider.MediaQuery query
        ) throws DmFileProvider.MediaCatalogException {
            this.rootKind = rootKind;
            this.query = query;
            if (exception != null) {
                throw exception;
            }
            return page;
        }
    }
}
