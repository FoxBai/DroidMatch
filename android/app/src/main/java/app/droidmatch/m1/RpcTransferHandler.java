package app.droidmatch.m1;

import app.droidmatch.m1.RpcTransferStreams.Ack;
import app.droidmatch.m1.RpcTransferStreams.Download;
import app.droidmatch.m1.RpcTransferStreams.Upload;
import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.CancelTransferRequest;
import app.droidmatch.proto.v1.DiscardUploadPartialRequest;
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
    private final DmFileProvider fileProvider;
    private final RpcTransferRegistry registry = new RpcTransferRegistry();
    private final RpcTransferOpenHandler openHandler;

    RpcTransferHandler(DiagnosticsReporter diagnosticsReporter, DmFileProvider fileProvider) {
        this.diagnosticsReporter = diagnosticsReporter;
        this.fileProvider = fileProvider;
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
        if (consumeTerminalFrame(sessionId, request.getRequestId())) {
            return RpcDispatcher.DispatchResult.empty();
        }
        long streamId = request.getStreamId();
        try {
            // Parse the nested message directly from the envelope ByteString.
            // Materializing another full chunk-sized byte[] is pure allocation
            // pressure on older ART runtimes and provides no ownership benefit.
            TransferChunk chunk = TransferChunk.parseFrom(request.getPayload());
            Upload transfer = registry.upload(sessionId, streamId);
            if (transfer == null) {
                if (registry.download(sessionId, streamId) != null) {
                    return abortCorrelatedWithError(
                            sessionId,
                            request.getRequestId(),
                            ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                            "transfer chunk direction does not match active stream"
                    );
                }
                return RpcDispatcher.DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "unknown transfer stream"
                ));
            }
            if (chunk.getTransferId().isEmpty()) {
                diagnosticsReporter.recordState("rpc.transfer.chunk.invalid_transfer_id");
                return abortUploadWithError(
                        sessionId,
                        streamId,
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer_id must be non-empty"
                );
            }

            if (!chunk.getTransferId().equals(transfer.transferId)) {
                return abortUploadWithError(
                        sessionId,
                        streamId,
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                        "transfer_id does not match active stream"
                );
            }
            if (chunk.getOffsetBytes() != transfer.nextOffsetBytes()) {
                return abortUploadWithError(
                        sessionId,
                        streamId,
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer chunk offset does not match the expected write boundary"
                );
            }
            byte[] data = chunk.getData().toByteArray();
            if (data.length > transfer.chunkSizeBytes) {
                return abortUploadWithError(
                        sessionId,
                        streamId,
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer chunk exceeds negotiated chunk_size_bytes"
                );
            }
            if (chunk.getCrc32() != crc32(data)) {
                return abortUploadWithError(
                        sessionId,
                        streamId,
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_CHECKSUM_MISMATCH,
                        "transfer chunk crc32 mismatch"
                );
            }

            transfer.writeChunk(chunk.getOffsetBytes(), data, chunk.getFinalChunk());
            long nextOffsetBytes = transfer.nextOffsetBytes();
            diagnosticsReporter.recordCounter("rpc.transfer.chunks.received", 1);
            diagnosticsReporter.recordCounter("rpc.transfer.bytes.received", data.length);
            if (chunk.getFinalChunk()) {
                terminateStream(sessionId, streamId);
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
            return abortCorrelatedWithError(
                    sessionId,
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "TransferChunk payload is invalid"
            );
        } catch (DmFileProvider.ProviderCatalogException exception) {
            terminateStream(sessionId, streamId);
            return RpcDispatcher.DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    exception.code,
                    ProviderErrorLabels.transfer(exception.code, "upload")
            ));
        }
    }

    RpcDispatcher.DispatchResult acknowledgeChunk(RpcEnvelope request, long sessionId) {
        if (consumeTerminalFrame(sessionId, request.getRequestId())) {
            return RpcDispatcher.DispatchResult.empty();
        }
        long streamId = request.getStreamId();
        try {
            TransferChunkAck ack = TransferChunkAck.parseFrom(request.getPayload());
            Download transfer = registry.download(sessionId, streamId);
            if (transfer == null) {
                if (registry.upload(sessionId, streamId) != null) {
                    return abortCorrelatedWithError(
                            sessionId,
                            request.getRequestId(),
                            ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                            "transfer acknowledgement direction does not match active stream"
                    );
                }
                return RpcDispatcher.DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "unknown transfer stream"
                ));
            }
            if (ack.getTransferId().isEmpty()) {
                diagnosticsReporter.recordState("rpc.transfer.ack.invalid_transfer_id");
                return abortDownloadWithError(
                        sessionId,
                        streamId,
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer_id must be non-empty"
                );
            }

            if (!ack.getTransferId().equals(transfer.transferId)) {
                return abortDownloadWithError(
                        sessionId,
                        streamId,
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                        "transfer_id does not match active stream"
                );
            }

            Ack ackResult = transfer.recordAck(ack.getNextOffsetBytes(), ack.getFinalAck());
            if (ackResult.error != null) {
                terminateStream(sessionId, streamId);
                return RpcDispatcher.DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ackResult.errorCode,
                        ackResult.error
                ));
            }
            if (ackResult.finalAcknowledged) {
                terminateStream(sessionId, streamId);
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
            return abortCorrelatedWithError(
                    sessionId,
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "TransferChunkAck payload is invalid"
            );
        } catch (DmFileProvider.ProviderCatalogException exception) {
            terminateStream(sessionId, streamId);
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

        closeTerminal(sessionId, downloadTransfer);
        closeTerminal(sessionId, uploadTransfer);
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
        closeTerminal(sessionId, transfer);
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

    RpcDispatcher.DispatchResult discardUploadPartial(RpcEnvelope request) {
        DiscardUploadPartialRequest discardRequest;
        try {
            discardRequest = DiscardUploadPartialRequest.parseFrom(request.getPayload());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.transfer.discard_partial.invalid", exception);
            return RpcDispatcher.DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "DiscardUploadPartialRequest payload is invalid"
            ));
        }

        String transferId = discardRequest.getTransferId();
        if (transferId.isEmpty() || discardRequest.getDestinationPath().isEmpty()
                || discardRequest.getExpectedSizeBytes() < 0) {
            return RpcDispatcher.DispatchResult.response(discardUploadPartialResponse(
                    request.getRequestId(),
                    transferId,
                    false,
                    error(
                            ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                            "upload partial cleanup fields are invalid"
                    )
            ));
        }

        try {
            fileProvider.discardUploadPartial(
                    discardRequest.getDestinationPath(),
                    transferId,
                    discardRequest.getExpectedSizeBytes()
            );
            diagnosticsReporter.recordCounter("rpc.transfer.partial_discards.received", 1);
            diagnosticsReporter.recordState("rpc.transfer.partial_discarded");
            return RpcDispatcher.DispatchResult.response(discardUploadPartialResponse(
                    request.getRequestId(),
                    transferId,
                    true,
                    null
            ));
        } catch (DmFileProvider.ProviderCatalogException exception) {
            return RpcDispatcher.DispatchResult.response(discardUploadPartialResponse(
                    request.getRequestId(),
                    transferId,
                    false,
                    error(
                            exception.code,
                            ProviderErrorLabels.transfer(exception.code, "upload cleanup")
                    )
            ));
        }
    }

    void closeSession(long sessionId) {
        registry.closeSession(sessionId);
    }

    boolean consumeTerminalFrame(long sessionId, long requestId) {
        return registry.consumeTerminalFrame(sessionId, requestId);
    }

    /**
     * Releases the route named by the original OpenTransferRequest request ID.
     * Android M1 chooses that same value as stream_id; using the correlated ID
     * here prevents a malformed frame from tearing down the sibling it names in
     * a conflicting stream_id field.
     */
    void abortCorrelatedStream(long sessionId, long requestId) {
        terminateStream(sessionId, requestId);
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

    private void closeTerminal(long sessionId, Download transfer) {
        if (transfer != null) {
            registry.markTerminalStream(sessionId, transfer.streamId);
            closeDownload(transfer);
        }
    }

    private void closeTerminal(long sessionId, Upload transfer) {
        if (transfer != null) {
            registry.markTerminalStream(sessionId, transfer.streamId);
            closeUpload(transfer);
        }
    }

    private void terminateStream(long sessionId, long streamId) {
        Download download = registry.removeDownload(sessionId, streamId);
        Upload upload = registry.removeUpload(sessionId, streamId);
        if (download == null && upload == null) {
            return;
        }
        registry.markTerminalStream(sessionId, streamId);
        closeDownload(download);
        closeUpload(upload);
    }

    private RpcDispatcher.DispatchResult abortUploadWithError(
            long sessionId,
            long streamId,
            long requestId,
            ErrorCode code,
            String message
    ) {
        terminateStream(sessionId, streamId);
        return RpcDispatcher.DispatchResult.response(errorEnvelope(requestId, code, message));
    }

    private RpcDispatcher.DispatchResult abortDownloadWithError(
            long sessionId,
            long streamId,
            long requestId,
            ErrorCode code,
            String message
    ) {
        terminateStream(sessionId, streamId);
        return RpcDispatcher.DispatchResult.response(errorEnvelope(requestId, code, message));
    }

    private RpcDispatcher.DispatchResult abortCorrelatedWithError(
            long sessionId,
            long requestId,
            ErrorCode code,
            String message
    ) {
        abortCorrelatedStream(sessionId, requestId);
        return RpcDispatcher.DispatchResult.response(errorEnvelope(requestId, code, message));
    }

}
