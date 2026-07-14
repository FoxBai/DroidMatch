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
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.FileTime;
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
    public void appSandboxRenameStaysInParentAndPreservesKind() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            writeFile(new File(root, "before.txt"), "payload");
            assertTrue(new File(root, "folder").mkdir());
            DmFileProvider provider = new DmFileProvider(root);

            FileMutationResponse fileRename = provider.renamePath(
                    "dm://app-sandbox/before.txt",
                    "dm://app-sandbox/after.txt"
            );
            assertTrue(fileRename.getOk());
            assertTrue(new File(root, "after.txt").isFile());

            FileMutationResponse directoryRename = provider.renamePath(
                    "dm://app-sandbox/folder/",
                    "dm://app-sandbox/archive/"
            );
            assertTrue(directoryRename.getOk());
            assertTrue(new File(root, "archive").isDirectory());

            FileMutationResponse kindMismatch = provider.renamePath(
                    "dm://app-sandbox/archive/",
                    "dm://app-sandbox/not-a-directory"
            );
            assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, kindMismatch.getError().getCode());
        } finally {
            deleteRecursively(root);
        }
    }

    @Test
    public void appSandboxDeleteRequiresRecursiveFlagForNonEmptyDirectory() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            File folder = new File(root, "folder");
            assertTrue(folder.mkdir());
            writeFile(new File(folder, "payload.txt"), "payload");
            DmFileProvider provider = new DmFileProvider(root);

            FileMutationResponse refused = provider.deletePath(
                    "dm://app-sandbox/folder/",
                    false
            );
            assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, refused.getError().getCode());
            assertTrue(folder.exists());

            FileMutationResponse deleted = provider.deletePath(
                    "dm://app-sandbox/folder/",
                    true
            );
            assertTrue(deleted.getOk());
            assertFalse(folder.exists());

            FileMutationResponse rootDelete = provider.deletePath(
                    DmFileProvider.APP_SANDBOX_PATH,
                    true
            );
            assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, rootDelete.getError().getCode());
        } finally {
            deleteRecursively(root);
        }
    }

    @Test
    public void appSandboxRecursiveDeleteDoesNotFollowSymbolicDirectoryEntries() throws Exception {
        Path root = Files.createTempDirectory("droidmatch-app-sandbox");
        Path outside = Files.createTempDirectory("droidmatch-app-sandbox-outside");
        Path container = Files.createDirectory(root.resolve("container"));
        Path outsideFile = Files.write(
                outside.resolve("keep.txt"),
                "keep".getBytes(StandardCharsets.UTF_8)
        );
        Path symbolicDirectory = Files.createSymbolicLink(
                container.resolve("escape"),
                outside
        );
        try {
            DmFileProvider provider = new DmFileProvider(root.toFile());
            ListDirResponse listing = provider.listDir(ListDirRequest.newBuilder()
                    .setPath("dm://app-sandbox/container/")
                    .build());

            FileMutationResponse deleted = provider.deletePath(
                    "dm://app-sandbox/container/",
                    true
            );

            assertTrue("recursive delete followed a symbolic directory outside the root",
                    Files.isRegularFile(outsideFile));
            assertFalse(listing.hasError());
            assertEquals(0, listing.getEntriesCount());
            assertTrue(deleted.getOk());
            assertFalse(Files.exists(container));
        } finally {
            // Remove the link before fixture cleanup so a regression cannot make
            // the test's own cleanup follow it. 中文：测试清理同样不得跟随链接。
            Files.deleteIfExists(symbolicDirectory);
            deleteRecursively(root.toFile());
            deleteRecursively(outside.toFile());
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
    public void appSandboxSearchFiltersBeforePagingCaseInsensitively() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            writeFile(new File(root, "Photo-One.jpg"), "one");
            writeFile(new File(root, "notes.txt"), "notes");
            writeFile(new File(root, "holiday-photo.jpg"), "two");
            DmFileProvider provider = new DmFileProvider(root);

            ListDirResponse first = provider.listDir(ListDirRequest.newBuilder()
                    .setPath(DmFileProvider.APP_SANDBOX_PATH)
                    .setSearchQuery("PHOTO")
                    .setSortField(SortField.SORT_FIELD_NAME)
                    .setPageSize(1)
                    .build());
            assertEquals(1, first.getEntriesCount());
            assertEquals("holiday-photo.jpg", first.getEntries(0).getName());
            assertFalse(first.getNextPageToken().isEmpty());

            ListDirResponse second = provider.listDir(ListDirRequest.newBuilder()
                    .setPath(DmFileProvider.APP_SANDBOX_PATH)
                    .setSearchQuery("PHOTO")
                    .setSortField(SortField.SORT_FIELD_NAME)
                    .setPageSize(1)
                    .setPageToken(first.getNextPageToken())
                    .build());
            assertEquals(1, second.getEntriesCount());
            assertEquals("Photo-One.jpg", second.getEntries(0).getName());
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
    public void appSandboxAtomicReplacementChangesOpaqueSourceIdentity() throws Exception {
        Path root = Files.createTempDirectory("droidmatch-app-sandbox");
        Path source = root.resolve("payload.bin");
        Path replacement = root.resolve("replacement.bin");
        FileTime fixedModifiedTime = FileTime.fromMillis(1_700_000_000_000L);
        try {
            Files.write(source, "before".getBytes(StandardCharsets.UTF_8));
            Files.setLastModifiedTime(source, fixedModifiedTime);
            DmFileProvider provider = new DmFileProvider(root.toFile());

            DmFileProvider.DownloadReader firstReader = provider.openDownload(
                    "dm://app-sandbox/payload.bin",
                    0,
                    16
            );
            DmFileProvider.DownloadChunk first = firstReader.readNextChunk();
            firstReader.close();

            Files.write(replacement, "after!".getBytes(StandardCharsets.UTF_8));
            Files.setLastModifiedTime(replacement, fixedModifiedTime);
            Files.move(
                    replacement,
                    source,
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE
            );

            DmFileProvider.DownloadReader secondReader = provider.openDownload(
                    "dm://app-sandbox/payload.bin",
                    0,
                    16
            );
            DmFileProvider.DownloadChunk second = secondReader.readNextChunk();
            secondReader.close();

            assertEquals(first.totalSizeBytes, second.totalSizeBytes);
            assertEquals(first.modifiedUnixMillis, second.modifiedUnixMillis);
            assertFalse(
                    "same-size replacement reused the prior provider identity",
                    first.providerEtag.equals(second.providerEtag)
            );
        } finally {
            Files.deleteIfExists(replacement);
            deleteRecursively(root.toFile());
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
    public void appSandboxUploadResumeRejectsSymbolicPartialWithoutTouchingTarget() throws Exception {
        Path root = Files.createTempDirectory("droidmatch-app-sandbox");
        Path outside = Files.createTempDirectory("droidmatch-app-sandbox-outside");
        Path uploads = Files.createDirectories(root.resolve("uploads"));
        Path outsideFile = Files.write(
                outside.resolve("keep.bin"),
                "abcdef".getBytes(StandardCharsets.UTF_8)
        );
        Path partial = Files.createSymbolicLink(
                uploads.resolve(".payload.bin.droidmatch-upload-part"),
                outsideFile
        );
        try {
            DmFileProvider provider = new DmFileProvider(root.toFile());
            boolean rejected = false;
            try {
                DmFileProvider.UploadWriter writer = provider.openUpload(
                        "dm://app-sandbox/uploads/payload.bin",
                        3,
                        6
                );
                writer.close();
            } catch (DmFileProvider.ProviderCatalogException exception) {
                rejected = true;
                assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, exception.code);
            }

            assertEquals("abcdef", new String(
                    Files.readAllBytes(outsideFile),
                    StandardCharsets.UTF_8
            ));
            assertTrue("symbolic upload partial should be rejected", rejected);
            assertTrue(Files.isSymbolicLink(partial));
            assertFalse(Files.exists(uploads.resolve("payload.bin")));
        } finally {
            // Delete the link itself before the generic fixture cleanup.
            // 中文：先删除链接节点，测试清理不得接触链接目标。
            Files.deleteIfExists(partial);
            deleteRecursively(root.toFile());
            deleteRecursively(outside.toFile());
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
    public void unknownDownloadPathDoesNotEchoCallerPath() throws Exception {
        DmFileProvider provider = new DmFileProvider();

        try {
            provider.openDownload("dm://private-root/private-report.txt", 0, 1);
            fail("expected unknown provider path to be rejected");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, exception.code);
            assertEquals("unknown DroidMatch provider path", exception.getMessage());
            assertFalse(exception.getMessage().contains("private-report.txt"));
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
