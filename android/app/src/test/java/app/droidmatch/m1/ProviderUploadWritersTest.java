package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import app.droidmatch.proto.v1.ErrorCode;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;

import org.junit.Test;

public final class ProviderUploadWritersTest {
    @Test
    public void sharedBoundaryReturnsTheContiguousNextOffset() throws Exception {
        assertEquals(
                14,
                ProviderUploadWriters.validatedNextOffset(
                        false,
                        10,
                        20,
                        10,
                        new byte[4],
                        false
                )
        );
        assertEquals(
                20,
                ProviderUploadWriters.validatedNextOffset(
                        false,
                        14,
                        20,
                        14,
                        new byte[6],
                        true
                )
        );
        assertEquals(
                0,
                ProviderUploadWriters.validatedNextOffset(
                        false,
                        0,
                        0,
                        0,
                        new byte[0],
                        true
                )
        );
    }

    @Test
    public void sharedBoundaryPreservesStableValidationFailures() throws Exception {
        expectInvalid(
                "upload writer is closed",
                () -> ProviderUploadWriters.validatedNextOffset(
                        true, 0, 1, 0, null, true
                )
        );
        expectInvalid(
                "transfer chunk offset does not match the expected write boundary",
                () -> ProviderUploadWriters.validatedNextOffset(
                        false, 2, 4, 1, null, false
                )
        );
        expectInvalid(
                "empty upload chunks must be final",
                () -> ProviderUploadWriters.validatedNextOffset(
                        false, 0, 1, 0, new byte[0], false
                )
        );
        expectInvalid(
                "upload chunk exceeds expected_size_bytes",
                () -> ProviderUploadWriters.validatedNextOffset(
                        false, 0, 1, 0, new byte[2], true
                )
        );
        expectInvalid(
                "final upload chunk does not match expected_size_bytes",
                () -> ProviderUploadWriters.validatedNextOffset(
                        false, 0, 2, 0, new byte[1], true
                )
        );
    }

    @Test
    public void freshSafUploadDeletesIncompleteDocumentOnClose() {
        FakeSafDocumentOperations operations = new FakeSafDocumentOperations();
        CloseTrackingOutputStream output = new CloseTrackingOutputStream();
        SafUploadWriter writer = new SafUploadWriter(
                operations, output, 4, 0, null, true, () -> {}
        );

        writer.close();
        writer.close();

        assertTrue(output.closed);
        assertEquals(1, operations.deleteCount);
        assertEquals(0, operations.renameCount);
    }

    @Test
    public void resumableSafUploadPreservesIncompletePartialOnClose() {
        FakeSafDocumentOperations operations = new FakeSafDocumentOperations();
        CloseTrackingOutputStream output = new CloseTrackingOutputStream();
        SafUploadWriter writer = new SafUploadWriter(
                operations, output, 4, 0, "final.bin", false, () -> {}
        );

        writer.close();

        assertTrue(output.closed);
        assertEquals(0, operations.deleteCount);
        assertEquals(0, operations.renameCount);
    }

