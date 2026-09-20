package app.droidmatch.m1;

import static org.junit.Assert.*;

import app.droidmatch.proto.v1.ErrorCode;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import org.junit.Test;

public final class ProviderAudioArtworkTest {
    @Test public void permissionLossAtEveryStageClosesTheDerivativeAndRejectsPublication() throws Exception {
        // Revoke before admission, on open, while reading, and during decoding.
        for (int deniedAt : new int[] {0, 1, 2, 3}) {
            boolean[] allowed = {deniedAt != 0};
            boolean[] opened = {false}, closed = {false}, encoded = {false};
            try {
                ProviderAudioArtwork.load(96, () -> {
                    if (!allowed[0]) throw denied();
                }, () -> {
                    opened[0] = true;
                    if (deniedAt == 1) allowed[0] = false;
                    return new ByteArrayInputStream(new byte[] {1, 2, 3}) {
                        @Override public int read(byte[] bytes, int offset, int count) {
                            if (deniedAt == 2) allowed[0] = false;
                            return super.read(bytes, offset, count);
                        }
                        @Override public void close() { closed[0] = true; }
                    };
                }, (bytes, maximum) -> {
                    encoded[0] = true;
                    if (deniedAt == 3) allowed[0] = false;
                    return result(maximum);
                });
                fail("revoked artwork must not be published");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, exception.code);
            }
            assertEquals(opened[0], closed[0]);
            assertEquals(deniedAt == 3, encoded[0]);
        }
    }

    @Test public void oversizedAndInterruptedSourcesNeverReachTheDecoder() throws Exception {
        int[] consumed = {0};
        boolean[] closed = {false};
        InputStream infinite = new InputStream() {
            @Override public int read() { consumed[0]++; return 0; }
            @Override public int read(byte[] bytes, int offset, int count) {
                consumed[0] += count;
                return count;
            }
            @Override public void close() { closed[0] = true; }
        };
        try {
            ProviderAudioArtwork.load(96, () -> {}, () -> infinite, (bytes, maximum) -> {
                fail("oversized input reached decoder"); return null;
            });
            fail("oversized input was accepted");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, exception.code);
        }
        assertEquals(ProviderAudioArtwork.MAX_INPUT_BYTES + 1, consumed[0]);
        assertTrue(closed[0]);
        Thread.currentThread().interrupt();
        try {
            ProviderAudioArtwork.load(96, () -> {}, () -> {
                fail("interrupted request opened a source"); return null;
            }, (bytes, maximum) -> null);
            fail("interruption was ignored");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_CANCELLED, exception.code);
        } finally {
            Thread.interrupted();
        }
    }

    @Test public void decodingAndEncodingBudgetsRejectBombsWithoutBreakingOrdinaryCovers() throws Exception {
        assertFalse(ProviderAudioArtwork.supported(28));
        assertTrue(ProviderAudioArtwork.supported(29));
        assertArrayEquals(new int[] {512, 256}, ProviderAudioArtwork.targetSize(4096, 2048, 512));
        assertArrayEquals(new int[] {1, 96}, ProviderAudioArtwork.targetSize(1, 8192, 96));
        for (int[] dimensions : new int[][] {{0, 2}, {2, -1}, {8193, 1}, {8192, 8192}}) {
            assertThrows(IllegalArgumentException.class,
                    () -> ProviderAudioArtwork.targetSize(dimensions[0], dimensions[1], 512));
        }
        ProviderAudioArtwork.EncodedOutput output = new ProviderAudioArtwork.EncodedOutput();
        output.write(new byte[ProviderAudioArtwork.MAX_OUTPUT_BYTES]);
        assertThrows(IOException.class, () -> output.write(1));
        assertEquals(ProviderAudioArtwork.MAX_OUTPUT_BYTES, output.toByteArray().length);
        ProviderThumbnail cover = ProviderAudioArtwork.load(96, () -> {},
                () -> new ByteArrayInputStream(new byte[] {1}), (bytes, maximum) -> result(maximum));
        assertEquals(96, cover.widthPx);
        assertThrows(DmFileProvider.ProviderCatalogException.class,
                () -> ProviderAudioArtwork.load(96, () -> {},
                        () -> new ByteArrayInputStream(new byte[] {1}), (bytes, maximum) -> result(513)));
    }

    private static ProviderThumbnail result(int dimension) {
        return new ProviderThumbnail(new byte[] {1, 2, 3}, "image/jpeg", dimension, dimension);
    }

    private static DmFileProvider.ProviderCatalogException denied() {
        return new DmFileProvider.ProviderCatalogException(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, "denied");
    }
}
