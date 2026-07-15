package app.droidmatch.m1;

import static app.droidmatch.m1.CursorTestFixture.cursor;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import android.provider.DocumentsContract;

import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;

import org.junit.Test;

public final class SafUploadOpenPolicyTest {
    @Test
    public void freshUploadRequiresOffsetZero() throws Exception {
        assertEquals(SafUploadOpenPolicy.Mode.FRESH, SafUploadOpenPolicy.mode("", 0));

        assertFailure(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "SAF upload resume requires a transfer_id",
                () -> SafUploadOpenPolicy.mode("", 1)
        );
    }

    @Test
    public void transferIdSeparatesRestartFromResume() throws Exception {
        assertEquals(
                SafUploadOpenPolicy.Mode.RESTART_RESUMABLE,
                SafUploadOpenPolicy.mode("transfer", 0)
        );
        assertEquals(
                SafUploadOpenPolicy.Mode.RESUME,
                SafUploadOpenPolicy.mode("transfer", 1)
        );
    }

    @Test
    public void resumeRequiresAnExistingFilePartial() throws Exception {
        assertFailure(
                ErrorCode.ERROR_CODE_NOT_FOUND,
                "SAF upload partial is not available",
                () -> SafUploadOpenPolicy.requiresTruncation(null, 3)
        );
        assertFailure(
                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                "SAF upload partial must identify a file entry",
                () -> SafUploadOpenPolicy.requiresTruncation(
                        partial("directory", FileKind.FILE_KIND_DIRECTORY, -1),
                        3
                )
        );
    }

    @Test
    public void resumeRejectsPartialBehindAcknowledgedOffset() throws Exception {
        assertFailure(
                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                "requested_offset_bytes does not match SAF upload partial",
                () -> SafUploadOpenPolicy.requiresTruncation(
                        partial("partial", FileKind.FILE_KIND_FILE, 2),
                        3
                )
        );
    }

    @Test
    public void resumeTruncatesOnlyAnAheadPartial() throws Exception {
        assertFalse(SafUploadOpenPolicy.requiresTruncation(
                partial("exact", FileKind.FILE_KIND_FILE, 3),
                3
        ));
        assertTrue(SafUploadOpenPolicy.requiresTruncation(
                partial("ahead", FileKind.FILE_KIND_FILE, 4),
                3
        ));
    }

    private static SafDocumentCursorReader.ChildDocument partial(
            String documentId,
            FileKind kind,
            long sizeBytes
    ) {
        String mimeType = kind == FileKind.FILE_KIND_DIRECTORY
                ? DocumentsContract.Document.MIME_TYPE_DIR
                : "application/octet-stream";
        int flags = kind == FileKind.FILE_KIND_VIRTUAL
                ? DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT
                : 0;
        return SafDocumentCursorReader.childByDisplayName(
                cursor(
                        SafDocumentCursorReader.projection(),
                        new Object[][] { new Object[] {
                                documentId,
                                documentId,
                                mimeType,
                                sizeBytes,
                                0L,
                                flags
                        } }
                ),
                documentId
        );
    }

    private static void assertFailure(
            ErrorCode code,
            String message,
            ThrowingRunnable action
    ) throws Exception {
        try {
            action.run();
            fail("expected provider catalog failure");
        } catch (ProviderCatalogException exception) {
            assertEquals(code, exception.code);
            assertEquals(message, exception.getMessage());
        }
    }

    private interface ThrowingRunnable {
        void run() throws Exception;
    }
}
