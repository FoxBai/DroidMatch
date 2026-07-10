package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.fail;

import app.droidmatch.proto.v1.ErrorCode;

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
}
