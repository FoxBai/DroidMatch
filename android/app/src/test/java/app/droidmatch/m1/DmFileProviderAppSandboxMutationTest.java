package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.FileMutationResponse;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;
import app.droidmatch.proto.v1.SortField;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import org.junit.Test;

import static app.droidmatch.m1.DmFileProviderTestFixtures.deleteRecursively;
import static app.droidmatch.m1.DmFileProviderTestFixtures.writeFile;

public final class DmFileProviderAppSandboxMutationTest {
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
}
