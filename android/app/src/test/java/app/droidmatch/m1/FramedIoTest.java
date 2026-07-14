package app.droidmatch.m1;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.fail;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;

import org.junit.Test;

public final class FramedIoTest {
    @Test
    public void writeFrameRejectsOversizedPayload() throws Exception {
        byte[] payload = new byte[FramedIo.MAX_ENVELOPE_LENGTH + 1];

        try {
            FramedIo.writeFrame(new ByteArrayOutputStream(), payload);
            fail("expected oversized frame to be rejected");
        } catch (IOException exception) {
            assertEquals(
                    "invalid envelope length: " + (FramedIo.MAX_ENVELOPE_LENGTH + 1),
                    exception.getMessage()
            );
        }
    }

    @Test
    public void readFrameRejectsOversizedLengthBeforePayloadRead() throws Exception {
        int length = FramedIo.MAX_ENVELOPE_LENGTH + 1;
        byte[] header = new byte[] {
                (byte) ((length >>> 24) & 0xff),
                (byte) ((length >>> 16) & 0xff),
                (byte) ((length >>> 8) & 0xff),
                (byte) (length & 0xff)
        };

        try {
            FramedIo.readFrame(new ByteArrayInputStream(header));
            fail("expected oversized frame header to be rejected");
        } catch (IOException exception) {
            assertEquals("invalid envelope length: " + length, exception.getMessage());
        }
    }

    @Test
    public void readFrameHandlesZeroProgressBeforeMakingProgress() throws Exception {
        byte[] frame = new byte[] {0x00, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03};

        assertArrayEquals(
                new byte[] {0x01, 0x02, 0x03},
                FramedIo.readFrame(new ZeroProgressInputStream(frame))
        );
    }

    @Test
    public void writeFrameUsesOneBulkHeaderWriteAndOnePayloadWrite() throws Exception {
        byte[] payload = new byte[] {0x01, 0x02, 0x03};
        CountingOutputStream output = new CountingOutputStream();

        FramedIo.writeFrame(output, payload);

        assertArrayEquals(
                new byte[] {0x00, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03},
                output.bytes.toByteArray()
        );
        assertEquals(0, output.singleByteWrites);
        assertEquals(2, output.bulkWrites);
        assertEquals(1, output.flushes);
    }

    private static final class CountingOutputStream extends java.io.OutputStream {
        private final ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        private int singleByteWrites;
        private int bulkWrites;
        private int flushes;

        @Override
        public void write(int value) {
            singleByteWrites += 1;
            bytes.write(value);
        }

        @Override
        public void write(byte[] buffer, int offset, int length) {
            bulkWrites += 1;
            bytes.write(buffer, offset, length);
        }

        @Override
        public void flush() {
            flushes += 1;
        }
    }

    private static final class ZeroProgressInputStream extends ByteArrayInputStream {
        private boolean returnedZero;

        private ZeroProgressInputStream(byte[] data) {
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
