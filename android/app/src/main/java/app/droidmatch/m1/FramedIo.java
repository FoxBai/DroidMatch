package app.droidmatch.m1;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

public final class FramedIo {
    public static final int MAX_ENVELOPE_LENGTH = 4 * 1024 * 1024;

    private FramedIo() {
    }

    public static byte[] readFrame(InputStream input) throws IOException {
        byte[] header = readExactly(input, 4);
        int length = ((header[0] & 0xff) << 24)
                | ((header[1] & 0xff) << 16)
                | ((header[2] & 0xff) << 8)
                | (header[3] & 0xff);

        if (length <= 0 || length > MAX_ENVELOPE_LENGTH) {
            throw new IOException("invalid envelope length: " + length);
        }

        return readExactly(input, length);
    }

    public static void writeFrame(OutputStream output, byte[] payload) throws IOException {
        if (payload.length == 0 || payload.length > MAX_ENVELOPE_LENGTH) {
            throw new IOException("invalid envelope length: " + payload.length);
        }

        byte[] header = new byte[] {
                (byte) ((payload.length >>> 24) & 0xff),
                (byte) ((payload.length >>> 16) & 0xff),
                (byte) ((payload.length >>> 8) & 0xff),
                (byte) (payload.length & 0xff)
        };
        // SocketOutputStream.write(int) crosses the Java/native boundary for
        // every byte on older Android releases. Keep the same wire framing but
        // submit the header as one bulk write before the payload.
        output.write(header);
        output.write(payload);
        output.flush();
    }

    private static byte[] readExactly(InputStream input, int length) throws IOException {
        byte[] buffer = new byte[length];
        int offset = 0;
        while (offset < length) {
            int read = input.read(buffer, offset, length - offset);
            if (read == -1) {
                throw new EOFException("expected " + length + " bytes, got " + offset);
            }
            if (read == 0) {
                // A provider-backed or non-blocking wrapper may report no
                // progress even for a positive request. Consume one byte so a
                // malformed wrapper cannot spin the endpoint forever.
                int nextByte = input.read();
                if (nextByte == -1) {
                    throw new EOFException("expected " + length + " bytes, got " + offset);
                }
                buffer[offset] = (byte) nextByte;
                offset += 1;
                continue;
            }
            offset += read;
        }
        return buffer;
    }
}
