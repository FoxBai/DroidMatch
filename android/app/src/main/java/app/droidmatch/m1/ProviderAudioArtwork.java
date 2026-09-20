package app.droidmatch.m1;

import app.droidmatch.proto.v1.ErrorCode;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/** App-owned artwork budgets; the platform provider owns thumbnail generation.
 * 中文：只读取有界图片派生物，不提取原始音频中的嵌入封面。 */
final class ProviderAudioArtwork {
    static final int MAX_INPUT_BYTES = 2 * 1024 * 1024;
    static final int MAX_OUTPUT_BYTES = 512 * 1024;

    static boolean supported(int apiLevel) { return apiLevel >= 29; }

    static ProviderThumbnail load(
            int maxDimension,
            ProviderLiveAuthorization authorization,
            Source source,
            Encoder encoder
    ) throws DmFileProvider.ProviderCatalogException, IOException {
        if (maxDimension < 32 || maxDimension > 512) {
            throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
        }
        check(authorization);
        byte[] encoded;
        try (InputStream input = source.open()) {
            check(authorization);
            if (input == null) throw error(ErrorCode.ERROR_CODE_NOT_FOUND);
            ByteArrayOutputStream bytes = new ByteArrayOutputStream(16 * 1024);
            byte[] buffer = new byte[16 * 1024];
            while (true) {
                check(authorization);
                int count = input.read(buffer, 0,
                        Math.min(buffer.length, MAX_INPUT_BYTES - bytes.size() + 1));
                if (count == -1) break;
                if (count <= 0 || count > MAX_INPUT_BYTES - bytes.size()) {
                    throw error(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY);
                }
                bytes.write(buffer, 0, count);
            }
            encoded = bytes.toByteArray();
        }
        check(authorization);
        if (encoded.length == 0) throw error(ErrorCode.ERROR_CODE_NOT_FOUND);
        ProviderThumbnail result = encoder.encode(encoded, maxDimension);
        check(authorization);
        if (result == null || result.encodedImage == null || result.encodedImage.length == 0
                || result.encodedImage.length > MAX_OUTPUT_BYTES
                || !"image/jpeg".equals(result.mimeType)
                || result.widthPx <= 0 || result.heightPx <= 0
                || result.widthPx > maxDimension || result.heightPx > maxDimension) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL);
        }
        return result;
    }

    /** Called from the decoder's header callback, before pixel allocation. */
    static int[] targetSize(int width, int height, int maximum) {
        if (maximum < 32 || maximum > 512 || width <= 0 || height <= 0
                || width > 8192 || height > 8192 || (long) width * height > 32 * 1024 * 1024) {
            throw new IllegalArgumentException("artwork image dimensions are unsupported");
        }
        double scale = Math.min(1.0, (double) maximum / Math.max(width, height));
        return new int[] {Math.max(1, (int) (width * scale)),
                Math.max(1, (int) (height * scale))};
    }

    private static void check(ProviderLiveAuthorization authorization)
            throws DmFileProvider.ProviderCatalogException {
        if (Thread.currentThread().isInterrupted()) throw error(ErrorCode.ERROR_CODE_CANCELLED);
        authorization.requireAuthorized();
    }

    private static DmFileProvider.ProviderCatalogException error(ErrorCode code) {
        return new DmFileProvider.ProviderCatalogException(code, "audio artwork is unavailable");
    }

    @FunctionalInterface interface Source {
        InputStream open() throws IOException, DmFileProvider.ProviderCatalogException;
    }

    @FunctionalInterface interface Encoder {
        ProviderThumbnail encode(byte[] input, int maximum) throws IOException;
    }

    /** Stop compression at the byte budget, before a large byte array is built. */
    static final class EncodedOutput extends OutputStream {
        private final ByteArrayOutputStream bytes = new ByteArrayOutputStream(16 * 1024);

        @Override public void write(int value) throws IOException {
            requireRoom(1);
            bytes.write(value);
        }

        @Override public void write(byte[] buffer, int offset, int length) throws IOException {
            if (offset < 0 || length < 0 || offset > buffer.length - length) {
                throw new IndexOutOfBoundsException();
            }
            requireRoom(length);
            bytes.write(buffer, offset, length);
        }

        private void requireRoom(int count) throws IOException {
            if (count > MAX_OUTPUT_BYTES - bytes.size()) {
                throw new IOException("audio artwork exceeds output budget");
            }
        }

        byte[] toByteArray() { return bytes.toByteArray(); }
    }
}
