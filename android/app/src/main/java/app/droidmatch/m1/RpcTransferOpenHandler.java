package app.droidmatch.m1;

import app.droidmatch.m1.RpcTransferStreams.Download;
import app.droidmatch.m1.RpcTransferStreams.Upload;
import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.OpenTransferRequest;
import app.droidmatch.proto.v1.OpenTransferResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.TransferChunk;
import app.droidmatch.proto.v1.TransferDirection;
import app.droidmatch.proto.v1.TransferFingerprint;

import com.google.protobuf.InvalidProtocolBufferException;

import java.util.List;

import static app.droidmatch.m1.RpcTransferFrames.*;

/**
 * Owns transfer-open parsing, admission, provider opening, and initial handle
 * installation after the dispatcher has admitted the session.
 *
 * <p>The active-stream handler supplies its sole registry instance, so open
 * admission and later chunk/lifecycle actions observe one identity and teardown
 * boundary. A provider handle is either installed into that registry or closed
 * before this method returns.</p>
 */
final class RpcTransferOpenHandler {
    private static final int MAX_CONCURRENT_TRANSFER_STREAMS = 2;

    private final DiagnosticsReporter diagnosticsReporter;
    private final DmFileProvider fileProvider;
    private final RpcTransferRegistry registry;

    RpcTransferOpenHandler(
            DiagnosticsReporter diagnosticsReporter,
            DmFileProvider fileProvider,
            RpcTransferRegistry registry
    ) {
        this.diagnosticsReporter = diagnosticsReporter;
        this.fileProvider = fileProvider;
        this.registry = registry;
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

        if (registry.hasTransferId(sessionId, openRequest.getTransferId())) {
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
        if (registry.hasStream(sessionId, request.getRequestId())) {
            return RpcDispatcher.DispatchResult.response(openTransferResponse(
                    request.getRequestId(),
                    openRequest.getTransferId(),
                    0,
                    0,
                    0,
                    request.getRequestId(),
                    error(
                            ErrorCode.ERROR_CODE_ALREADY_EXISTS,
                            "stream_id is already active or retired in this session"
                    )
            ));
        }
        if (registry.count(sessionId) >= MAX_CONCURRENT_TRANSFER_STREAMS) {
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
                    request.getRequestId(),
                    openRequest.getTransferId(),
                    reader,
                    chunkSize,
                    openRequest.getRequestedOffsetBytes()
            );
            reader = null;
            transfer.recordSent(openRequest.getRequestedOffsetBytes(), chunk);
            registry.installDownload(sessionId, request.getRequestId(), transfer);
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
                    error(exception.code, ProviderErrorLabels.transfer(exception.code, "download"))
            ));
        } finally {
            if (reader != null) {
                reader.close();
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
                    request.getRequestId(),
                    openRequest.getTransferId(),
                    writer,
                    chunkSize
            );
            writer = null;
            registry.installUpload(sessionId, request.getRequestId(), transfer);
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
                    error(exception.code, ProviderErrorLabels.transfer(exception.code, "upload"))
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
}
