package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.fail;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.FileTime;

import org.junit.Test;

import static app.droidmatch.m1.DmFileProviderTestFixtures.deleteRecursively;
import static app.droidmatch.m1.DmFileProviderTestFixtures.writeFile;

public final class DmFileProviderAppSandboxTransferTest {
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
}
