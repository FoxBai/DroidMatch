package app.droidmatch.m1;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import app.droidmatch.proto.v1.ErrorCode;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

import org.junit.Test;

public final class ProviderDownloadReadersTest {
    @Test
    public void streamReaderPreservesChunkMetadataAndClosesAtKnownTotal() throws Exception {
        CloseTrackingInputStream input = new CloseTrackingInputStream(bytes("abcdef"));
        DmFileProvider.DownloadReader reader = ProviderDownloadReaders.stream(
                input,
                0,
                4,
                6,
                123,
                "opaque-etag",
                ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                "provider permission is required",
                "provider read failed"
        );

        DmFileProvider.DownloadChunk first = reader.readNextChunk();
        DmFileProvider.DownloadChunk second = reader.readNextChunk();

        assertArrayEquals(bytes("abcd"), first.data);
        assertFalse(first.finalChunk);
        assertArrayEquals(bytes("ef"), second.data);
        assertTrue(second.finalChunk);
        assertEquals(6, second.totalSizeBytes);
        assertEquals(123, second.modifiedUnixMillis);
        assertEquals("opaque-etag", second.providerEtag);
        assertTrue(input.closed);
        expectInvalid("download reader is closed", reader::readNextChunk);
    }

    @Test
    public void streamReaderTreatsShortReadAsFinalWhenSizeIsUnknown() throws Exception {
        DmFileProvider.DownloadReader reader = ProviderDownloadReaders.stream(
                new ByteArrayInputStream(bytes("abc")),
                8,
                4,
                -1,
                0,
                "stream",
                ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                "stream permission is required",
                "stream read failed"
        );

        DmFileProvider.DownloadChunk chunk = reader.readNextChunk();

        assertArrayEquals(bytes("abc"), chunk.data);
        assertEquals(-1, chunk.totalSizeBytes);
        assertTrue(chunk.finalChunk);
    }

    @Test
    public void streamReaderMapsSecurityFailureWithoutLeakingProviderDetails() throws Exception {
        SecurityFailingInputStream input = new SecurityFailingInputStream();
        DmFileProvider.DownloadReader reader = ProviderDownloadReaders.stream(
                input,
                0,
                4,
                -1,
                0,
                "stream",
                ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                "SAF permission is required to read this document",
                "SAF read failed"
        );

        try {
            reader.readNextChunk();
            fail("expected provider permission failure");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, exception.code);
            assertEquals(
                    "SAF permission is required to read this document",
                    exception.getMessage()
            );
        }

        reader.close();
        assertEquals(1, input.closeCount);
        expectInvalid("download reader is closed", reader::readNextChunk);
    }

    @Test
    public void streamReaderDoesNotMisreportAppSandboxSecurityFailureAsPermission() throws Exception {
        SecurityFailingInputStream input = new SecurityFailingInputStream();
        DmFileProvider.DownloadReader reader = ProviderDownloadReaders.stream(
                input,
                0,
                4,
                -1,
                0,
                "stream",
                ErrorCode.ERROR_CODE_INTERNAL,
                "app sandbox read failed",
                "app sandbox read failed"
        );

        try {
            reader.readNextChunk();
            fail("expected app sandbox read failure");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_INTERNAL, exception.code);
            assertEquals("app sandbox read failed", exception.getMessage());
        }

        reader.close();
        assertEquals(1, input.closeCount);
    }

    @Test
    public void oneShotReaderReturnsItsExactChunkOnlyOnce() throws Exception {
        DmFileProvider.DownloadChunk expected = new DmFileProvider.DownloadChunk(
                bytes("x"),
                1,
                2,
                "one-shot",
                true
        );
        DmFileProvider.DownloadReader reader = ProviderDownloadReaders.oneShot(expected);

        reader.close();
        assertSame(expected, reader.readNextChunk());
        expectInvalid("download reader has no remaining chunks", reader::readNextChunk);
    }

    @Test
    public void skipFullyFallsBackToSingleByteReadsAndRejectsPastEnd() throws Exception {
        ByteArrayInputStream noSkip = new ByteArrayInputStream(bytes("abc")) {
            @Override
            public synchronized long skip(long byteCount) {
                return 0;
            }
        };
        ProviderDownloadReaders.skipFully(noSkip, 2);
        assertArrayEquals(bytes("c"), ProviderDownloadReaders.readAtMost(noSkip, 2));

        try {
            ProviderDownloadReaders.skipFully(new ByteArrayInputStream(bytes("a")), 2);
            fail("expected offset past end to fail");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
            assertEquals("requested_offset_bytes is beyond end of file", exception.getMessage());
        }
    }

    @Test
    public void readAtMostFillsOneBufferAcrossShortAndZeroProgressReads() throws Exception {
        IntermittentInputStream input = new IntermittentInputStream(bytes("abcdef"));

        assertArrayEquals(bytes("abcdef"), ProviderDownloadReaders.readAtMost(input, 6));
        assertEquals(0, input.available());
    }

    @Test
    public void readAtMostDoesNotOverreadAndTrimsOnlyAtEof() throws Exception {
        ByteArrayInputStream input = new ByteArrayInputStream(bytes("abcdef"));

        assertArrayEquals(bytes("abc"), ProviderDownloadReaders.readAtMost(input, 3));
        assertArrayEquals(bytes("def"), ProviderDownloadReaders.readAtMost(input, 8));
        assertArrayEquals(new byte[0], ProviderDownloadReaders.readAtMost(input, 0));
    }

    @Test
    public void seekableReaderRejectsOffsetPastKnownSizeBeforeOpeningProvider() throws Exception {
        try {
            ProviderDownloadReaders.seekableOrNull(
                    null,
                    null,
                    2,
                    1,
                    1,
                    0,
                    "etag",
                    "permission",
                    "read"
            );
            fail("expected offset past known size to fail");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
            assertEquals("requested_offset_bytes is beyond end of file", exception.getMessage());
        }
    }

    private static void expectInvalid(String message, ThrowingRead action) throws Exception {
        try {
            action.run();
            fail("expected reader state failure");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
            assertEquals(message, exception.getMessage());
        }
    }

    private static byte[] bytes(String value) {
        return value.getBytes(StandardCharsets.UTF_8);
    }

    @FunctionalInterface
    private interface ThrowingRead {
        DmFileProvider.DownloadChunk run() throws Exception;
    }

    private static final class CloseTrackingInputStream extends ByteArrayInputStream {
        private boolean closed;

        private CloseTrackingInputStream(byte[] data) {
            super(data);
        }

        @Override
        public void close() throws IOException {
            closed = true;
            super.close();
        }
    }

    private static final class SecurityFailingInputStream extends InputStream {
        private int closeCount;

        @Override
        public int read() {
            throw new SecurityException("content://private/document and stack detail");
        }

        @Override
        public void close() {
            closeCount += 1;
            throw new SecurityException("content://private/close detail");
        }
    }

    private static final class IntermittentInputStream extends ByteArrayInputStream {
        private boolean returnedZero;

        private IntermittentInputStream(byte[] data) {
            super(data);
        }

        @Override
        public synchronized int read(byte[] buffer, int offset, int length) {
            if (!returnedZero) {
                returnedZero = true;
                return 0;
            }
            return super.read(buffer, offset, Math.min(length, 2));
        }
    }
}
