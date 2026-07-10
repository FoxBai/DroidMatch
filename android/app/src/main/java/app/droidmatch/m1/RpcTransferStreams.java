package app.droidmatch.m1;

import app.droidmatch.proto.v1.ErrorCode;

import java.util.ArrayDeque;
import java.util.Deque;

/** Per-stream transfer state with ACK-bounded download progress. */
final class RpcTransferStreams {
    private static final int MAX_DOWNLOAD_IN_FLIGHT_CHUNKS = 4;
    private static final int MAX_DOWNLOAD_IN_FLIGHT_BYTES = 2 * 1024 * 1024;

    private RpcTransferStreams() {
    }

    static final class Download {
        final String transferId;
        final int chunkSizeBytes;
        long acknowledgedOffsetBytes;
        long nextSendOffsetBytes;

        private final DmFileProvider.DownloadReader reader;
        private final Deque<SentChunk> outstandingChunks = new ArrayDeque<>();
        private boolean finalChunkSent;

        Download(
                String transferId,
                DmFileProvider.DownloadReader reader,
                int chunkSizeBytes,
                long startingOffsetBytes
        ) {
            this.transferId = transferId;
            this.reader = reader;
            this.chunkSizeBytes = chunkSizeBytes;
            acknowledgedOffsetBytes = startingOffsetBytes;
            nextSendOffsetBytes = startingOffsetBytes;
        }

        DmFileProvider.DownloadChunk readNextChunk() throws DmFileProvider.ProviderCatalogException {
            return reader.readNextChunk();
        }

        void recordSent(long offsetBytes, DmFileProvider.DownloadChunk chunk) {
            long nextOffset = offsetBytes + chunk.data.length;
            outstandingChunks.addLast(new SentChunk(nextOffset, chunk.finalChunk));
            nextSendOffsetBytes = nextOffset;
            finalChunkSent = finalChunkSent || chunk.finalChunk;
        }

        Ack recordAck(long nextOffsetBytes, boolean finalAck) {
            SentChunk sentChunk = outstandingChunks.peekFirst();
            if (sentChunk == null) {
                return Ack.error(
                        ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                        "transfer ack received with no outstanding chunk",
                        false
                );
            }
            if (nextOffsetBytes != sentChunk.nextOffsetBytes) {
                return Ack.error(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "next_offset_bytes does not match the next sent chunk boundary",
                        false
                );
            }
            if (sentChunk.finalChunk && !finalAck) {
                return Ack.error(
                        ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                        "final chunk requires final_ack",
                        true
                );
            }
            if (!sentChunk.finalChunk && finalAck) {
                return Ack.error(
                        ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                        "final_ack received before final chunk",
                        true
                );
            }

            outstandingChunks.removeFirst();
            acknowledgedOffsetBytes = nextOffsetBytes;
            return sentChunk.finalChunk ? Ack.finalAcknowledged() : Ack.ok();
        }

        boolean canSendMore() {
            if (finalChunkSent || outstandingChunks.size() >= MAX_DOWNLOAD_IN_FLIGHT_CHUNKS) {
                return false;
            }
            long outstandingBytes = nextSendOffsetBytes - acknowledgedOffsetBytes;
            return outstandingBytes + chunkSizeBytes <= MAX_DOWNLOAD_IN_FLIGHT_BYTES;
        }

        void close() {
            reader.close();
        }
    }

    static final class Upload {
        final String transferId;
        final int chunkSizeBytes;

        private final DmFileProvider.UploadWriter writer;

        Upload(String transferId, DmFileProvider.UploadWriter writer, int chunkSizeBytes) {
            this.transferId = transferId;
            this.writer = writer;
            this.chunkSizeBytes = chunkSizeBytes;
        }

        long nextOffsetBytes() {
            return writer.nextOffsetBytes();
        }

        void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
                throws DmFileProvider.ProviderCatalogException {
            writer.writeChunk(offsetBytes, data, finalChunk);
        }

        void close() {
            writer.close();
        }
    }

    static final class Ack {
        final boolean finalAcknowledged;
        final ErrorCode errorCode;
        final String error;
        final boolean closeTransfer;

        private Ack(
                boolean finalAcknowledged,
                ErrorCode errorCode,
                String error,
                boolean closeTransfer
        ) {
            this.finalAcknowledged = finalAcknowledged;
            this.errorCode = errorCode;
            this.error = error;
            this.closeTransfer = closeTransfer;
        }

        private static Ack ok() {
            return new Ack(false, null, null, false);
        }

        private static Ack finalAcknowledged() {
            return new Ack(true, null, null, true);
        }

        private static Ack error(ErrorCode errorCode, String error, boolean closeTransfer) {
            return new Ack(false, errorCode, error, closeTransfer);
        }
    }

    private static final class SentChunk {
        private final long nextOffsetBytes;
        private final boolean finalChunk;

        private SentChunk(long nextOffsetBytes, boolean finalChunk) {
            this.nextOffsetBytes = nextOffsetBytes;
            this.finalChunk = finalChunk;
        }
    }
}
