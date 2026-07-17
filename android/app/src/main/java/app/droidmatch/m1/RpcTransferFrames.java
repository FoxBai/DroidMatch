package app.droidmatch.m1;

import app.droidmatch.proto.v1.CancelTransferResponse;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.DiscardUploadPartialResponse;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.OpenTransferResponse;
import app.droidmatch.proto.v1.PauseTransferResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.TransferChunk;
import app.droidmatch.proto.v1.TransferFingerprint;

import com.google.protobuf.ByteString;

import java.util.zip.CRC32;

/**
 * Pure transfer wire construction and validation helpers.
 *
 * <p>This boundary owns no session, registry, provider handle, or diagnostics
 * state. Keeping protobuf construction here lets {@link RpcTransferHandler}
 * retain only transfer routing and resource-lifecycle decisions.</p>
 */
final class RpcTransferFrames {
    private static final int DEFAULT_TRANSFER_CHUNK_SIZE_BYTES = 256 * 1024;
    private static final int MAX_TRANSFER_CHUNK_SIZE_BYTES = 1024 * 1024;

    private RpcTransferFrames() {}

    static int negotiatedChunkSize(int preferredChunkSizeBytes) {
        long requestedSize = Integer.toUnsignedLong(preferredChunkSizeBytes);
        return requestedSize == 0
                ? DEFAULT_TRANSFER_CHUNK_SIZE_BYTES
                : (int) Math.min(requestedSize, MAX_TRANSFER_CHUNK_SIZE_BYTES);
    }

    static int crc32(byte[] data) {
        CRC32 crc32 = new CRC32();
        crc32.update(data);
        return (int) crc32.getValue();
    }

    static boolean fingerprintsMatch(TransferFingerprint expected, TransferFingerprint actual) {
        return expected.getSizeBytes() == actual.getSizeBytes()
                && expected.getModifiedUnixMillis() == actual.getModifiedUnixMillis()
                && expected.getProviderEtag().equals(actual.getProviderEtag())
                && expected.getSha256().equals(actual.getSha256());
    }

    static TransferChunk transferChunk(
            String transferId,
            long offsetBytes,
            DmFileProvider.DownloadChunk chunk
    ) {
        return TransferChunk.newBuilder()
                .setTransferId(transferId)
                .setOffsetBytes(offsetBytes)
                .setData(ByteString.copyFrom(chunk.data))
                .setCrc32(crc32(chunk.data))
                .setFinalChunk(chunk.finalChunk)
                .build();
    }

    static RpcEnvelope errorEnvelope(long requestId, ErrorCode code, String message) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(RpcDispatcher.FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_ERROR)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_DROIDMATCH_ERROR)
                .setError(error(code, message))
                .build();
    }

    static RpcEnvelope openTransferResponse(
            long requestId,
            String transferId,
            long acceptedOffsetBytes,
            int chunkSizeBytes,
            long totalSizeBytes,
            long streamId,
            DroidMatchError error
    ) {
        OpenTransferResponse.Builder response = OpenTransferResponse.newBuilder()
                .setTransferId(transferId)
                .setAcceptedOffsetBytes(acceptedOffsetBytes)
                .setChunkSizeBytes(chunkSizeBytes)
                .setTotalSizeBytes(totalSizeBytes)
                .setStreamId(streamId);
        if (error != null) {
            response.setError(error);
        }
        return responseEnvelope(
                requestId,
                PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_RESPONSE,
                response.build().toByteString()
        );
    }

    static RpcEnvelope cancelTransferResponse(
            long requestId,
            String transferId,
            boolean ok,
            DroidMatchError error
    ) {
        CancelTransferResponse.Builder response = CancelTransferResponse.newBuilder()
                .setTransferId(transferId)
                .setOk(ok);
        if (error != null) {
            response.setError(error);
        }
        return responseEnvelope(
                requestId,
                PayloadType.PAYLOAD_TYPE_CANCEL_TRANSFER_RESPONSE,
                response.build().toByteString()
        );
    }

    static RpcEnvelope pauseTransferResponse(
            long requestId,
            String transferId,
            boolean ok,
            long resumableOffsetBytes,
            DroidMatchError error
    ) {
        PauseTransferResponse.Builder response = PauseTransferResponse.newBuilder()
                .setTransferId(transferId)
                .setOk(ok)
                .setResumableOffsetBytes(resumableOffsetBytes);
        if (error != null) {
            response.setError(error);
        }
        return responseEnvelope(
                requestId,
                PayloadType.PAYLOAD_TYPE_PAUSE_TRANSFER_RESPONSE,
                response.build().toByteString()
        );
    }

    static RpcEnvelope discardUploadPartialResponse(
            long requestId,
            String transferId,
            boolean ok,
            DroidMatchError error
    ) {
        DiscardUploadPartialResponse.Builder response = DiscardUploadPartialResponse.newBuilder()
                .setTransferId(transferId)
                .setOk(ok);
        if (error != null) {
            response.setError(error);
        }
        return responseEnvelope(
                requestId,
                PayloadType.PAYLOAD_TYPE_DISCARD_UPLOAD_PARTIAL_RESPONSE,
                response.build().toByteString()
        );
    }

    static RpcEnvelope responseEnvelope(
            long requestId,
            PayloadType payloadType,
            ByteString payload
    ) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(RpcDispatcher.FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_RESPONSE)
                .setRequestId(requestId)
                .setPayloadType(payloadType)
                .setPayload(payload)
                .build();
    }

    static RpcEnvelope streamEnvelope(
            long requestId,
            long streamId,
            PayloadType payloadType,
            ByteString payload
    ) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(RpcDispatcher.FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_STREAM)
                .setRequestId(requestId)
                .setStreamId(streamId)
                .setPayloadType(payloadType)
                .setPayload(payload)
                .build();
    }

    static DroidMatchError error(ErrorCode code, String message) {
        return DroidMatchError.newBuilder()
                .setCode(code)
                .setMessage(message == null ? "" : message)
                .build();
    }
}
