package app.droidmatch.m1;

import android.content.ContentResolver;
import android.net.Uri;
import android.os.ParcelFileDescriptor;

import app.droidmatch.proto.v1.ErrorCode;

import java.io.Closeable;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.channels.FileChannel;
import java.util.Arrays;

/**
 * Provider download reader factories and stream mechanics.
 *
 * <p>{@link DmFileProvider} owns logical path, permission, and catalog routing.
 * This class owns offset positioning, bounded sequential reads, EOF/final-chunk
 * detection, and descriptor teardown only.</p>
 */
final class ProviderDownloadReaders {
    private ProviderDownloadReaders() {
    }

    static DmFileProvider.DownloadReader oneShot(DmFileProvider.DownloadChunk chunk) {
        return new OneShotDownloadReader(chunk);
    }

    static DmFileProvider.DownloadReader stream(
            InputStream inputStream,
            long nextOffsetBytes,
            int chunkSizeBytes,
            long totalSizeBytes,
            long modifiedUnixMillis,
            String providerEtag,
            ErrorCode securityFailureCode,
            String securityFailureMessage,
            String readFailureMessage
    ) {
        return new StreamDownloadReader(
                inputStream,
                null,
                nextOffsetBytes,
                chunkSizeBytes,
                totalSizeBytes,
                modifiedUnixMillis,
                providerEtag,
                securityFailureCode,
                securityFailureMessage,
                readFailureMessage
        );
    }

    static DmFileProvider.DownloadReader seekableOrNull(
            ContentResolver contentResolver,
            Uri uri,
            long offsetBytes,
            int chunkSizeBytes,
            long totalSizeBytes,
            long modifiedUnixMillis,
            String providerEtag,
            String permissionMessage,
            String readFailureMessage
    ) throws DmFileProvider.ProviderCatalogException {
        if (totalSizeBytes >= 0 && offsetBytes > totalSizeBytes) {
            throw new DmFileProvider.ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "requested_offset_bytes is beyond end of file"
            );
        }

