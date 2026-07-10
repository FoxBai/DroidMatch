package app.droidmatch.m1;

import app.droidmatch.m1.RpcTransferStreams.Ack;
import app.droidmatch.m1.RpcTransferStreams.Download;
import app.droidmatch.m1.RpcTransferStreams.Upload;
import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.CancelTransferRequest;
import app.droidmatch.proto.v1.CancelTransferResponse;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.OpenTransferRequest;
import app.droidmatch.proto.v1.OpenTransferResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.PauseTransferRequest;
import app.droidmatch.proto.v1.PauseTransferResponse;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.TransferChunk;
import app.droidmatch.proto.v1.TransferChunkAck;
import app.droidmatch.proto.v1.TransferDirection;
import app.droidmatch.proto.v1.TransferFingerprint;

import com.google.protobuf.ByteString;
import com.google.protobuf.InvalidProtocolBufferException;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.zip.CRC32;

/**
 * Owns transfer RPC state after the session dispatcher has validated envelope
 * framing and session phase.
 *
 * <p>One instance owns every active stream registry. Download acknowledgements
 * advance only across recorded chunk boundaries; uploads advance only after the
 * provider writer accepts a CRC-checked chunk. Session teardown closes all
 * provider handles owned by that session.</p>
 */
final class RpcTransferHandler {
    private static final int DEFAULT_TRANSFER_CHUNK_SIZE_BYTES = 256 * 1024;
    private static final int MAX_TRANSFER_CHUNK_SIZE_BYTES = 1024 * 1024;
    private static final int MAX_CONCURRENT_TRANSFER_STREAMS = 2;

    private final DiagnosticsReporter diagnosticsReporter;
    private final DmFileProvider fileProvider;
    private final ConcurrentMap<String, Download> activeDownloadTransfers = new ConcurrentHashMap<>();
    private final ConcurrentMap<String, Upload> activeUploadTransfers = new ConcurrentHashMap<>();

    RpcTransferHandler(DiagnosticsReporter diagnosticsReporter, DmFileProvider fileProvider) {
        this.diagnosticsReporter = diagnosticsReporter;
        this.fileProvider = fileProvider;
    }

