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

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Collections;

import org.junit.Test;

public final class DmFileProviderSafTest {
    @Test
    public void listRootsIncludesPersistedSafRootPaths() {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:", "Documents", true)
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);

        String[] roots = provider.listRoots();

        assertEquals(5, roots.length);
        assertEquals("dm://saf-abc123/", roots[4]);
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
        assertEquals(5, response.getEntriesCount());
        FileEntry safRoot = response.getEntries(4);
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
        assertTrue(response.getNextPageToken().matches("v1:2:[0-9a-f]{16}"));
        assertEquals(2, response.getEntriesCount());
        assertTrue(response.getEntries(0).getPath().matches("dm://saf-abc123/doc/[0-9a-f]{16}"));
        assertEquals("Letter.txt", response.getEntries(0).getName());
        assertEquals(FileKind.FILE_KIND_FILE, response.getEntries(0).getKind());
        assertEquals(123, response.getEntries(0).getSizeBytes());
        assertFalse(response.getEntries(0).getCanWrite());
        assertTrue(response.getEntries(1).getPath().matches("dm://saf-abc123/doc/[0-9a-f]{16}"));
    }

    @Test
    public void safListingErrorDoesNotEchoProviderMessage() {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:", "Documents", false)
        );
        safCatalog.exception = new DmFileProvider.ProviderCatalogException(
                ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                "primary:Private/secret.txt: permission denied"
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath("dm://saf-abc123/")
                .build());

        assertTrue(response.hasError());
        assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, response.getError().getCode());
        assertEquals("SAF permission is required", response.getError().getMessage());
        assertFalse(response.getError().getMessage().contains("secret.txt"));
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
    public void safRootPathUploadsFreshFile() throws Exception {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:Docs", "Documents", true)
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);

        DmFileProvider.UploadWriter writer = provider.openUpload("dm://saf-abc123/payload.bin", 0, 6);
        writer.writeChunk(0, "abc".getBytes(StandardCharsets.UTF_8), false);
        writer.writeChunk(3, "def".getBytes(StandardCharsets.UTF_8), true);
        writer.close();

        assertEquals("primary:Docs", safCatalog.uploadParentDocumentId);
        assertEquals("payload.bin", safCatalog.uploadDisplayName);
        assertEquals(0, safCatalog.uploadOffsetBytes);
        assertEquals(6, safCatalog.uploadExpectedSizeBytes);
        assertEquals("abcdef", safCatalog.uploadedText());
    }

    @Test
    public void safUploadReceivesTransferIdForDurablePartialKey() throws Exception {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:Docs", "Documents", true)
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);

        DmFileProvider.UploadWriter writer = provider.openUpload(
                "dm://saf-abc123/payload.bin",
                "saf-transfer-1",
                0,
                4
        );
        writer.writeChunk(0, "data".getBytes(StandardCharsets.UTF_8), true);
        writer.close();

        assertEquals("saf-transfer-1", safCatalog.uploadTransferId);
        assertEquals("payload.bin", safCatalog.uploadDisplayName);
        assertEquals("data", safCatalog.uploadedText());
    }

    @Test
    public void safUploadResumeOffsetReachesCatalogWhenTransferIdIsPresent() throws Exception {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:Docs", "Documents", true)
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);

        DmFileProvider.UploadWriter writer = provider.openUpload(
                "dm://saf-abc123/payload.bin",
                "saf-transfer-2",
                3,
                6
        );
        assertEquals(3, writer.nextOffsetBytes());
        writer.writeChunk(3, "def".getBytes(StandardCharsets.UTF_8), true);
        writer.close();

        assertEquals("saf-transfer-2", safCatalog.uploadTransferId);
        assertEquals(3, safCatalog.uploadOffsetBytes);
        assertEquals(6, safCatalog.uploadExpectedSizeBytes);
        assertEquals("def", safCatalog.uploadedText());
    }

    @Test
    public void safDirectoryTokenPathUploadsFreshFileWithoutLeakingDocumentId() throws Exception {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:Docs", "Documents", true)
        );
        safCatalog.page = new DmFileProvider.SafPage(
                Collections.singletonList(new DmFileProvider.SafItem(
                        "primary:Docs/Subdir",
                        "Subdir",
                        FileKind.FILE_KIND_DIRECTORY,
                        0,
                        1_700_000_001_000L,
                        "vnd.android.document/directory",
                        true
                )),
                false
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);
        ListDirResponse listing = provider.listDir(ListDirRequest.newBuilder()
                .setPath("dm://saf-abc123/")
                .build());
        String directoryPath = listing.getEntries(0).getPath();

        DmFileProvider.UploadWriter writer = provider.openUpload(directoryPath + "/payload.txt", 0, 4);
        writer.writeChunk(0, "data".getBytes(StandardCharsets.UTF_8), true);
        writer.close();

        assertTrue(directoryPath.matches("dm://saf-abc123/doc/[0-9a-f]{16}"));
        assertFalse(directoryPath.contains("Subdir"));
        assertEquals("primary:Docs/Subdir", safCatalog.uploadParentDocumentId);
        assertEquals("payload.txt", safCatalog.uploadDisplayName);
        assertEquals("data", safCatalog.uploadedText());
    }

    @Test
    public void safUploadResumeRequiresTransferId() throws Exception {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:Docs", "Documents", true)
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);

        try {
            provider.openUpload("dm://saf-abc123/payload.bin", 1, 6);
            fail("expected SAF upload resume without transfer_id to be rejected");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, exception.code);
            assertEquals("SAF upload resume requires a transfer_id", exception.getMessage());
        }
    }

    @Test
    public void safUploadRejectsReadOnlyRoot() throws Exception {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:Docs", "Documents", false)
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);

        try {
            provider.openUpload("dm://saf-abc123/payload.bin", 0, 6);
            fail("expected read-only SAF upload to be rejected");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, exception.code);
        }
    }

    @Test
    public void safLogicalDocumentCacheEvictsOldestPathWhenBounded() {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:", "Documents", false)
        );
        safCatalog.page = new DmFileProvider.SafPage(
                Arrays.asList(
                        new DmFileProvider.SafItem(
                                "primary:Docs/A.txt",
                                "A.txt",
                                FileKind.FILE_KIND_FILE,
                                1,
                                1_700_000_001_000L,
                                "text/plain",
                                false
                        ),
                        new DmFileProvider.SafItem(
                                "primary:Docs/B.txt",
                                "B.txt",
                                FileKind.FILE_KIND_FILE,
                                1,
                                1_700_000_002_000L,
                                "text/plain",
                                false
                        ),
                        new DmFileProvider.SafItem(
                                "primary:Docs/C.txt",
                                "C.txt",
                                FileKind.FILE_KIND_FILE,
                                1,
                                1_700_000_003_000L,
                                "text/plain",
                                false
                        )
                ),
                false
        );
        DmFileProvider provider = new DmFileProvider(
                new FakeMediaCatalog(),
                safCatalog,
                DmFileProvider.AppSandboxCatalog.empty(),
                2
        );

        ListDirResponse listing = provider.listDir(ListDirRequest.newBuilder()
                .setPath("dm://saf-abc123/")
                .build());
        String evictedPath = listing.getEntries(0).getPath();
        String retainedPath = listing.getEntries(2).getPath();
        safCatalog.page = new DmFileProvider.SafPage(Collections.emptyList(), false);

        ListDirResponse evictedResponse = provider.listDir(ListDirRequest.newBuilder()
                .setPath(evictedPath)
                .build());
        ListDirResponse retainedResponse = provider.listDir(ListDirRequest.newBuilder()
                .setPath(retainedPath)
                .build());

        assertTrue(evictedResponse.hasError());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, evictedResponse.getError().getCode());
        assertFalse(retainedResponse.hasError());
        assertEquals("primary:Docs/C.txt", safCatalog.documentId);
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

}