        ParcelFileDescriptor parcelFileDescriptor = null;
        FileInputStream inputStream = null;
        try {
            parcelFileDescriptor = contentResolver.openFileDescriptor(uri, "r");
            if (parcelFileDescriptor == null) {
                return null;
            }
            inputStream = new FileInputStream(parcelFileDescriptor.getFileDescriptor());
            FileChannel channel = inputStream.getChannel();
            channel.position(offsetBytes);
            return new StreamDownloadReader(
                    inputStream,
                    parcelFileDescriptor,
                    offsetBytes,
                    chunkSizeBytes,
                    totalSizeBytes,
                    modifiedUnixMillis,
                    providerEtag,
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    permissionMessage,
                    readFailureMessage
            );
        } catch (SecurityException exception) {
            closeQuietly(inputStream);
            closeQuietly(parcelFileDescriptor);
            throw new DmFileProvider.ProviderCatalogException(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    permissionMessage
            );
        } catch (IOException | RuntimeException exception) {
            closeQuietly(inputStream);
            closeQuietly(parcelFileDescriptor);
            return null;
        }
    }

    static void skipFully(InputStream inputStream, long offsetBytes)
            throws IOException, DmFileProvider.ProviderCatalogException {
        long remaining = offsetBytes;
        while (remaining > 0) {
            long skipped = inputStream.skip(remaining);
            if (skipped > 0) {
                remaining -= skipped;
                continue;
            }
            if (inputStream.read() == -1) {
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "requested_offset_bytes is beyond end of file"
                );
            }
            remaining--;
        }
    }

    static byte[] readAtMost(InputStream inputStream, int byteCount) throws IOException {
        byte[] buffer = new byte[byteCount];
        int offset = 0;
        while (offset < byteCount) {
            int read = inputStream.read(buffer, offset, byteCount - offset);
            if (read == -1) {
                break;
            }
            if (read == 0) {
                // InputStream should make progress for a positive request, but a
                // provider wrapper may legally be imperfect. Fall back to one
                // byte so a stalled provider cannot spin the session thread.
                int nextByte = inputStream.read();
                if (nextByte == -1) {
                    break;
                }
                buffer[offset] = (byte) nextByte;
                offset += 1;
                continue;
            }
            offset += read;
        }

        // The old 64 KiB ByteArrayOutputStream path repeatedly expanded and
        // recopied every large chunk. A negotiated full chunk now owns exactly
        // one provider buffer; only the final short chunk needs trimming.
        return offset == byteCount ? buffer : Arrays.copyOf(buffer, offset);
    }

    private static void closeQuietly(Closeable closeable) {
        if (closeable == null) {
            return;
        }
        try {
            closeable.close();
        } catch (IOException | SecurityException ignored) {
        }
    }

    private static final class OneShotDownloadReader implements DmFileProvider.DownloadReader {
        private final DmFileProvider.DownloadChunk chunk;
        private boolean consumed;

        private OneShotDownloadReader(DmFileProvider.DownloadChunk chunk) {
            this.chunk = chunk;
        }

        @Override
        public DmFileProvider.DownloadChunk readNextChunk()
                throws DmFileProvider.ProviderCatalogException {
            if (consumed) {
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "download reader has no remaining chunks"
                );
            }
            consumed = true;
            return chunk;
        }

        @Override
        public void close() {
        }
    }

    private static final class StreamDownloadReader implements DmFileProvider.DownloadReader {
        private final InputStream inputStream;
        private final Closeable extraCloseable;
        private final int chunkSizeBytes;
        private final long totalSizeBytes;
        private final long modifiedUnixMillis;
        private final String providerEtag;
        private final ErrorCode securityFailureCode;
        private final String securityFailureMessage;
        private final String readFailureMessage;
        private long nextOffsetBytes;
        private boolean closed;

        private StreamDownloadReader(
                InputStream inputStream,
                Closeable extraCloseable,
                long nextOffsetBytes,
                int chunkSizeBytes,
                long totalSizeBytes,
                long modifiedUnixMillis,
                String providerEtag,
                ErrorCode securityFailureCode,
                String securityFailureMessage,
                String readFailureMessage
        ) {
            this.inputStream = inputStream;
            this.extraCloseable = extraCloseable;
            this.nextOffsetBytes = nextOffsetBytes;
            this.chunkSizeBytes = chunkSizeBytes;
            this.totalSizeBytes = totalSizeBytes;
            this.modifiedUnixMillis = modifiedUnixMillis;
            this.providerEtag = providerEtag;
            this.securityFailureCode = securityFailureCode;
            this.securityFailureMessage = securityFailureMessage;
            this.readFailureMessage = readFailureMessage;
        }

        @Override
        public DmFileProvider.DownloadChunk readNextChunk()
                throws DmFileProvider.ProviderCatalogException {
            if (closed) {
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "download reader is closed"
                );
            }

            try {
                byte[] data = readAtMost(inputStream, chunkSizeBytes);
                boolean finalChunk = data.length < chunkSizeBytes
                        || (totalSizeBytes >= 0
                        && nextOffsetBytes + data.length >= totalSizeBytes);
                nextOffsetBytes += data.length;
                if (finalChunk) {
                    close();
                }
                return new DmFileProvider.DownloadChunk(
                        data,
                        totalSizeBytes,
                        modifiedUnixMillis,
                        providerEtag,
                        finalChunk
                );
            } catch (SecurityException exception) {
                close();
                throw new DmFileProvider.ProviderCatalogException(
                        securityFailureCode,
                        securityFailureMessage
                );
            } catch (IOException exception) {
                close();
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        readFailureMessage
                );
            }
        }

        @Override
        public void close() {
            if (closed) {
                return;
            }
            closed = true;
            closeQuietly(inputStream);
            closeQuietly(extraCloseable);
        }
    }
}
