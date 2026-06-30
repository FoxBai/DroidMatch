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

import java.nio.charset.StandardCharsets;
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
        catalog.exception = new DmFileProvider.ProviderCatalogException(
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

    @Test
    public void mediaFilePathReadsDownloadChunk() throws Exception {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.downloadChunk = new DmFileProvider.DownloadChunk(
                "hello".getBytes(StandardCharsets.UTF_8),
                5,
                1_700_000_000_000L,
                "media-etag",
                true
        );
        DmFileProvider provider = new DmFileProvider(catalog);

        DmFileProvider.DownloadChunk chunk = provider.readDownloadChunk(
                "dm://media-images/media/42",
                1,
                4
        );

        assertEquals(DmFileProvider.RootKind.MEDIA_IMAGES, catalog.readRootKind);
        assertEquals(42, catalog.mediaId);
        assertEquals(1, catalog.readOffsetBytes);
        assertEquals(4, catalog.readChunkSizeBytes);
        assertEquals("hello", new String(chunk.data, StandardCharsets.UTF_8));
        assertTrue(chunk.finalChunk);
    }

    @Test
    public void listRootsIncludesPersistedSafRootPaths() {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:", "Documents", true)
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);

        String[] roots = provider.listRoots();

        assertEquals(4, roots.length);
        assertEquals("dm://saf-abc123/", roots[3]);
    }

    @Test
    public void rootsPathListsPersistedSafRoots() {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:", "Documents", true)
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .build());

        assertFalse(response.hasError());
        assertEquals(4, response.getEntriesCount());
        FileEntry safRoot = response.getEntries(3);
        assertEquals("dm://saf-abc123/", safRoot.getPath());
        assertEquals("Documents", safRoot.getName());
        assertEquals(FileKind.FILE_KIND_VIRTUAL, safRoot.getKind());
        assertTrue(safRoot.getCanRead());
        assertTrue(safRoot.getCanWrite());
    }

    @Test
    public void safRootListsChildrenWithEncodedDocumentPaths() {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:", "Documents", false)
        );
        safCatalog.page = new DmFileProvider.SafPage(
                Arrays.asList(
                        new DmFileProvider.SafItem(
                                "primary:Docs/Letter.txt",
                                "Letter.txt",
                                FileKind.FILE_KIND_FILE,
                                123,
                                1_700_000_000_000L,
                                "text/plain",
                                false
                        ),
                        new DmFileProvider.SafItem(
                                "primary:Docs/Subdir",
                                "Subdir",
                                FileKind.FILE_KIND_DIRECTORY,
                                0,
                                1_700_000_001_000L,
                                "vnd.android.document/directory",
                                false
                        )
                ),
                true
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath("dm://saf-abc123/")
                .setPageSize(2)
                .setSortField(SortField.SORT_FIELD_NAME)
                .setDescending(false)
                .build());

        assertFalse(response.hasError());
        assertEquals("primary:", safCatalog.documentId);
        assertEquals(0, safCatalog.query.offset());
        assertEquals(2, safCatalog.query.limit());
        assertEquals(SortField.SORT_FIELD_NAME, safCatalog.query.sortField());
        assertFalse(safCatalog.query.descending());
        assertEquals("2", response.getNextPageToken());
        assertEquals(2, response.getEntriesCount());
        assertTrue(response.getEntries(0).getPath().matches("dm://saf-abc123/doc/[0-9a-f]{16}"));
        assertEquals("Letter.txt", response.getEntries(0).getName());
        assertEquals(FileKind.FILE_KIND_FILE, response.getEntries(0).getKind());
        assertEquals(123, response.getEntries(0).getSizeBytes());
        assertFalse(response.getEntries(0).getCanWrite());
        assertTrue(response.getEntries(1).getPath().matches("dm://saf-abc123/doc/[0-9a-f]{16}"));
    }

    @Test
    public void safChildPathDecodesDocumentIdForNestedListing() {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:", "Documents", false)
        );
        safCatalog.page = new DmFileProvider.SafPage(
                Collections.singletonList(new DmFileProvider.SafItem(
                        "primary:Docs/Subdir",
                        "Subdir",
                        FileKind.FILE_KIND_DIRECTORY,
                        0,
                        1_700_000_001_000L,
                        "vnd.android.document/directory",
                        false
                )),
                false
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);

        ListDirResponse rootResponse = provider.listDir(ListDirRequest.newBuilder()
                .setPath("dm://saf-abc123/")
                .build());
        String childPath = rootResponse.getEntries(0).getPath();

        ListDirResponse childResponse = provider.listDir(ListDirRequest.newBuilder()
                .setPath(childPath)
                .build());

        assertFalse(childResponse.hasError());
        assertEquals("primary:Docs/Subdir", safCatalog.documentId);
    }

    @Test
    public void safListedFilePathReadsDownloadChunkWithoutLeakingDocumentId() throws Exception {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:", "Documents", false)
        );
        safCatalog.page = new DmFileProvider.SafPage(
                Collections.singletonList(new DmFileProvider.SafItem(
                        "primary:Docs/Letter.txt",
                        "Letter.txt",
                        FileKind.FILE_KIND_FILE,
                        5,
                        1_700_000_001_000L,
                        "text/plain",
                        false
                )),
                false
        );
        safCatalog.downloadChunk = new DmFileProvider.DownloadChunk(
                "world".getBytes(StandardCharsets.UTF_8),
                5,
                1_700_000_001_000L,
                "saf-etag",
                true
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);
        ListDirResponse listing = provider.listDir(ListDirRequest.newBuilder()
                .setPath("dm://saf-abc123/")
                .build());
        String logicalPath = listing.getEntries(0).getPath();

        DmFileProvider.DownloadChunk chunk = provider.readDownloadChunk(logicalPath, 0, 5);

        assertTrue(logicalPath.matches("dm://saf-abc123/doc/[0-9a-f]{16}"));
        assertFalse(logicalPath.contains("Letter"));
        assertEquals("primary:Docs/Letter.txt", safCatalog.readDocumentId);
        assertEquals("world", new String(chunk.data, StandardCharsets.UTF_8));
    }

    @Test
    public void malformedSafPathsAreRejected() {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:", "Documents", false)
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath("dm://saf-abc123/not-doc/primary%3ADocs")
                .build());

        assertTrue(response.hasError());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, response.getError().getCode());
    }

    private static final class FakeMediaCatalog implements DmFileProvider.MediaCatalog {
        private DmFileProvider.RootKind rootKind;
        private DmFileProvider.ProviderQuery query;
        private DmFileProvider.MediaPage page = new DmFileProvider.MediaPage(Collections.emptyList(), false);
        private DmFileProvider.ProviderCatalogException exception;
        private DmFileProvider.RootKind readRootKind;
        private long mediaId;
        private long readOffsetBytes;
        private int readChunkSizeBytes;
        private DmFileProvider.DownloadChunk downloadChunk = new DmFileProvider.DownloadChunk(
                new byte[0],
                0,
                0,
                "",
                true
        );

        @Override
        public DmFileProvider.MediaPage listMedia(
                DmFileProvider.RootKind rootKind,
                DmFileProvider.ProviderQuery query
        ) throws DmFileProvider.ProviderCatalogException {
            this.rootKind = rootKind;
            this.query = query;
            if (exception != null) {
                throw exception;
            }
            return page;
        }

        @Override
        public DmFileProvider.DownloadChunk readMedia(
                DmFileProvider.RootKind rootKind,
                long mediaId,
                long offsetBytes,
                int chunkSizeBytes
        ) throws DmFileProvider.ProviderCatalogException {
            this.readRootKind = rootKind;
            this.mediaId = mediaId;
            this.readOffsetBytes = offsetBytes;
            this.readChunkSizeBytes = chunkSizeBytes;
            if (exception != null) {
                throw exception;
            }
            return downloadChunk;
        }
    }

    private static final class FakeSafCatalog implements DmFileProvider.SafCatalog {
        private final DmFileProvider.SafRoot root;
        private String documentId;
        private String readDocumentId;
        private DmFileProvider.ProviderQuery query;
        private DmFileProvider.SafPage page = new DmFileProvider.SafPage(Collections.emptyList(), false);
        private DmFileProvider.DownloadChunk downloadChunk = new DmFileProvider.DownloadChunk(
                new byte[0],
                0,
                0,
                "",
                true
        );

        private FakeSafCatalog(DmFileProvider.SafRoot root) {
            this.root = root;
        }

        @Override
        public java.util.List<DmFileProvider.SafRoot> roots() {
            return Collections.singletonList(root);
        }

        @Override
        public DmFileProvider.SafPage listChildren(
                DmFileProvider.SafRoot root,
                String documentId,
                DmFileProvider.ProviderQuery query
        ) {
            this.documentId = documentId;
            this.query = query;
            return page;
        }

        @Override
        public DmFileProvider.DownloadChunk readDocument(
                DmFileProvider.SafRoot root,
                String documentId,
                long offsetBytes,
                int chunkSizeBytes
        ) {
            this.readDocumentId = documentId;
            return downloadChunk;
        }
    }
}
