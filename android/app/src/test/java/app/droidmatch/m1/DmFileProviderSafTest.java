package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.fail;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.FileEntry;
import app.droidmatch.proto.v1.FileMutationResponse;
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
        DmFileProvider.SafRoot firstRoot = new DmFileProvider.SafRoot(
                "abc123", "primary:", "Documents", true
        );
        DmFileProvider.SafRoot secondRoot = new DmFileProvider.SafRoot(
                "def456", "secondary:", "Documents", false
        );
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                firstRoot,
                secondRoot
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);

        ListDirResponse first = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .setPageSize(5)
                .build());

        assertFalse(first.hasError());
        assertEquals(5, first.getEntriesCount());
        assertEquals("dm://saf-abc123/", first.getEntries(4).getPath());
        assertTrue(first.getNextPageToken().matches("v1:5:[0-9a-f]{16}"));

        ListDirResponse second = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .setPageSize(5)
                .setPageToken(first.getNextPageToken())
                .build());

        assertFalse(second.hasError());
        assertEquals(1, second.getEntriesCount());
        assertTrue(second.getNextPageToken().isEmpty());
        FileEntry safRoot = second.getEntries(0);
        assertEquals("dm://saf-def456/", safRoot.getPath());
        assertEquals("Documents", safRoot.getName());
        assertEquals(FileKind.FILE_KIND_VIRTUAL, safRoot.getKind());
        assertTrue(safRoot.getCanRead());
        assertFalse(safRoot.getCanWrite());

        // Provider enumeration order is not part of the cursor. Stable
        // display-name/path ordering keeps the same snapshot and page.
        safCatalog.replaceRoots(secondRoot, firstRoot);
        ListDirResponse reordered = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .setPageSize(5)
                .setPageToken(first.getNextPageToken())
                .build());
        assertFalse(reordered.hasError());
        assertEquals("dm://saf-def456/", reordered.getEntries(0).getPath());

        DmFileProvider.SafRoot secondWritable = new DmFileProvider.SafRoot(
                "def456", "secondary:", "Documents", true
        );
        safCatalog.replaceRoots(firstRoot, secondWritable);
        ListDirResponse capabilityChanged = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .setPageSize(5)
                .setPageToken(first.getNextPageToken())
                .build());
        assertEquals(
                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                capabilityChanged.getError().getCode()
        );

        safCatalog.replaceRoots(secondRoot, firstRoot);
        ListDirResponse searched = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .setPageSize(1)
                .setSortField(SortField.SORT_FIELD_NAME)
                .setSearchQuery("documents")
                .build());
        assertEquals("dm://saf-abc123/", searched.getEntries(0).getPath());
        assertFalse(searched.getNextPageToken().isEmpty());
        ListDirResponse searchedNext = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .setPageSize(1)
                .setSortField(SortField.SORT_FIELD_NAME)
                .setSearchQuery("documents")
                .setPageToken(searched.getNextPageToken())
                .build());
        assertEquals("dm://saf-def456/", searchedNext.getEntries(0).getPath());
        assertTrue(searchedNext.getNextPageToken().isEmpty());

        // Revocation changes the live snapshot, so the old offset cannot skip
        // the first remaining grant.
        safCatalog.replaceRoots(secondRoot);
        ListDirResponse revoked = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .setPageSize(5)
                .setPageToken(first.getNextPageToken())
                .build());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, revoked.getError().getCode());
    }

    @Test
    public void rootListingFailsExplicitlyAtM1ResultHorizon() {
        DmFileProvider.SafRoot[] roots = new DmFileProvider.SafRoot[10_001];
        for (int index = 0; index < roots.length; index++) {
            roots[index] = new DmFileProvider.SafRoot(
                    String.format("root%05d", index),
                    "tree:" + index,
                    String.format("Root %05d", index),
                    false
            );
        }
        DmFileProvider provider = new DmFileProvider(
                new FakeMediaCatalog(), new FakeSafCatalog(roots)
        );
        String token = "";
        for (int page = 0; page < 9; page++) {
            ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                    .setPath(DmFileProvider.ROOTS_PATH)
                    .setPageSize(1_000)
                    .setPageToken(token)
                    .build());
            assertFalse(response.hasError());
            assertEquals(1_000, response.getEntriesCount());
            token = response.getNextPageToken();
            assertFalse(token.isEmpty());
        }

        ListDirResponse boundary = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .setPageSize(1_000)
                .setPageToken(token)
                .build());
        assertEquals(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                boundary.getError().getCode()
        );
        assertEquals(0, boundary.getEntriesCount());
        assertTrue(boundary.getNextPageToken().isEmpty());
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
    public void safMutationErrorDoesNotEchoProviderMessage() {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:", "Documents", true)
        );
        safCatalog.mutationException = new DmFileProvider.ProviderCatalogException(
                ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                "content://com.android.providers.documents/tree/primary%3A/private.txt denied"
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);

        FileMutationResponse response = provider.createDirectory("dm://saf-abc123/new-folder/");

        assertFalse(response.getOk());
        assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, response.getError().getCode());
        assertEquals("SAF permission is required", response.getError().getMessage());
        assertFalse(response.getError().getMessage().contains("private.txt"));
        assertFalse(response.getError().getMessage().contains("content://"));
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
    public void safPartialDiscardRoutesExactIdentityAndIsIdempotent() throws Exception {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:Docs", "Documents", true)
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);

        provider.discardUploadPartial(
                "dm://saf-abc123/payload.bin",
                "saf-cleanup-transfer",
                42
        );
        provider.discardUploadPartial(
                "dm://saf-abc123/payload.bin",
                "saf-cleanup-transfer",
                42
        );

        assertEquals("primary:Docs", safCatalog.discardedParentDocumentId);
        assertEquals("payload.bin", safCatalog.discardedDisplayName);
        assertEquals("saf-cleanup-transfer", safCatalog.discardedTransferId);
        assertEquals(42, safCatalog.discardedExpectedSizeBytes);
        assertEquals(2, safCatalog.discardCount);
    }

    @Test
    public void safPartialDiscardSharesDestinationLeaseWithActiveWriter() throws Exception {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:Docs", "Documents", true)
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);
        DmFileProvider.UploadWriter writer = provider.openUpload(
                "dm://saf-abc123/payload.bin",
                "saf-active-transfer",
                0,
                4
        );

        try {
            provider.discardUploadPartial(
                    "dm://saf-abc123/payload.bin",
                    "saf-active-transfer",
                    4
            );
            fail("expected active SAF writer to exclude partial cleanup");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_ALREADY_EXISTS, exception.code);
        }
        assertEquals(0, safCatalog.discardCount);

        writer.close();
        provider.discardUploadPartial(
                "dm://saf-abc123/payload.bin",
                "saf-active-transfer",
                4
        );
        assertEquals(1, safCatalog.discardCount);
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
    public void safDirectChildRenameUsesItsListedRootParent() {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:Docs", "Documents", true)
        );
        safCatalog.page = new DmFileProvider.SafPage(
                Collections.singletonList(new DmFileProvider.SafItem(
                        "primary:Docs/source.txt",
                        "source.txt",
                        FileKind.FILE_KIND_FILE,
                        4,
                        1_700_000_001_000L,
                        "text/plain",
                        true
                )),
                false
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);
        ListDirResponse listing = provider.listDir(ListDirRequest.newBuilder()
                .setPath("dm://saf-abc123/")
                .build());
        String sourcePath = listing.getEntries(0).getPath();

        FileMutationResponse response = provider.renamePath(
                sourcePath,
                "dm://saf-abc123/renamed.txt"
        );

        assertTrue(response.getOk());
        assertEquals(1, safCatalog.renameCount);
        assertEquals("primary:Docs/source.txt", safCatalog.renamedDocumentId);
        assertEquals("renamed.txt", safCatalog.renamedDisplayName);
    }

    @Test
    public void safRenameRejectsMissingParentProvenanceBeforeCatalogCall() {
        DmFileProvider.SafRoot root =
                new DmFileProvider.SafRoot("abc123", "primary:Docs", "Documents", true);
        FakeSafCatalog safCatalog = new FakeSafCatalog(root);
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(2);
        String sourceToken = cache.remember(root, null, "primary:Docs/source.txt");
        ProviderMutations mutations = new ProviderMutations(
                safCatalog,
                ProviderAppSandboxCatalog.empty(),
                cache
        );

        FileMutationResponse response = mutations.renamePath(
                root.path() + ProviderPathRouter.SAF_DOCUMENT_PREFIX + sourceToken,
                root.path() + "renamed.txt"
        );

        assertFalse(response.getOk());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, response.getError().getCode());
        assertEquals("SAF rename must remain in one directory", response.getError().getMessage());
        assertEquals(0, safCatalog.renameCount);
    }

    @Test
    public void safRenameRejectsCrossDirectoryBeforeCatalogAndAllowsSameDirectory() {
        FakeSafCatalog safCatalog = new FakeSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:Docs", "Documents", true)
        );
        safCatalog.page = new DmFileProvider.SafPage(
                Arrays.asList(
                        new DmFileProvider.SafItem(
                                "primary:Docs/first",
                                "first",
                                FileKind.FILE_KIND_DIRECTORY,
                                0,
                                1_700_000_001_000L,
                                "vnd.android.document/directory",
                                true
                        ),
                        new DmFileProvider.SafItem(
                                "primary:Docs/second",
                                "second",
                                FileKind.FILE_KIND_DIRECTORY,
                                0,
                                1_700_000_002_000L,
                                "vnd.android.document/directory",
                                true
                        )
                ),
                false
        );
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog(), safCatalog);
        ListDirResponse rootListing = provider.listDir(ListDirRequest.newBuilder()
                .setPath("dm://saf-abc123/")
                .build());
        String firstDirectoryPath = rootListing.getEntries(0).getPath();
        String secondDirectoryPath = rootListing.getEntries(1).getPath();
        safCatalog.page = new DmFileProvider.SafPage(
                Collections.singletonList(new DmFileProvider.SafItem(
                        "primary:Docs/first/source.txt",
                        "source.txt",
                        FileKind.FILE_KIND_FILE,
                        4,
                        1_700_000_003_000L,
                        "text/plain",
                        true
                )),
                false
        );
        ListDirResponse firstListing = provider.listDir(ListDirRequest.newBuilder()
                .setPath(firstDirectoryPath)
                .build());
        String sourcePath = firstListing.getEntries(0).getPath();

        FileMutationResponse crossDirectory = provider.renamePath(
                sourcePath,
                secondDirectoryPath + "/renamed.txt"
        );

        assertFalse(crossDirectory.getOk());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, crossDirectory.getError().getCode());
        assertEquals("SAF rename must remain in one directory", crossDirectory.getError().getMessage());
        assertFalse(crossDirectory.getError().getMessage().contains("primary:"));
        assertFalse(crossDirectory.getError().getMessage().contains("content://"));
        assertEquals(0, safCatalog.renameCount);

        FileMutationResponse sameDirectory = provider.renamePath(
                sourcePath,
                firstDirectoryPath + "/renamed.txt"
        );

        assertTrue(sameDirectory.getOk());
        assertEquals(1, safCatalog.renameCount);
        assertEquals("primary:Docs/first/source.txt", safCatalog.renamedDocumentId);
        assertEquals("renamed.txt", safCatalog.renamedDisplayName);
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
                ProviderAppSandboxCatalog.empty(),
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