    RpcDispatcher.DispatchResult open(
            RpcEnvelope request,
            List<Capability> grantedCapabilities,
            long sessionId
    ) {
        OpenTransferRequest openRequest;
        try {
            openRequest = OpenTransferRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.open_transfer.invalid", exception);
            return RpcDispatcher.DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "OpenTransferRequest payload is invalid"
            ));
        }

        if (openRequest.getTransferId().isEmpty()) {
            return RpcDispatcher.DispatchResult.response(openTransferResponse(
                    request.getRequestId(),
                    "",
                    0,
                    0,
                    0,
                    0,
                    error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "transfer_id must be non-empty")
            ));
        }
        TransferDirection direction = openRequest.getDirection();
        if (direction != TransferDirection.TRANSFER_DIRECTION_DOWNLOAD
                && direction != TransferDirection.TRANSFER_DIRECTION_UPLOAD) {
            return RpcDispatcher.DispatchResult.response(openTransferResponse(
                    request.getRequestId(),
                    openRequest.getTransferId(),
                    0,
                    0,
                    0,
                    request.getRequestId(),
                    error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "transfer direction must be download or upload")
            ));
        }
        Capability requiredCapability = direction == TransferDirection.TRANSFER_DIRECTION_UPLOAD
                ? Capability.CAPABILITY_FILE_WRITE
                : Capability.CAPABILITY_FILE_READ;
        if (!grantedCapabilities.contains(requiredCapability)) {
            return capabilityDenied(request, requiredCapability);
        }
        if (openRequest.getRequestedOffsetBytes() > 0
                && !grantedCapabilities.contains(Capability.CAPABILITY_RESUMABLE_TRANSFER)) {
            return capabilityDenied(request, Capability.CAPABILITY_RESUMABLE_TRANSFER);
        }

        if (hasActiveTransferId(sessionId, openRequest.getTransferId())) {
            return RpcDispatcher.DispatchResult.response(openTransferResponse(
                    request.getRequestId(),
                    openRequest.getTransferId(),
                    0,
                    0,
                    0,
                    request.getRequestId(),
                    error(
                            ErrorCode.ERROR_CODE_ALREADY_EXISTS,
                            "transfer_id is already active in this session"
                    )
            ));
        }
        String requestedTransferKey = transferKey(sessionId, request.getRequestId());
        if (activeDownloadTransfers.containsKey(requestedTransferKey)
                || activeUploadTransfers.containsKey(requestedTransferKey)) {
            return RpcDispatcher.DispatchResult.response(openTransferResponse(
                    request.getRequestId(),
                    openRequest.getTransferId(),
                    0,
                    0,
                    0,
                    request.getRequestId(),
                    error(ErrorCode.ERROR_CODE_ALREADY_EXISTS, "stream_id is already active")
            ));
        }
        if (activeTransferCount(sessionId) >= MAX_CONCURRENT_TRANSFER_STREAMS) {
            diagnosticsReporter.recordCounter("rpc.transfer.concurrent_limit_rejected", 1);
            return RpcDispatcher.DispatchResult.response(openTransferResponse(
                    request.getRequestId(),
                    openRequest.getTransferId(),
                    0,
                    0,
                    0,
                    request.getRequestId(),
                    error(
                            ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                            "maximum concurrent transfer streams reached"
                    )
            ));
        }
        if (direction == TransferDirection.TRANSFER_DIRECTION_UPLOAD) {
            return openUpload(request, openRequest, sessionId);
        }
        if (openRequest.getRequestedOffsetBytes() < 0) {
            return RpcDispatcher.DispatchResult.response(openTransferResponse(
                    request.getRequestId(),
                    openRequest.getTransferId(),
                    0,
                    0,
                    0,
                    request.getRequestId(),
                    error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "requested_offset_bytes must be non-negative")
            ));
        }
        if (openRequest.getRequestedOffsetBytes() > 0 && !openRequest.hasSourceFingerprint()) {
            return RpcDispatcher.DispatchResult.response(openTransferResponse(
                    request.getRequestId(),
                    openRequest.getTransferId(),
                    0,
                    0,
                    0,
                    request.getRequestId(),
                    error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "source_fingerprint is required for resume")
            ));
        }

        int chunkSize = negotiatedChunkSize(openRequest.getPreferredChunkSizeBytes());
        DmFileProvider.DownloadReader reader = null;
        try {
            reader = fileProvider.openDownload(
                    openRequest.getSourcePath(),
                    openRequest.getRequestedOffsetBytes(),
                    chunkSize
            );
            DmFileProvider.DownloadChunk chunk = reader.readNextChunk();
            TransferFingerprint fingerprint = TransferFingerprint.newBuilder()
                    .setSizeBytes(chunk.totalSizeBytes)
                    .setModifiedUnixMillis(chunk.modifiedUnixMillis)
                    .setProviderEtag(chunk.providerEtag)
                    .build();
            if (openRequest.getRequestedOffsetBytes() > 0
                    && !fingerprintsMatch(openRequest.getSourceFingerprint(), fingerprint)) {
                reader.close();
                return RpcDispatcher.DispatchResult.response(openTransferResponse(
                        request.getRequestId(),
                        openRequest.getTransferId(),
                        0,
                        chunkSize,
                        chunk.totalSizeBytes,
                        request.getRequestId(),
                        error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "source fingerprint changed")
                ));
            }
            OpenTransferResponse openResponse = OpenTransferResponse.newBuilder()
                    .setTransferId(openRequest.getTransferId())
                    .setAcceptedOffsetBytes(openRequest.getRequestedOffsetBytes())
                    .setChunkSizeBytes(chunkSize)
                    .setTotalSizeBytes(chunk.totalSizeBytes)
                    .setStreamId(request.getRequestId())
                    .setAcceptedSourceFingerprint(fingerprint)
                    .build();
            TransferChunk firstChunk = transferChunk(
                    openRequest.getTransferId(),
                    openRequest.getRequestedOffsetBytes(),
                    chunk
            );
            Download transfer = new Download(
                    openRequest.getTransferId(),
                    reader,
                    chunkSize,
                    openRequest.getRequestedOffsetBytes()
            );
            reader = null;
            transfer.recordSent(openRequest.getRequestedOffsetBytes(), chunk);
            closeDownload(activeDownloadTransfers.put(requestedTransferKey, transfer));
            diagnosticsReporter.recordCounter("rpc.open_transfer.download.requests", 1);
            diagnosticsReporter.recordCounter("rpc.transfer.bytes.sent", chunk.data.length);
            diagnosticsReporter.recordCounter("rpc.transfer.chunks.sent", 1);
            return RpcDispatcher.DispatchResult.responses(
                    responseEnvelope(
                            request.getRequestId(),
                            PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_RESPONSE,
                            openResponse.toByteString()
                    ),
                    streamEnvelope(
                            request.getRequestId(),
                            request.getRequestId(),
                            PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK,
                            firstChunk.toByteString()
                    )
            );
        } catch (DmFileProvider.ProviderCatalogException exception) {
            return RpcDispatcher.DispatchResult.response(openTransferResponse(
                    request.getRequestId(),
                    openRequest.getTransferId(),
                    0,
                    chunkSize,
                    0,
                    request.getRequestId(),
                    error(exception.code, exception.getMessage())
            ));
        } finally {
            if (reader != null) {
                reader.close();
            }
        }
    }

    RpcDispatcher.DispatchResult receiveChunk(RpcEnvelope request, long sessionId) {
        long streamId = request.getStreamId();
        try {
            TransferChunk chunk = TransferChunk.parseFrom(request.getPayload().toByteArray());
            if (chunk.getTransferId().isEmpty()) {
                diagnosticsReporter.recordState("rpc.transfer.chunk.invalid_transfer_id");
                return RpcDispatcher.DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer_id must be non-empty"
                ));
            }

            String transferKey = transferKey(sessionId, streamId);
            Upload transfer = activeUploadTransfers.get(transferKey);
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
                closeUpload(activeUploadTransfers.remove(transferKey));
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
            closeUpload(activeUploadTransfers.remove(transferKey(sessionId, streamId)));
            return RpcDispatcher.DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    exception.code,
                    exception.getMessage()
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

            String transferKey = transferKey(sessionId, streamId);
            Download transfer = activeDownloadTransfers.get(transferKey);
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
                    closeDownload(activeDownloadTransfers.remove(transferKey));
                }
                return RpcDispatcher.DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ackResult.errorCode,
                        ackResult.error
                ));
            }
            if (ackResult.finalAcknowledged) {
                closeDownload(activeDownloadTransfers.remove(transferKey));
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
            closeDownload(activeDownloadTransfers.remove(transferKey(sessionId, streamId)));
            return RpcDispatcher.DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    exception.code,
                    exception.getMessage()
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

        Download downloadTransfer = removeSessionDownload(sessionId, transferId);
        Upload uploadTransfer = null;
        if (downloadTransfer == null) {
            uploadTransfer = removeSessionUpload(sessionId, transferId);
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

        Download transfer = removeSessionDownload(sessionId, transferId);
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
        String prefix = sessionId + ":";
        for (Map.Entry<String, Download> entry : activeDownloadTransfers.entrySet()) {
            if (entry.getKey().startsWith(prefix)
                    && activeDownloadTransfers.remove(entry.getKey(), entry.getValue())) {
                entry.getValue().close();
            }
        }
        for (Map.Entry<String, Upload> entry : activeUploadTransfers.entrySet()) {
            if (entry.getKey().startsWith(prefix)
                    && activeUploadTransfers.remove(entry.getKey(), entry.getValue())) {
                entry.getValue().close();
            }
        }
    }

    private RpcDispatcher.DispatchResult openUpload(
            RpcEnvelope request,
            OpenTransferRequest openRequest,
            long sessionId
    ) {
        if (openRequest.getDestinationPath().isEmpty()) {
            return RpcDispatcher.DispatchResult.response(openTransferResponse(
                    request.getRequestId(),
                    openRequest.getTransferId(),
                    0,
                    0,
                    0,
                    request.getRequestId(),
                    error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "destination_path must be non-empty for upload")
            ));
        }
        if (openRequest.getExpectedSizeBytes() < -1) {
            return RpcDispatcher.DispatchResult.response(openTransferResponse(
                    request.getRequestId(),
                    openRequest.getTransferId(),
                    0,
                    0,
                    0,
                    request.getRequestId(),
                    error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "expected_size_bytes must be -1 or non-negative")
            ));
        }

        int chunkSize = negotiatedChunkSize(openRequest.getPreferredChunkSizeBytes());
        DmFileProvider.UploadWriter writer = null;
        try {
            writer = fileProvider.openUpload(
                    openRequest.getDestinationPath(),
                    openRequest.getTransferId(),
                    openRequest.getRequestedOffsetBytes(),
                    openRequest.getExpectedSizeBytes()
            );
            OpenTransferResponse openResponse = OpenTransferResponse.newBuilder()
                    .setTransferId(openRequest.getTransferId())
                    .setAcceptedOffsetBytes(writer.nextOffsetBytes())
                    .setChunkSizeBytes(chunkSize)
                    .setTotalSizeBytes(openRequest.getExpectedSizeBytes())
                    .setStreamId(request.getRequestId())
                    .build();
            Upload transfer = new Upload(
                    openRequest.getTransferId(),
                    writer,
                    chunkSize
            );
            writer = null;
            closeUpload(activeUploadTransfers.put(transferKey(sessionId, request.getRequestId()), transfer));
            diagnosticsReporter.recordCounter("rpc.open_transfer.upload.requests", 1);
            return RpcDispatcher.DispatchResult.response(responseEnvelope(
                    request.getRequestId(),
                    PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_RESPONSE,
                    openResponse.toByteString()
            ));
        } catch (DmFileProvider.ProviderCatalogException exception) {
            return RpcDispatcher.DispatchResult.response(openTransferResponse(
                    request.getRequestId(),
                    openRequest.getTransferId(),
                    0,
                    chunkSize,
                    0,
                    request.getRequestId(),
                    error(exception.code, exception.getMessage())
            ));
        } finally {
            if (writer != null) {
                writer.close();
            }
        }
    }

    private RpcDispatcher.DispatchResult capabilityDenied(RpcEnvelope request, Capability capability) {
        diagnosticsReporter.recordState("rpc.capability.denied:" + capability);
        return RpcDispatcher.DispatchResult.response(errorEnvelope(
                request.getRequestId(),
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "capability not granted: " + capability
        ));
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

    private int activeTransferCount(long sessionId) {
        String prefix = sessionId + ":";
        int count = 0;
        for (String key : activeDownloadTransfers.keySet()) {
            if (key.startsWith(prefix)) {
                count += 1;
            }
        }
        for (String key : activeUploadTransfers.keySet()) {
            if (key.startsWith(prefix)) {
                count += 1;
            }
        }
        return count;
    }

    private boolean hasActiveTransferId(long sessionId, String transferId) {
        String prefix = sessionId + ":";
        for (Map.Entry<String, Download> entry : activeDownloadTransfers.entrySet()) {
            if (entry.getKey().startsWith(prefix) && transferId.equals(entry.getValue().transferId)) {
                return true;
            }
        }
        for (Map.Entry<String, Upload> entry : activeUploadTransfers.entrySet()) {
            if (entry.getKey().startsWith(prefix) && transferId.equals(entry.getValue().transferId)) {
                return true;
            }
        }
        return false;
    }

    private Download removeSessionDownload(long sessionId, String transferId) {
        String prefix = sessionId + ":";
        for (Map.Entry<String, Download> entry : activeDownloadTransfers.entrySet()) {
            if (entry.getKey().startsWith(prefix)
                    && transferId.equals(entry.getValue().transferId)
                    && activeDownloadTransfers.remove(entry.getKey(), entry.getValue())) {
                return entry.getValue();
            }
        }
        return null;
    }

    private Upload removeSessionUpload(long sessionId, String transferId) {
        String prefix = sessionId + ":";
        for (Map.Entry<String, Upload> entry : activeUploadTransfers.entrySet()) {
            if (entry.getKey().startsWith(prefix)
                    && transferId.equals(entry.getValue().transferId)
                    && activeUploadTransfers.remove(entry.getKey(), entry.getValue())) {
                return entry.getValue();
            }
        }
        return null;
    }

    private static String transferKey(long sessionId, long streamId) {
        return sessionId + ":" + streamId;
    }

    private static int negotiatedChunkSize(int preferredChunkSizeBytes) {
        long requestedSize = Integer.toUnsignedLong(preferredChunkSizeBytes);
        return requestedSize == 0
                ? DEFAULT_TRANSFER_CHUNK_SIZE_BYTES
                : (int) Math.min(requestedSize, MAX_TRANSFER_CHUNK_SIZE_BYTES);
    }

    private static int crc32(byte[] data) {
        CRC32 crc32 = new CRC32();
        crc32.update(data);
        return (int) crc32.getValue();
    }

    private static boolean fingerprintsMatch(TransferFingerprint expected, TransferFingerprint actual) {
        return expected.getSizeBytes() == actual.getSizeBytes()
                && expected.getModifiedUnixMillis() == actual.getModifiedUnixMillis()
                && expected.getProviderEtag().equals(actual.getProviderEtag())
                && expected.getSha256().equals(actual.getSha256());
    }

    private static TransferChunk transferChunk(
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

    private static RpcEnvelope errorEnvelope(long requestId, ErrorCode code, String message) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(RpcDispatcher.FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_ERROR)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_DROIDMATCH_ERROR)
                .setError(error(code, message))
                .build();
    }

    private static RpcEnvelope openTransferResponse(
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

    private static RpcEnvelope cancelTransferResponse(
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

    private static RpcEnvelope pauseTransferResponse(
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

    private static RpcEnvelope responseEnvelope(long requestId, PayloadType payloadType, ByteString payload) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(RpcDispatcher.FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_RESPONSE)
                .setRequestId(requestId)
                .setPayloadType(payloadType)
                .setPayload(payload)
                .build();
    }

    private static RpcEnvelope streamEnvelope(
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

    private static DroidMatchError error(ErrorCode code, String message) {
        return DroidMatchError.newBuilder()
                .setCode(code)
                .setMessage(message == null ? "" : message)
                .build();
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
