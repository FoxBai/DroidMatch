package app.droidmatch.m1;

import app.droidmatch.m1.RpcTransferStreams.Ack;
import app.droidmatch.m1.RpcTransferStreams.Download;
import app.droidmatch.m1.RpcTransferStreams.Upload;
import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.CancelTransferRequest;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.PauseTransferRequest;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.TransferChunk;
import app.droidmatch.proto.v1.TransferChunkAck;

import com.google.protobuf.InvalidProtocolBufferException;

import java.util.ArrayList;
import java.util.List;

import static app.droidmatch.m1.RpcTransferFrames.*;

/**
 * Owns active transfer stream actions after the session dispatcher has
 * validated envelope framing and session phase.
 *
 * <p>Opening and admission delegate to {@link RpcTransferOpenHandler} over the
 * same registry. Download acknowledgements advance only across recorded chunk
 * boundaries; uploads advance only after the provider writer accepts a
 * CRC-checked chunk. Session teardown closes every handle owned by the
 * session.</p>
 */
final class RpcTransferHandler {
    private final DiagnosticsReporter diagnosticsReporter;
    private final RpcTransferRegistry registry = new RpcTransferRegistry();
    private final RpcTransferOpenHandler openHandler;

    RpcTransferHandler(DiagnosticsReporter diagnosticsReporter, DmFileProvider fileProvider) {
        this.diagnosticsReporter = diagnosticsReporter;
        this.openHandler = new RpcTransferOpenHandler(diagnosticsReporter, fileProvider, registry);
    }

    RpcDispatcher.DispatchResult open(
            RpcEnvelope request,
            List<Capability> grantedCapabilities,
            long sessionId
    ) {
        return openHandler.open(request, grantedCapabilities, sessionId);
    }

    RpcDispatcher.DispatchResult receiveChunk(RpcEnvelope request, long sessionId) {
        long streamId = request.getStreamId();
        try {
            // Parse the nested message directly from the envelope ByteString.
            // Materializing another full chunk-sized byte[] is pure allocation
            // pressure on older ART runtimes and provides no ownership benefit.
            TransferChunk chunk = TransferChunk.parseFrom(request.getPayload());
            if (chunk.getTransferId().isEmpty()) {
                diagnosticsReporter.recordState("rpc.transfer.chunk.invalid_transfer_id");
                return RpcDispatcher.DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer_id must be non-empty"
                ));
            }

