package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.fail;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.FileMutationResponse;
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

import static app.droidmatch.m1.DmFileProviderTestFixtures.deleteRecursively;
import static app.droidmatch.m1.DmFileProviderTestFixtures.writeFile;

public final class DmFileProviderTransferTest {
    @Test
    public void appSandboxCreateDirectoryRequiresExistingParentAndRejectsDuplicates() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);

            FileMutationResponse created = provider.createDirectory("dm://app-sandbox/exports/");
            assertTrue(created.getOk());
            assertTrue(new File(root, "exports").isDirectory());

            FileMutationResponse duplicate = provider.createDirectory("dm://app-sandbox/exports/");
            assertEquals(ErrorCode.ERROR_CODE_ALREADY_EXISTS, duplicate.getError().getCode());

            FileMutationResponse missingParent = provider.createDirectory(
                    "dm://app-sandbox/missing/child/"
            );
            assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, missingParent.getError().getCode());
            assertFalse(new File(root, "missing").exists());
        } finally {
            deleteRecursively(root);
        }
    }

    @Test
    public void appSandboxRootListsFilesAndDirectories() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            writeFile(new File(root, "payload.bin"), "payload");
            assertTrue(new File(root, "exports").mkdir());
            DmFileProvider provider = new DmFileProvider(root);

            ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                    .setPath(DmFileProvider.APP_SANDBOX_PATH)
                    .setSortField(SortField.SORT_FIELD_NAME)
                    .setDescending(false)
                    .build());

            assertFalse(response.hasError());
            assertEquals(2, response.getEntriesCount());
            assertEquals("dm://app-sandbox/exports/", response.getEntries(0).getPath());
            assertEquals(FileKind.FILE_KIND_DIRECTORY, response.getEntries(0).getKind());
            assertEquals("dm://app-sandbox/payload.bin", response.getEntries(1).getPath());
            assertEquals(FileKind.FILE_KIND_FILE, response.getEntries(1).getKind());
            assertEquals(7, response.getEntries(1).getSizeBytes());
            assertEquals("application/octet-stream", response.getEntries(1).getMimeType());
        } finally {
            deleteRecursively(root);
        }
    }

    @Test
    public void appSandboxFilePathStreamsDownloadChunks() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            writeFile(new File(root, "payload.bin"), "payload");
            DmFileProvider provider = new DmFileProvider(root);

            DmFileProvider.DownloadReader reader = provider.openDownload(
                    "dm://app-sandbox/payload.bin",
                    2,
                    3
            );
            DmFileProvider.DownloadChunk first = reader.readNextChunk();
            DmFileProvider.DownloadChunk second = reader.readNextChunk();
            reader.close();

            assertEquals("ylo", new String(first.data, StandardCharsets.UTF_8));
            assertFalse(first.finalChunk);
            assertEquals("ad", new String(second.data, StandardCharsets.UTF_8));
            assertTrue(second.finalChunk);
            assertEquals(7, second.totalSizeBytes);
            assertTrue(second.providerEtag.startsWith("app-sandbox:"));
            assertFalse(second.providerEtag.contains("payload.bin"));
        } finally {
            deleteRecursively(root);
        }
    }

    @Test
    public void appSandboxUploadCommitsFinalFile() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);
            DmFileProvider.UploadWriter writer = provider.openUpload(
                    "dm://app-sandbox/uploads/payload.bin",
                    0,
                    6
            );

            writer.writeChunk(0, "abc".getBytes(StandardCharsets.UTF_8), false);
            assertEquals(3, writer.nextOffsetBytes());
            writer.writeChunk(3, "def".getBytes(StandardCharsets.UTF_8), true);
            writer.close();

            File uploaded = new File(root, "uploads/payload.bin");
            assertEquals("abcdef", new String(Files.readAllBytes(uploaded.toPath()), StandardCharsets.UTF_8));
            assertEquals(0, new File(root, "uploads").listFiles((directory, name) -> name.endsWith(".droidmatch-upload-part")).length);
        } finally {
            deleteRecursively(root);
        }
    }

    @Test
    public void appSandboxUploadResumeAppendsPartialFileAndHidesItFromListing() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);
            DmFileProvider.UploadWriter partialWriter = provider.openUpload(
                    "dm://app-sandbox/uploads/payload.bin",
                    0,
                    6
            );
            partialWriter.writeChunk(0, "abc".getBytes(StandardCharsets.UTF_8), false);
            partialWriter.close();

            ListDirResponse partialListing = provider.listDir(ListDirRequest.newBuilder()
                    .setPath("dm://app-sandbox/uploads/")
                    .build());
            assertFalse(partialListing.hasError());
            assertEquals(0, partialListing.getEntriesCount());

            DmFileProvider.UploadWriter resumedWriter = provider.openUpload(
                    "dm://app-sandbox/uploads/payload.bin",
                    3,
                    6
            );
            assertEquals(3, resumedWriter.nextOffsetBytes());
            resumedWriter.writeChunk(3, "def".getBytes(StandardCharsets.UTF_8), true);
            resumedWriter.close();

            File uploaded = new File(root, "uploads/payload.bin");
            assertEquals("abcdef", new String(Files.readAllBytes(uploaded.toPath()), StandardCharsets.UTF_8));
        } finally {
            deleteRecursively(root);
        }
    }

    @Test
    public void appSandboxUploadResumeTruncatesPartialAheadOfRequestedOffset() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);
            DmFileProvider.UploadWriter partialWriter = provider.openUpload(
                    "dm://app-sandbox/uploads/payload.bin",
                    0,
                    6
            );
            partialWriter.writeChunk(0, "abcdef".getBytes(StandardCharsets.UTF_8), false);
            partialWriter.close();

            DmFileProvider.UploadWriter resumedWriter = provider.openUpload(
                    "dm://app-sandbox/uploads/payload.bin",
                    3,
                    6
            );
            assertEquals(3, resumedWriter.nextOffsetBytes());
            resumedWriter.writeChunk(3, "def".getBytes(StandardCharsets.UTF_8), true);
            resumedWriter.close();

            File uploaded = new File(root, "uploads/payload.bin");
            assertEquals("abcdef", new String(Files.readAllBytes(uploaded.toPath()), StandardCharsets.UTF_8));
        } finally {
            deleteRecursively(root);
        }
    }

    @Test
    public void appSandboxUploadRejectsOffsetBeyondExpectedSize() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);

            try {
                provider.openUpload("dm://app-sandbox/uploads/payload.bin", 7, 6);
                fail("expected offset beyond expected size to be rejected");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
            }
        } finally {
            deleteRecursively(root);
        }
    }

    @Test
    public void appSandboxUploadRejectsTraversalOutsideRoot() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);

            try {
                provider.openUpload("dm://app-sandbox/../payload.bin", 0, 1);
                fail("expected traversal to be rejected");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
            }
        } finally {
            deleteRecursively(root);
        }
    }

    @Test
    public void appSandboxRejectsTraversalOutsideRoot() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);

            ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                    .setPath("dm://app-sandbox/../")
                    .build());

            assertTrue(response.hasError());
            assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, response.getError().getCode());
            try {
                provider.openDownload("dm://app-sandbox/../secret.bin", 0, 1);
                fail("expected traversal to be rejected");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
            }
        } finally {
            deleteRecursively(root);
        }
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
    public void mediaRootPathUploadsFreshFile() throws Exception {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        DmFileProvider provider = new DmFileProvider(catalog);

        DmFileProvider.UploadWriter writer = provider.openUpload("dm://media-images/payload.jpg", 0, 6);
        writer.writeChunk(0, "abc".getBytes(StandardCharsets.UTF_8), false);
        writer.writeChunk(3, "def".getBytes(StandardCharsets.UTF_8), true);
        writer.close();

        assertEquals(DmFileProvider.RootKind.MEDIA_IMAGES, catalog.uploadRootKind);
        assertEquals("payload.jpg", catalog.uploadDisplayName);
        assertEquals(0, catalog.uploadOffsetBytes);
        assertEquals(6, catalog.uploadExpectedSizeBytes);
        assertEquals("abcdef", catalog.uploadedText());
    }

    @Test
    public void mediaUploadRejectsResumeOffset() throws Exception {
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog());

        try {
            provider.openUpload("dm://media-videos/payload.mp4", 1, 6);
            fail("expected MediaStore upload resume to be rejected");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, exception.code);
        }
    }

    @Test
    public void mediaUploadRejectsNestedPath() throws Exception {
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog());

        try {
            provider.openUpload("dm://media-images/nested/payload.jpg", 0, 6);
            fail("expected nested MediaStore upload path to be rejected");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
        }
    }

    @Test
    public void openDownloadReusesOneReaderAcrossChunks() throws Exception {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.streamData = "abcdef".getBytes(StandardCharsets.UTF_8);
        DmFileProvider provider = new DmFileProvider(catalog);

        DmFileProvider.DownloadReader reader = provider.openDownload(
                "dm://media-images/media/42",
                2,
                2
        );
        DmFileProvider.DownloadChunk first = reader.readNextChunk();
        DmFileProvider.DownloadChunk second = reader.readNextChunk();
        reader.close();

        assertEquals(1, catalog.openMediaCount);
        assertEquals(42, catalog.mediaId);
        assertEquals(2, catalog.readOffsetBytes);
        assertEquals(2, catalog.readChunkSizeBytes);
        assertEquals("cd", new String(first.data, StandardCharsets.UTF_8));
        assertFalse(first.finalChunk);
        assertEquals("ef", new String(second.data, StandardCharsets.UTF_8));
        assertTrue(second.finalChunk);
        assertEquals(1, catalog.closeReaderCount);
    }

}