    @Test
    public void appSandboxUploadFailsClosedWhenAtomicReplacementIsUnavailable() throws Exception {
        Path directory = Files.createTempDirectory("droidmatch-atomic-upload");
        File destination = directory.resolve("destination.bin").toFile();
        File partial = directory.resolve("partial.bin").toFile();
        try {
            Files.write(destination.toPath(), "old".getBytes(StandardCharsets.UTF_8));
            Files.write(partial.toPath(), "partial".getBytes(StandardCharsets.UTF_8));
            TrackingAppSandboxPartialOutput output =
                    new TrackingAppSandboxPartialOutput(false);
            RejectingAppSandboxCommitOperations operations =
                    new RejectingAppSandboxCommitOperations(output);
            AppSandboxUploadWriter writer = new AppSandboxUploadWriter(
                    destination,
                    partial,
                    output,
                    4,
                    0,
                    operations
            );

            try {
                writer.writeChunk(0, new byte[] {1, 2, 3, 4}, true);
                fail("expected unsupported atomic replacement to fail");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INTERNAL, exception.code);
                assertEquals("app sandbox upload write failed", exception.getMessage());
            }
            writer.close();

            assertTrue(output.closed);
            assertEquals(1, output.synchronizeCount);
            assertEquals(1, operations.replaceCount);
            assertTrue(operations.partialWasSynchronized);
            assertTrue(operations.partialWasClosed);
            assertEquals("old", new String(
                    Files.readAllBytes(destination.toPath()),
                    StandardCharsets.UTF_8
            ));
            assertEquals("partial", new String(
                    Files.readAllBytes(partial.toPath()),
                    StandardCharsets.UTF_8
            ));
        } finally {
            Files.deleteIfExists(partial.toPath());
            Files.deleteIfExists(destination.toPath());
            Files.deleteIfExists(directory);
        }
    }

    @Test
    public void appSandboxUploadDoesNotReplaceDestinationWhenPartialSyncFails() throws Exception {
        Path directory = Files.createTempDirectory("droidmatch-durable-upload");
        File destination = directory.resolve("destination.bin").toFile();
        File partial = directory.resolve("partial.bin").toFile();
        try {
            Files.write(destination.toPath(), "old".getBytes(StandardCharsets.UTF_8));
            Files.write(partial.toPath(), "partial".getBytes(StandardCharsets.UTF_8));
            TrackingAppSandboxPartialOutput output =
                    new TrackingAppSandboxPartialOutput(true);
            RejectingAppSandboxCommitOperations operations =
                    new RejectingAppSandboxCommitOperations(output);
            AppSandboxUploadWriter writer = new AppSandboxUploadWriter(
                    destination,
                    partial,
                    output,
                    4,
                    0,
                    operations
            );

            try {
                writer.writeChunk(0, new byte[] {1, 2, 3, 4}, true);
                fail("expected partial synchronization to fail");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INTERNAL, exception.code);
                assertEquals("app sandbox upload write failed", exception.getMessage());
            }

            assertTrue(output.closed);
            assertEquals(1, output.synchronizeCount);
            assertEquals(0, operations.replaceCount);
            assertEquals("old", new String(
                    Files.readAllBytes(destination.toPath()),
                    StandardCharsets.UTF_8
            ));
            assertEquals("partial", new String(
                    Files.readAllBytes(partial.toPath()),
                    StandardCharsets.UTF_8
            ));
        } finally {
            Files.deleteIfExists(partial.toPath());
            Files.deleteIfExists(destination.toPath());
            Files.deleteIfExists(directory);
        }
    }

    @Test
    public void completedSafUploadRenamesPartialWithoutDeletingIt() throws Exception {
        FakeSafDocumentOperations operations = new FakeSafDocumentOperations();
        CloseTrackingOutputStream output = new CloseTrackingOutputStream();
        SafUploadWriter writer = new SafUploadWriter(
                operations, output, 4, 0, "final.bin", false, () -> {}
        );

        writer.writeChunk(0, new byte[] {1, 2, 3, 4}, true);
        writer.close();

        assertTrue(output.closed);
        assertEquals(1, operations.renameCount);
        assertEquals("final.bin", operations.renamedDisplayName);
        assertEquals(0, operations.deleteCount);
        assertEquals(4, output.size());
    }

    @Test
    public void providerSecurityFailuresMapToPermissionWithoutLeakingDetails() throws Exception {
        FakeSafDocumentOperations safOperations = new FakeSafDocumentOperations();
        SafUploadWriter safWriter = new SafUploadWriter(
                safOperations,
                new SecurityFailingOutputStream(),
                1,
                0,
                null,
                true,
                () -> {}
        );
        assertPermissionFailure(
                safWriter,
                "SAF write permission is required to upload this document"
        );
        assertEquals(1, safOperations.deleteCount);

        FakeMediaStoreEntryOperations mediaOperations =
                new FakeMediaStoreEntryOperations(true);
        MediaStoreUploadWriter mediaWriter = new MediaStoreUploadWriter(
                mediaOperations,
                new SecurityFailingOutputStream(),
                1,
                true
        );
        assertPermissionFailure(
                mediaWriter,
                "MediaStore write permission is required to upload this item"
        );
        assertEquals(1, mediaOperations.deleteCount);
        assertEquals(0, mediaOperations.publishCount);
        ProviderIoCleanup.closeQuietly(new SecurityFailingOutputStream());
    }

    @Test
    public void safUploadRechecksAuthorizationBeforeFinalCommit() throws Exception {
        FakeSafDocumentOperations operations = new FakeSafDocumentOperations();
        CloseTrackingOutputStream output = new CloseTrackingOutputStream();
        SafUploadWriter writer = new SafUploadWriter(
                operations,
                output,
                4,
                0,
                "final.bin",
                false,
                () -> {
                    throw new DmFileProvider.ProviderCatalogException(
                            ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                            "SAF write permission is required to upload this document"
                    );
                }
        );

        try {
            writer.writeChunk(0, new byte[] {1, 2, 3, 4}, true);
            fail("expected final commit authorization failure");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, exception.code);
            assertEquals(
                    "SAF write permission is required to upload this document",
                    exception.getMessage()
            );
        }

        assertTrue(output.closed);
        assertEquals(4, output.size());
        assertEquals(0, operations.renameCount);
        assertEquals(0, operations.deleteCount);
    }

    @Test
    public void mediaStoreUploadDeletesPendingItemWhenPublicationMissesIt() throws Exception {
        FakeMediaStoreEntryOperations operations = new FakeMediaStoreEntryOperations(false);
        CloseTrackingOutputStream output = new CloseTrackingOutputStream();
        MediaStoreUploadWriter writer = new MediaStoreUploadWriter(
                operations, output, 4, true
        );

        try {
            writer.writeChunk(0, new byte[] {1, 2, 3, 4}, true);
            fail("expected a zero-row MediaStore publication to fail");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_INTERNAL, exception.code);
            assertEquals("MediaStore upload write failed", exception.getMessage());
        }
        writer.close();

        assertTrue(output.closed);
        assertEquals(1, operations.publishCount);
        assertEquals(1, operations.deleteCount);
    }

    @Test
    public void mediaStoreUploadCommitsOnlyAfterPublicationSucceeds() throws Exception {
        FakeMediaStoreEntryOperations operations = new FakeMediaStoreEntryOperations(true);
        CloseTrackingOutputStream output = new CloseTrackingOutputStream();
        MediaStoreUploadWriter writer = new MediaStoreUploadWriter(
                operations, output, 4, true
        );

        writer.writeChunk(0, new byte[] {1, 2, 3, 4}, true);
        writer.close();

        assertTrue(output.closed);
        assertEquals(1, operations.publishCount);
        assertEquals(0, operations.deleteCount);
        assertEquals(4, output.size());
    }

    private static void expectInvalid(String message, ThrowingAction action) throws Exception {
        try {
            action.run();
            fail("expected upload boundary validation failure");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
            assertEquals(message, exception.getMessage());
        }
    }

    private static void assertPermissionFailure(
            DmFileProvider.UploadWriter writer,
            String expectedMessage
    ) throws Exception {
        try {
            writer.writeChunk(0, new byte[] {1}, true);
            fail("expected provider permission failure");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, exception.code);
            assertEquals(expectedMessage, exception.getMessage());
            assertTrue(!exception.getMessage().contains("content://private"));
        }
    }

    @FunctionalInterface
    private interface ThrowingAction {
        void run() throws Exception;
    }

    private static final class FakeSafDocumentOperations implements SafDocumentOperations {
        private int renameCount;
        private int deleteCount;
        private String renamedDisplayName;

        @Override
        public boolean rename(String displayName) {
            renameCount += 1;
            renamedDisplayName = displayName;
            return true;
        }

        @Override
        public void delete() {
            deleteCount += 1;
        }
    }

    private static final class SecurityFailingOutputStream extends OutputStream {
        @Override
        public void write(int value) {
            throw new SecurityException("content://private/document and stack detail");
        }

        @Override
        public void close() {
            throw new SecurityException("content://private/close detail");
        }
    }

    private static final class RejectingAppSandboxCommitOperations
            implements AppSandboxCommitOperations {
        private final TrackingAppSandboxPartialOutput output;
        private int replaceCount;
        private boolean partialWasSynchronized;
        private boolean partialWasClosed;

        private RejectingAppSandboxCommitOperations(
                TrackingAppSandboxPartialOutput output
        ) {
            this.output = output;
        }

        @Override
        public void replaceAtomically(File partialFile, File destinationFile)
                throws IOException {
            replaceCount += 1;
            partialWasSynchronized = output.synchronizeCount == 1;
            partialWasClosed = output.closed;
            throw new AtomicMoveNotSupportedException(
                    partialFile.getPath(),
                    destinationFile.getPath(),
                    "test filesystem rejects atomic replacement"
            );
        }
    }

    private static final class TrackingAppSandboxPartialOutput
            implements AppSandboxPartialOutput {
        private final ByteArrayOutputStream output = new ByteArrayOutputStream();
        private final boolean failSynchronization;
        private int synchronizeCount;
        private boolean closed;

        private TrackingAppSandboxPartialOutput(boolean failSynchronization) {
            this.failSynchronization = failSynchronization;
        }

        @Override
        public void write(byte[] data) throws IOException {
            output.write(data);
        }

        @Override
        public void synchronize() throws IOException {
            synchronizeCount += 1;
            if (failSynchronization) {
                throw new IOException("test synchronization failure");
            }
        }

        @Override
        public void close() {
            closed = true;
        }
    }

    private static final class FakeMediaStoreEntryOperations
            implements MediaStoreEntryOperations {
        private final boolean publishResult;
        private int publishCount;
        private int deleteCount;

        private FakeMediaStoreEntryOperations(boolean publishResult) {
            this.publishResult = publishResult;
        }

        @Override
        public boolean publish() {
            publishCount += 1;
            return publishResult;
        }

        @Override
        public void delete() {
            deleteCount += 1;
        }
    }

    private static final class CloseTrackingOutputStream extends ByteArrayOutputStream {
        private boolean closed;

        @Override
        public void close() throws IOException {
            closed = true;
            super.close();
        }
    }
}
