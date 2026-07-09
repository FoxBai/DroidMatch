package app.droidmatch.m1;

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
}
