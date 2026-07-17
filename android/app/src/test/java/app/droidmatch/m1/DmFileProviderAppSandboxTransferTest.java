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
import static app.droidmatch.m1.DmFileProviderTestFixtures.deleteAppSandboxRoot;
import static app.droidmatch.m1.DmFileProviderTestFixtures.writeFile;

public final class DmFileProviderAppSandboxTransferTest {
    @Test
    public void discardUploadPartialIsExactIdempotentAndPreservesFinalFile() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);
            String path = "dm://app-sandbox/uploads/payload.bin";
            DmFileProvider.UploadWriter writer = provider.openUpload(
                    path,
                    "discard-exact",
                    0,
                    6
            );
            writer.writeChunk(0, "abc".getBytes(StandardCharsets.UTF_8), false);
            writer.close();
            Path staging = AndroidAppSandboxCatalog.stagingDirectoryFor(root).toPath();
            Path partial = AndroidAppSandboxCatalog.stagingPartialFile(
                    staging.toFile(),
                    "uploads/payload.bin",
                    "discard-exact",
                    6
            ).toPath();
            Path finalFile = Files.write(
                    root.toPath().resolve("uploads/payload.bin"),
                    "keep".getBytes(StandardCharsets.UTF_8)
            );

            provider.discardUploadPartial(path, "discard-exact", 5);
            assertTrue("wrong size must not match another partial", Files.exists(partial));
            provider.discardUploadPartial(path, "discard-exact", 6);
            provider.discardUploadPartial(path, "discard-exact", 6);

            assertFalse(Files.exists(partial));
            assertEquals("keep", new String(
                    Files.readAllBytes(finalFile),
                    StandardCharsets.UTF_8
            ));
        } finally {
            deleteAppSandboxRoot(root);
        }
    }

    @Test
    public void discardUploadPartialCannotRaceAnActiveDestinationWriter() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);
            String path = "dm://app-sandbox/uploads/payload.bin";
            DmFileProvider.UploadWriter writer = provider.openUpload(
                    path,
                    "discard-active",
                    0,
                    6
            );
            writer.writeChunk(0, "abc".getBytes(StandardCharsets.UTF_8), false);
            try {
                provider.discardUploadPartial(path, "discard-active", 6);
                fail("expected active upload lease to reject partial cleanup");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_ALREADY_EXISTS, exception.code);
            }
            writer.close();

            provider.discardUploadPartial(path, "discard-active", 6);
            Path partial = AndroidAppSandboxCatalog.stagingPartialFile(
                    AndroidAppSandboxCatalog.stagingDirectoryFor(root),
                    "uploads/payload.bin",
                    "discard-active",
                    6
            ).toPath();
            assertFalse(Files.exists(partial));
        } finally {
            deleteAppSandboxRoot(root);
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
            deleteAppSandboxRoot(root);
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
            deleteAppSandboxRoot(root.toFile());
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
            deleteAppSandboxRoot(root);
        }
    }

    @Test
    public void appSandboxUploadRejectsUnsafeDisplayNamesWithoutBreakingDownloads()
            throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);
            String supplementaryFormat = new String(Character.toChars(0xE0001));

            for (String displayName : new String[] {
                    "private%name.bin",
                    "private" + String.valueOf((char) 0x0001) + "name.bin",
                    "private" + String.valueOf((char) 0x0085) + "name.bin",
                    "private\u200Dname.bin",
                    "private\u202Ename.bin",
                    "private\u2068name.bin",
                    "private" + supplementaryFormat + "name.bin",
            }) {
                try {
                    provider.openUpload(
                            "dm://app-sandbox/uploads/" + displayName,
                            0,
                            1
                    );
                    fail("expected unsafe app sandbox display name to fail closed");
                } catch (DmFileProvider.ProviderCatalogException exception) {
                    assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
                    assertEquals(
                            "malformed app sandbox upload file name",
                            exception.getMessage()
                    );
                    assertFalse(exception.getMessage().contains("private"));
                }
            }

            writeFile(new File(root, "legacy%name.bin"), "x");
            try (DmFileProvider.DownloadReader reader = provider.openDownload(
                    "dm://app-sandbox/legacy%name.bin",
                    0,
                    1
            )) {
                assertEquals("x", new String(
                        reader.readNextChunk().data,
                        StandardCharsets.UTF_8
                ));
            }
        } finally {
            deleteAppSandboxRoot(root);
        }
    }

    @Test
    public void appSandboxUploadResumeAppendsPartialFileAndHidesItFromListing() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);
            DmFileProvider.UploadWriter partialWriter = provider.openUpload(
                    "dm://app-sandbox/uploads/payload.bin",
                    "resume-append",
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
                    "resume-append",
                    3,
                    6
            );
            assertEquals(3, resumedWriter.nextOffsetBytes());
            resumedWriter.writeChunk(3, "def".getBytes(StandardCharsets.UTF_8), true);
            resumedWriter.close();

            File uploaded = new File(root, "uploads/payload.bin");
            assertEquals("abcdef", new String(Files.readAllBytes(uploaded.toPath()), StandardCharsets.UTF_8));
        } finally {
            deleteAppSandboxRoot(root);
        }
    }

    @Test
    public void appSandboxUploadResumeTruncatesPartialAheadOfRequestedOffset() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);
            DmFileProvider.UploadWriter partialWriter = provider.openUpload(
                    "dm://app-sandbox/uploads/payload.bin",
                    "resume-truncate",
                    0,
                    6
            );
            partialWriter.writeChunk(0, "abcdef".getBytes(StandardCharsets.UTF_8), false);
            partialWriter.close();

            DmFileProvider.UploadWriter resumedWriter = provider.openUpload(
                    "dm://app-sandbox/uploads/payload.bin",
                    "resume-truncate",
                    3,
                    6
            );
            assertEquals(3, resumedWriter.nextOffsetBytes());
            resumedWriter.writeChunk(3, "def".getBytes(StandardCharsets.UTF_8), true);
            resumedWriter.close();

            File uploaded = new File(root, "uploads/payload.bin");
            assertEquals("abcdef", new String(Files.readAllBytes(uploaded.toPath()), StandardCharsets.UTF_8));
        } finally {
            deleteAppSandboxRoot(root);
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
        Path staging = Files.createDirectory(
                AndroidAppSandboxCatalog.stagingDirectoryFor(root.toFile()).toPath()
        );
        Path partial = Files.createSymbolicLink(
                AndroidAppSandboxCatalog.stagingPartialFile(
                        staging.toFile(),
                        "uploads/payload.bin",
                        "symbolic-resume",
                        6
                ).toPath(),
                outsideFile
        );
        try {
            DmFileProvider provider = new DmFileProvider(root.toFile());
            boolean rejected = false;
            try {
                DmFileProvider.UploadWriter writer = provider.openUpload(
                        "dm://app-sandbox/uploads/payload.bin",
                        "symbolic-resume",
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
            Files.deleteIfExists(staging);
            deleteAppSandboxRoot(root.toFile());
            deleteRecursively(outside.toFile());
        }
    }

    @Test
    public void appSandboxUploadRejectsNonDirectoryStagingNodes() throws Exception {
        Path root = Files.createTempDirectory("droidmatch-app-sandbox");
        Path outside = Files.createTempDirectory("droidmatch-app-sandbox-outside");
        Path staging = AndroidAppSandboxCatalog.stagingDirectoryFor(root.toFile()).toPath();
        Path outsideKeep = Files.write(
                outside.resolve("keep.bin"),
                "keep".getBytes(StandardCharsets.UTF_8)
        );
        try {
            DmFileProvider provider = new DmFileProvider(root.toFile());
            Files.write(staging, "not-a-directory".getBytes(StandardCharsets.UTF_8));
            try {
                provider.openUpload(
                        "dm://app-sandbox/uploads/file-node.bin",
                        "staging-file",
                        0,
                        4
                );
                fail("expected ordinary staging file to be rejected");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INTERNAL, exception.code);
            }
            assertEquals("not-a-directory", new String(
                    Files.readAllBytes(staging),
                    StandardCharsets.UTF_8
            ));

            Files.delete(staging);
            Files.createSymbolicLink(staging, outside);
            try {
                provider.openUpload(
                        "dm://app-sandbox/uploads/symbolic-node.bin",
                        "staging-symbolic",
                        0,
                        4
                );
                fail("expected symbolic staging directory to be rejected");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INTERNAL, exception.code);
            }
            assertTrue(Files.isSymbolicLink(staging));
            assertEquals("keep", new String(
                    Files.readAllBytes(outsideKeep),
                    StandardCharsets.UTF_8
            ));
            assertFalse(Files.exists(root.resolve("uploads/file-node.bin")));
            assertFalse(Files.exists(root.resolve("uploads/symbolic-node.bin")));
        } finally {
            Files.deleteIfExists(staging);
            deleteAppSandboxRoot(root.toFile());
            deleteRecursively(outside.toFile());
        }
    }

    @Test
    public void appSandboxFreshUploadPreservesUnexpectedMatchingPartialNodes() throws Exception {
        Path root = Files.createTempDirectory("droidmatch-app-sandbox");
        Path outside = Files.createTempDirectory("droidmatch-app-sandbox-outside");
        Path staging = Files.createDirectory(
                AndroidAppSandboxCatalog.stagingDirectoryFor(root.toFile()).toPath()
        );
        Path unexpected = AndroidAppSandboxCatalog.stagingPartialFile(
                staging.toFile(),
                "uploads/payload.bin",
                "stale-transfer",
                6
        ).toPath();
        Path outsideKeep = Files.write(
                outside.resolve("keep.bin"),
                "keep".getBytes(StandardCharsets.UTF_8)
        );
        try {
            DmFileProvider provider = new DmFileProvider(root.toFile());
            Files.createDirectory(unexpected);
            try {
                provider.openUpload(
                        "dm://app-sandbox/uploads/payload.bin",
                        "fresh-after-directory",
                        0,
                        6
                );
                fail("expected matching partial directory to be rejected");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INTERNAL, exception.code);
            }
            assertTrue(Files.isDirectory(unexpected, java.nio.file.LinkOption.NOFOLLOW_LINKS));

            Files.delete(unexpected);
            Files.createSymbolicLink(unexpected, outsideKeep);
            try {
                provider.openUpload(
                        "dm://app-sandbox/uploads/payload.bin",
                        "fresh-after-symbolic",
                        0,
                        6
                );
                fail("expected matching symbolic partial to be rejected");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INTERNAL, exception.code);
            }
            assertTrue(Files.isSymbolicLink(unexpected));
            assertEquals("keep", new String(
                    Files.readAllBytes(outsideKeep),
                    StandardCharsets.UTF_8
            ));
        } finally {
            Files.deleteIfExists(unexpected);
            Files.deleteIfExists(staging);
            deleteAppSandboxRoot(root.toFile());
            deleteRecursively(outside.toFile());
        }
    }

    @Test
    public void appSandboxUploadResumeCannotReuseAnotherTransferIdentity() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            assertEquals(
                    "0288faa2e1495ced41d8de4deeac3c4299ad8c4b24d1f9ea4b8dc5c45498d032",
                    AndroidAppSandboxCatalog.uploadDestinationKey("uploads/payload.bin")
            );
            DmFileProvider provider = new DmFileProvider(root);
            DmFileProvider.UploadWriter first = provider.openUpload(
                    "dm://app-sandbox/uploads/payload.bin",
                    "transfer-a",
                    0,
                    6
            );
            first.writeChunk(0, "aaa".getBytes(StandardCharsets.UTF_8), false);
            first.close();

            DmFileProvider.UploadWriter other = provider.openUpload(
                    "dm://app-sandbox/uploads/other.bin",
                    "transfer-other",
                    0,
                    6
            );
            other.writeChunk(0, "ooo".getBytes(StandardCharsets.UTF_8), false);
            other.close();

            DmFileProvider.UploadWriter second = provider.openUpload(
                    "dm://app-sandbox/uploads/payload.bin",
                    "transfer-b",
                    0,
                    6
            );
            second.writeChunk(0, "bbb".getBytes(StandardCharsets.UTF_8), false);
            second.close();

            try {
                provider.openUpload(
                        "dm://app-sandbox/uploads/payload.bin",
                        "transfer-a",
                        3,
                        6
                );
                fail("expected stale transfer identity to be rejected");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, exception.code);
            }

            DmFileProvider.UploadWriter resumed = provider.openUpload(
                    "dm://app-sandbox/uploads/payload.bin",
                    "transfer-b",
                    3,
                    6
            );
            resumed.writeChunk(3, "BBB".getBytes(StandardCharsets.UTF_8), true);
            resumed.close();
            assertEquals("bbbBBB", new String(
                    Files.readAllBytes(new File(root, "uploads/payload.bin").toPath()),
                    StandardCharsets.UTF_8
            ));

            DmFileProvider.UploadWriter resumedOther = provider.openUpload(
                    "dm://app-sandbox/uploads/other.bin",
                    "transfer-other",
                    3,
                    6
            );
            resumedOther.writeChunk(3, "OOO".getBytes(StandardCharsets.UTF_8), true);
            resumedOther.close();
            assertEquals("oooOOO", new String(
                    Files.readAllBytes(new File(root, "uploads/other.bin").toPath()),
                    StandardCharsets.UTF_8
            ));
        } finally {
            deleteAppSandboxRoot(root);
        }
    }

    @Test
    public void appSandboxLegacyPartialRemainsHiddenReservedAndUntouched() throws Exception {
        File root = Files.createTempDirectory("droidmatch-app-sandbox").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);
            File uploads = new File(root, "uploads");
            assertTrue(uploads.mkdirs());
            File legacyPartial = new File(uploads, ".payload.droidmatch-upload-part");
            Files.write(
                    legacyPartial.toPath(),
                    "old".getBytes(StandardCharsets.UTF_8)
            );

            DmFileProvider.UploadWriter ordinary = provider.openUpload(
                    "dm://app-sandbox/uploads/payload",
                    "ordinary-file",
                    0,
                    3
            );
            ordinary.writeChunk(0, "new".getBytes(StandardCharsets.UTF_8), true);
            ordinary.close();

            ListDirResponse listing = provider.listDir(ListDirRequest.newBuilder()
                    .setPath("dm://app-sandbox/uploads/")
                    .build());
            assertFalse(listing.hasError());
            assertEquals(1, listing.getEntriesCount());
            assertEquals("dm://app-sandbox/uploads/payload", listing.getEntries(0).getPath());
            assertEquals("old", new String(
                    Files.readAllBytes(legacyPartial.toPath()),
                    StandardCharsets.UTF_8
            ));
            try {
                provider.openUpload(
                        "dm://app-sandbox/uploads/.other.droidmatch-upload-part",
                        "reserved-name",
                        0,
                        3
                );
                fail("expected legacy upload partial name to remain reserved");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
            }
            try {
                provider.openDownload(
                        "dm://app-sandbox/uploads/.payload.droidmatch-upload-part",
                        0,
                        3
                );
                fail("expected legacy upload partial to remain private");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
            }
        } finally {
            deleteAppSandboxRoot(root);
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
            deleteAppSandboxRoot(root);
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
            deleteAppSandboxRoot(root);
        }
    }

    @Test
    public void appSandboxTransfersRejectSymbolicPathComponents() throws Exception {
        Path root = Files.createTempDirectory("droidmatch-app-sandbox");
        Path target = Files.createDirectory(root.resolve("target"));
        Path payload = Files.write(target.resolve("payload.bin"), new byte[] {1, 2, 3});
        Path alias = Files.createSymbolicLink(root.resolve("alias"), target);
        try {
            DmFileProvider provider = new DmFileProvider(root.toFile());

            try {
                provider.openDownload("dm://app-sandbox/alias/payload.bin", 0, 1);
                fail("expected symbolic download path to be rejected");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
            }
            try {
                provider.openUpload("dm://app-sandbox/alias/new.bin", 0, 1);
                fail("expected symbolic upload path to be rejected");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
            }

            try (DmFileProvider.DownloadReader ignored = provider.openDownload(
                    "dm://app-sandbox/target/payload.bin",
                    0,
                    1
            )) {
                assertTrue(Files.isRegularFile(payload));
            }
            assertFalse(Files.exists(target.resolve("new.bin")));
        } finally {
            Files.deleteIfExists(alias);
            deleteAppSandboxRoot(root.toFile());
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
            deleteAppSandboxRoot(root);
        }
    }
}