            Upload transfer = registry.upload(sessionId, streamId);
            if (transfer == null) {
                return RpcDispatcher.DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "unknown transfer stream"
                ));
            }
            if (!chunk.getTransferId().equals(transfer.transferId)) {
                return RpcDispatcher.DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                        "transfer_id does not match active stream"
                ));
            }
            if (chunk.getOffsetBytes() != transfer.nextOffsetBytes()) {
                return RpcDispatcher.DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer chunk offset does not match the expected write boundary"
                ));
            }
            byte[] data = chunk.getData().toByteArray();
            if (data.length > transfer.chunkSizeBytes) {
                return RpcDispatcher.DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer chunk exceeds negotiated chunk_size_bytes"
                ));
            }
            if (chunk.getCrc32() != crc32(data)) {
                return RpcDispatcher.DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_CHECKSUM_MISMATCH,
                        "transfer chunk crc32 mismatch"
                ));
            }

            transfer.writeChunk(chunk.getOffsetBytes(), data, chunk.getFinalChunk());
            long nextOffsetBytes = transfer.nextOffsetBytes();
            diagnosticsReporter.recordCounter("rpc.transfer.chunks.received", 1);
            diagnosticsReporter.recordCounter("rpc.transfer.bytes.received", data.length);
            if (chunk.getFinalChunk()) {
                closeUpload(registry.removeUpload(sessionId, streamId));
                diagnosticsReporter.recordCounter("rpc.transfer.uploads.completed", 1);
            }
            return RpcDispatcher.DispatchResult.response(streamEnvelope(
                    request.getRequestId(),
                    streamId,
                    PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK,
                    TransferChunkAck.newBuilder()
                            .setTransferId(transfer.transferId)
                            .setNextOffsetBytes(nextOffsetBytes)
                            .setFinalAck(chunk.getFinalChunk())
                            .build()
                            .toByteString()
            ));
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.transfer.chunk.invalid", exception);
            return RpcDispatcher.DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "TransferChunk payload is invalid"
            ));
        } catch (DmFileProvider.ProviderCatalogException exception) {
            closeUpload(registry.removeUpload(sessionId, streamId));
            return RpcDispatcher.DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    exception.code,
                    ProviderErrorLabels.transfer(exception.code, "upload")
            ));
        }
    }

    RpcDispatcher.DispatchResult acknowledgeChunk(RpcEnvelope request, long sessionId) {
        long streamId = request.getStreamId();
        try {
            TransferChunkAck ack = TransferChunkAck.parseFrom(request.getPayload().toByteArray());
            if (ack.getTransferId().isEmpty()) {
                diagnosticsReporter.recordState("rpc.transfer.ack.invalid_transfer_id");
                return RpcDispatcher.DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer_id must be non-empty"
                ));
            }

            Download transfer = registry.download(sessionId, streamId);
            if (transfer == null) {
                return RpcDispatcher.DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "unknown transfer stream"
                ));
            }
            if (!ack.getTransferId().equals(transfer.transferId)) {
                return RpcDispatcher.DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                        "transfer_id does not match active stream"
                ));
            }

            Ack ackResult = transfer.recordAck(ack.getNextOffsetBytes(), ack.getFinalAck());
            if (ackResult.error != null) {
                if (ackResult.closeTransfer) {
                    closeDownload(registry.removeDownload(sessionId, streamId));
                }
                return RpcDispatcher.DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ackResult.errorCode,
                        ackResult.error
                ));
            }
            if (ackResult.finalAcknowledged) {
                closeDownload(registry.removeDownload(sessionId, streamId));
                diagnosticsReporter.recordCounter("rpc.transfer.final_acks.received", 1);
                return RpcDispatcher.DispatchResult.empty();
            }

            List<RpcEnvelope> responses = fillDownloadWindow(request.getRequestId(), streamId, transfer);
            diagnosticsReporter.recordCounter("rpc.transfer.acks.received", 1);
            return responses.isEmpty()
                    ? RpcDispatcher.DispatchResult.empty()
                    : RpcDispatcher.DispatchResult.responses(responses);
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.transfer.ack.invalid", exception);
            return RpcDispatcher.DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "TransferChunkAck payload is invalid"
            ));
        } catch (DmFileProvider.ProviderCatalogException exception) {
            closeDownload(registry.removeDownload(sessionId, streamId));
            return RpcDispatcher.DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    exception.code,
                    ProviderErrorLabels.transfer(exception.code, "download")
            ));
        }
    }

    RpcDispatcher.DispatchResult cancel(RpcEnvelope request, long sessionId) {
        CancelTransferRequest cancelRequest;
        try {
            cancelRequest = CancelTransferRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.transfer.cancel.invalid", exception);
            return RpcDispatcher.DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "CancelTransferRequest payload is invalid"
            ));
        }

        String transferId = cancelRequest.getTransferId();
        if (transferId.isEmpty()) {
            return RpcDispatcher.DispatchResult.response(cancelTransferResponse(
                    request.getRequestId(),
                    "",
                    false,
                    error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "transfer_id must be non-empty")
            ));
        }

        Download downloadTransfer = registry.removeDownload(sessionId, transferId);
        Upload uploadTransfer = null;
        if (downloadTransfer == null) {
            uploadTransfer = registry.removeUpload(sessionId, transferId);
        }
        if (downloadTransfer == null && uploadTransfer == null) {
            return RpcDispatcher.DispatchResult.response(cancelTransferResponse(
                    request.getRequestId(),
                    transferId,
                    false,
                    error(ErrorCode.ERROR_CODE_NOT_FOUND, "unknown transfer")
            ));
        }

        closeDownload(downloadTransfer);
        closeUpload(uploadTransfer);
        diagnosticsReporter.recordCounter("rpc.transfer.cancellations.received", 1);
        diagnosticsReporter.recordState("rpc.transfer.cancelled");
        return RpcDispatcher.DispatchResult.response(cancelTransferResponse(
                request.getRequestId(),
                transferId,
                true,
                null
        ));
    }

    RpcDispatcher.DispatchResult pause(RpcEnvelope request, long sessionId) {
        PauseTransferRequest pauseRequest;
        try {
            pauseRequest = PauseTransferRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.transfer.pause.invalid", exception);
            return RpcDispatcher.DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "PauseTransferRequest payload is invalid"
            ));
        }

        String transferId = pauseRequest.getTransferId();
        if (transferId.isEmpty()) {
            return RpcDispatcher.DispatchResult.response(pauseTransferResponse(
                    request.getRequestId(),
                    "",
                    false,
                    0,
                    error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "transfer_id must be non-empty")
            ));
        }

        Download transfer = registry.removeDownload(sessionId, transferId);
        if (transfer == null) {
            return RpcDispatcher.DispatchResult.response(pauseTransferResponse(
                    request.getRequestId(),
                    transferId,
                    false,
                    0,
                    error(ErrorCode.ERROR_CODE_NOT_FOUND, "unknown transfer")
            ));
        }

        long resumableOffsetBytes = transfer.acknowledgedOffsetBytes;
        closeDownload(transfer);
        diagnosticsReporter.recordCounter("rpc.transfer.pauses.received", 1);
        diagnosticsReporter.recordState("rpc.transfer.paused");
        return RpcDispatcher.DispatchResult.response(pauseTransferResponse(
                request.getRequestId(),
                transferId,
                true,
                resumableOffsetBytes,
                null
        ));
    }

    void closeSession(long sessionId) {
        registry.closeSession(sessionId);
    }

    private List<RpcEnvelope> fillDownloadWindow(long requestId, long streamId, Download transfer)
            throws DmFileProvider.ProviderCatalogException {
        List<RpcEnvelope> responses = new ArrayList<>();
        while (transfer.canSendMore()) {
            long offsetBytes = transfer.nextSendOffsetBytes;
            DmFileProvider.DownloadChunk chunk = transfer.readNextChunk();
            transfer.recordSent(offsetBytes, chunk);
            diagnosticsReporter.recordCounter("rpc.transfer.bytes.sent", chunk.data.length);
            diagnosticsReporter.recordCounter("rpc.transfer.chunks.sent", 1);
            responses.add(streamEnvelope(
                    requestId,
                    streamId,
                    PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK,
                    transferChunk(transfer.transferId, offsetBytes, chunk).toByteString()
            ));
        }
        return responses;
    }

    private static void closeDownload(Download transfer) {
        if (transfer != null) {
            transfer.close();
        }
    }

    private static void closeUpload(Upload transfer) {
        if (transfer != null) {
            transfer.close();
        }
    }

}
