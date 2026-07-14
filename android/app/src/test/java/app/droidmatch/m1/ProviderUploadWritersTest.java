package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import app.droidmatch.proto.v1.ErrorCode;

import java.io.ByteArrayOutputStream;
import java.io.IOException;

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
                operations, output, 4, 0, null, true
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
                operations, output, 4, 0, "final.bin", false
        );

        writer.close();

        assertTrue(output.closed);
        assertEquals(0, operations.deleteCount);
        assertEquals(0, operations.renameCount);
    }

    @Test
    public void completedSafUploadRenamesPartialWithoutDeletingIt() throws Exception {
        FakeSafDocumentOperations operations = new FakeSafDocumentOperations();
        CloseTrackingOutputStream output = new CloseTrackingOutputStream();
        SafUploadWriter writer = new SafUploadWriter(
                operations, output, 4, 0, "final.bin", false
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
