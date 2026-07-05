package app.droidmatch.m1;

import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.CancelTransferRequest;
import app.droidmatch.proto.v1.CancelTransferResponse;
import app.droidmatch.proto.v1.ClientHello;
import app.droidmatch.proto.v1.DeviceInfoRequest;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.DiagnosticsRequest;
import app.droidmatch.proto.v1.DiagnosticsResponse;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.HeartbeatRequest;
import app.droidmatch.proto.v1.HeartbeatResponse;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;
import app.droidmatch.proto.v1.OpenTransferRequest;
import app.droidmatch.proto.v1.OpenTransferResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.PauseTransferRequest;
import app.droidmatch.proto.v1.PauseTransferResponse;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.ServerHello;
import app.droidmatch.proto.v1.TransferChunk;
import app.droidmatch.proto.v1.TransferChunkAck;
import app.droidmatch.proto.v1.TransferDirection;
import app.droidmatch.proto.v1.TransferFingerprint;
import app.droidmatch.proto.v1.TransportKind;
import com.google.protobuf.ByteString;
import com.google.protobuf.InvalidProtocolBufferException;

import java.io.EOFException;
import java.io.IOException;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Deque;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.zip.CRC32;

public final class RpcDispatcher {
    private static final String TAG = "DroidMatchRpc";
    private static final int FRAME_VERSION = 1;
    private static final int PROTOCOL_MAJOR = 1;
    private static final int PROTOCOL_MINOR = 0;
    private static final int DEFAULT_TRANSFER_CHUNK_SIZE_BYTES = 256 * 1024;
    private static final int MAX_TRANSFER_CHUNK_SIZE_BYTES = 1024 * 1024;
    private static final int MAX_DOWNLOAD_IN_FLIGHT_CHUNKS = 4;
    private static final int MAX_DOWNLOAD_IN_FLIGHT_BYTES = 2 * 1024 * 1024;

    private final DiagnosticsReporter diagnosticsReporter;
    private final PermissionStateProvider permissionStateProvider;
    private final DmFileProvider fileProvider;
    private final AndroidDeviceInfoProvider deviceInfoProvider;
    private final AtomicLong nextSessionId = new AtomicLong(1);
    private final ConcurrentMap<String, DownloadTransfer> activeDownloadTransfers = new ConcurrentHashMap<>();
    private final ConcurrentMap<String, UploadTransfer> activeUploadTransfers = new ConcurrentHashMap<>();

    public RpcDispatcher(
            DiagnosticsReporter diagnosticsReporter,
            PermissionStateProvider permissionStateProvider,
            DmFileProvider fileProvider,
            AndroidDeviceInfoProvider deviceInfoProvider
    ) {
        this.diagnosticsReporter = diagnosticsReporter;
        this.permissionStateProvider = permissionStateProvider;
        this.fileProvider = fileProvider;
        this.deviceInfoProvider = deviceInfoProvider;
    }

    public void handle(Socket socket, int idleTimeoutMillis) {
        long sessionId = nextSessionId.getAndIncrement();
        try (Socket client = socket) {
            boolean handshakeComplete = false;
            diagnosticsReporter.recordState("rpc.session.open");
            diagnosticsReporter.recordState("permission.media_read:" + permissionStateProvider.publicMediaReadState());
            diagnosticsReporter.recordState("permission.notifications:" + permissionStateProvider.notificationPostState());
            diagnosticsReporter.recordState("permission.saf_roots:" + permissionStateProvider.persistedSafRootCount());
            diagnosticsReporter.recordState("provider.roots:" + fileProvider.listRoots().length);
            android.util.Log.i(TAG, "session " + sessionId + " open");

            while (!client.isClosed()) {
                client.setSoTimeout(idleTimeoutMillis);
                byte[] frame = FramedIo.readFrame(client.getInputStream());
                diagnosticsReporter.recordCounter("rpc.frames.received", 1);
                android.util.Log.i(TAG, "session " + sessionId + " received frame bytes=" + frame.length);
                DispatchResult result = dispatch(frame, handshakeComplete, sessionId);
                for (RpcEnvelope response : result.responses) {
                    FramedIo.writeFrame(client.getOutputStream(), response.toByteArray());
                    diagnosticsReporter.recordCounter("rpc.frames.sent", 1);
                    android.util.Log.i(
                            TAG,
                            "session " + sessionId + " sent " + response.getKind() + "/" + response.getPayloadType()
                    );
                }
                handshakeComplete = handshakeComplete || result.handshakeComplete;
            }
        } catch (SocketTimeoutException exception) {
            diagnosticsReporter.recordError("rpc.session.idle_timeout", exception);
            android.util.Log.w(TAG, "session " + sessionId + " idle timeout", exception);
        } catch (EOFException exception) {
            String message = exception.getMessage();
            diagnosticsReporter.recordState("rpc.session.closed:eof" + (message == null ? "" : ":" + message));
            android.util.Log.i(TAG, "session " + sessionId + " closed by peer");
        } catch (IOException exception) {
            diagnosticsReporter.recordError("rpc.session.closed", exception);
            android.util.Log.w(TAG, "session " + sessionId + " closed", exception);
        } catch (RuntimeException exception) {
            diagnosticsReporter.recordError("rpc.session.crashed", exception);
            android.util.Log.e(TAG, "session " + sessionId + " crashed", exception);
        } finally {
            closeSessionTransfers(sessionId);
        }
    }

    private DispatchResult dispatch(byte[] frame, boolean handshakeComplete, long sessionId) {
        RpcEnvelope request;
        try {
            request = RpcEnvelope.parseFrom(frame);
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.envelope.invalid", exception);
            return DispatchResult.response(errorEnvelope(
                    0,
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "frame payload is not RpcEnvelope"
            ));
        }

        if (request.getFrameVersion() != FRAME_VERSION) {
            diagnosticsReporter.recordState("rpc.envelope.unsupported_frame_version:" + request.getFrameVersion());
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNSUPPORTED_VERSION,
                    "unsupported frame_version: " + request.getFrameVersion()
            ));
        }

        boolean isTransferPayload = request.getPayloadType() == PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK
                || request.getPayloadType() == PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK;
        boolean isTransferStream = request.getKind() == RpcFrameKind.RPC_FRAME_KIND_STREAM && isTransferPayload;
        if (request.getKind() != RpcFrameKind.RPC_FRAME_KIND_REQUEST && !isTransferStream) {
            diagnosticsReporter.recordState("rpc.envelope.unexpected:" + request.getKind() + ":" + request.getPayloadType());
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "expected request envelope"
            ));
        }

        if (isTransferPayload && request.getKind() != RpcFrameKind.RPC_FRAME_KIND_STREAM) {
            diagnosticsReporter.recordState("rpc.transfer.invalid_frame_kind");
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "transfer chunks and acknowledgements must use stream envelopes"
            ));
        }

        if (isTransferStream && request.getStreamId() == 0) {
            diagnosticsReporter.recordState("rpc.transfer.stream.invalid_stream_id");
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    request.getPayloadType() == PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK
                            ? "stream_id must be non-zero for transfer acknowledgements"
                            : "stream_id must be non-zero for transfer chunks"
            ));
        }

        if (request.getRequestId() == 0) {
            diagnosticsReporter.recordState("rpc.envelope.invalid_request_id");
            return DispatchResult.response(errorEnvelope(
                    0,
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "request_id must be non-zero"
            ));
        }

        if (!handshakeComplete && request.getPayloadType() != PayloadType.PAYLOAD_TYPE_CLIENT_HELLO) {
            diagnosticsReporter.recordState("rpc.envelope.handshake_required:" + request.getPayloadType());
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNAUTHORIZED,
                    "ClientHello must be the first request on a session"
            ));
        }

        if (handshakeComplete && request.getPayloadType() == PayloadType.PAYLOAD_TYPE_CLIENT_HELLO) {
            diagnosticsReporter.recordState("rpc.client_hello.duplicate");
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "ClientHello is only valid as the first request on a session"
            ));
        }

        switch (request.getPayloadType()) {
            case PAYLOAD_TYPE_CLIENT_HELLO:
                return handleClientHello(request);
            case PAYLOAD_TYPE_HEARTBEAT_REQUEST:
                return handleHeartbeat(request);
            case PAYLOAD_TYPE_DEVICE_INFO_REQUEST:
                return handleDeviceInfo(request);
            case PAYLOAD_TYPE_DIAGNOSTICS_REQUEST:
                return handleDiagnostics(request);
            case PAYLOAD_TYPE_LIST_DIR_REQUEST:
                return handleListDir(request);
            case PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST:
                return handleOpenTransfer(request, sessionId);
            case PAYLOAD_TYPE_TRANSFER_CHUNK:
                return handleTransferChunk(request, sessionId);
            case PAYLOAD_TYPE_TRANSFER_CHUNK_ACK:
                return handleTransferChunkAck(request, sessionId);
            case PAYLOAD_TYPE_CANCEL_TRANSFER_REQUEST:
                return handleCancelTransfer(request, sessionId);
            case PAYLOAD_TYPE_PAUSE_TRANSFER_REQUEST:
                return handlePauseTransfer(request, sessionId);
            default:
                diagnosticsReporter.recordState("rpc.envelope.unsupported_payload:" + request.getPayloadType());
                return DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                        "unsupported payload_type: " + request.getPayloadType()
                ));
        }
    }

    RpcEnvelope[] dispatchForTest(byte[] frame, boolean handshakeComplete, long sessionId) {
        DispatchResult result = dispatch(frame, handshakeComplete, sessionId);
        return result.responses.toArray(new RpcEnvelope[0]);
    }

    private DispatchResult handleClientHello(RpcEnvelope request) {
        ClientHello hello;
        try {
            hello = ClientHello.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.client_hello.invalid", exception);
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "ClientHello payload is invalid"
            ));
        }

        if (hello.getProtocolMajor() != PROTOCOL_MAJOR) {
            diagnosticsReporter.recordState("rpc.client_hello.unsupported_protocol:" + hello.getProtocolMajor());
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNSUPPORTED_VERSION,
                    "unsupported protocol_major: " + hello.getProtocolMajor()
            ));
        }

        if (hello.getTransport() != TransportKind.TRANSPORT_KIND_ADB) {
            diagnosticsReporter.recordState("rpc.client_hello.unsupported_transport:" + hello.getTransport());
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "ADB endpoint requires TRANSPORT_KIND_ADB"
            ));
        }

        ServerHello.Builder serverHello = ServerHello.newBuilder()
                .setServerName("DroidMatchAndroid")
                .setServerVersion("0.1.0-m1")
                .setProtocolMajor(PROTOCOL_MAJOR)
                .setProtocolMinor(Math.min(hello.getProtocolMinor(), PROTOCOL_MINOR))
                .setTransport(TransportKind.TRANSPORT_KIND_ADB)
                .setSessionNonce(hello.getSessionNonce());

        if (hello.getRequestedCapabilitiesList().contains(Capability.CAPABILITY_DIAGNOSTICS)) {
            serverHello.addGrantedCapabilities(Capability.CAPABILITY_DIAGNOSTICS);
        }

        diagnosticsReporter.recordCounter("rpc.handshakes.accepted", 1);
        return DispatchResult.handshakeComplete(RpcEnvelope.newBuilder()
                .setFrameVersion(FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_RESPONSE)
                .setRequestId(request.getRequestId())
                .setPayloadType(PayloadType.PAYLOAD_TYPE_SERVER_HELLO)
                .setPayload(serverHello.build().toByteString())
                .build());
    }

    private DispatchResult handleDeviceInfo(RpcEnvelope request) {
        try {
            DeviceInfoRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.device_info.invalid", exception);
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "DeviceInfoRequest payload is invalid"
            ));
        }

        diagnosticsReporter.recordCounter("rpc.device_info.requests", 1);
        return DispatchResult.response(RpcEnvelope.newBuilder()
                .setFrameVersion(FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_RESPONSE)
                .setRequestId(request.getRequestId())
                .setPayloadType(PayloadType.PAYLOAD_TYPE_DEVICE_INFO_RESPONSE)
                .setPayload(deviceInfoProvider.snapshot().toByteString())
                .build());
    }

    private DispatchResult handleHeartbeat(RpcEnvelope request) {
        HeartbeatRequest heartbeat;
        try {
            heartbeat = HeartbeatRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.heartbeat.invalid", exception);
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "HeartbeatRequest payload is invalid"
            ));
        }

        diagnosticsReporter.recordCounter("rpc.heartbeat.requests", 1);
        HeartbeatResponse response = HeartbeatResponse.newBuilder()
                .setMonotonicMillis(heartbeat.getMonotonicMillis())
                .build();
        return DispatchResult.response(RpcEnvelope.newBuilder()
                .setFrameVersion(FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_RESPONSE)
                .setRequestId(request.getRequestId())
                .setPayloadType(PayloadType.PAYLOAD_TYPE_HEARTBEAT_RESPONSE)
                .setPayload(response.toByteString())
                .build());
    }

    private DispatchResult handleListDir(RpcEnvelope request) {
        ListDirRequest listDirRequest;
        try {
            listDirRequest = ListDirRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.list_dir.invalid", exception);
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "ListDirRequest payload is invalid"
            ));
        }

        diagnosticsReporter.recordCounter("rpc.list_dir.requests", 1);
        ListDirResponse listDirResponse = fileProvider.listDir(listDirRequest);
        return DispatchResult.response(RpcEnvelope.newBuilder()
                .setFrameVersion(FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_RESPONSE)
                .setRequestId(request.getRequestId())
                .setPayloadType(PayloadType.PAYLOAD_TYPE_LIST_DIR_RESPONSE)
                .setPayload(listDirResponse.toByteString())
                .build());
    }

    private DispatchResult handleOpenTransfer(RpcEnvelope request, long sessionId) {
        OpenTransferRequest openRequest;
        try {
            openRequest = OpenTransferRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.open_transfer.invalid", exception);
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "OpenTransferRequest payload is invalid"
            ));
        }

        if (openRequest.getTransferId().isEmpty()) {
            return DispatchResult.response(openTransferResponse(
                    request.getRequestId(),
                    "",
                    0,
                    0,
                    0,
                    0,
                    error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "transfer_id must be non-empty")
            ));
        }
        if (openRequest.getDirection() == TransferDirection.TRANSFER_DIRECTION_UPLOAD) {
            return handleOpenUploadTransfer(request, openRequest, sessionId);
        }
        if (openRequest.getDirection() != TransferDirection.TRANSFER_DIRECTION_DOWNLOAD) {
            return DispatchResult.response(openTransferResponse(
                    request.getRequestId(),
                    openRequest.getTransferId(),
                    0,
                    0,
                    0,
                    request.getRequestId(),
                    error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "transfer direction must be download or upload")
            ));
        }
        if (openRequest.getRequestedOffsetBytes() < 0) {
            return DispatchResult.response(openTransferResponse(
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
            return DispatchResult.response(openTransferResponse(
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
                return DispatchResult.response(openTransferResponse(
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
            TransferChunk transferChunk = TransferChunk.newBuilder()
                    .setTransferId(openRequest.getTransferId())
                    .setOffsetBytes(openRequest.getRequestedOffsetBytes())
                    .setData(ByteString.copyFrom(chunk.data))
                    .setCrc32(crc32(chunk.data))
                    .setFinalChunk(chunk.finalChunk)
                    .build();
            DownloadTransfer transfer = new DownloadTransfer(
                    openRequest.getTransferId(),
                    reader,
                    chunkSize,
                    openRequest.getRequestedOffsetBytes()
            );
            reader = null;
            transfer.recordSent(openRequest.getRequestedOffsetBytes(), chunk);
            String transferKey = transferKey(sessionId, request.getRequestId());
            closeTransfer(activeDownloadTransfers.put(transferKey, transfer));
            diagnosticsReporter.recordCounter("rpc.open_transfer.download.requests", 1);
            diagnosticsReporter.recordCounter("rpc.transfer.bytes.sent", chunk.data.length);
            diagnosticsReporter.recordCounter("rpc.transfer.chunks.sent", 1);
            return DispatchResult.responses(
                    responseEnvelope(
                            request.getRequestId(),
                            PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_RESPONSE,
                            openResponse.toByteString()
                    ),
                    streamEnvelope(
                            request.getRequestId(),
                            request.getRequestId(),
                            PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK,
                            transferChunk.toByteString()
                    )
            );
        } catch (DmFileProvider.ProviderCatalogException exception) {
            return DispatchResult.response(openTransferResponse(
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

    private DispatchResult handleOpenUploadTransfer(
            RpcEnvelope request,
            OpenTransferRequest openRequest,
            long sessionId
    ) {
        if (openRequest.getDestinationPath().isEmpty()) {
            return DispatchResult.response(openTransferResponse(
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
            return DispatchResult.response(openTransferResponse(
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
            UploadTransfer transfer = new UploadTransfer(
                    openRequest.getTransferId(),
                    writer,
                    chunkSize
            );
            writer = null;
            String transferKey = transferKey(sessionId, request.getRequestId());
            closeUploadTransfer(activeUploadTransfers.put(transferKey, transfer));
            diagnosticsReporter.recordCounter("rpc.open_transfer.upload.requests", 1);
            return DispatchResult.response(responseEnvelope(
                    request.getRequestId(),
                    PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_RESPONSE,
                    openResponse.toByteString()
            ));
        } catch (DmFileProvider.ProviderCatalogException exception) {
            return DispatchResult.response(openTransferResponse(
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

    private DispatchResult handleTransferChunk(RpcEnvelope request, long sessionId) {
        long streamId = request.getStreamId();
        try {
            TransferChunk chunk = TransferChunk.parseFrom(request.getPayload().toByteArray());
            if (chunk.getTransferId().isEmpty()) {
                diagnosticsReporter.recordState("rpc.transfer.chunk.invalid_transfer_id");
                return DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer_id must be non-empty"
                ));
            }

            String transferKey = transferKey(sessionId, streamId);
            UploadTransfer transfer = activeUploadTransfers.get(transferKey);
            if (transfer == null) {
                return DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "unknown transfer stream"
                ));
            }
            if (!chunk.getTransferId().equals(transfer.transferId)) {
                return DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                        "transfer_id does not match active stream"
                ));
            }
            if (chunk.getOffsetBytes() != transfer.nextOffsetBytes()) {
                return DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer chunk offset does not match the expected write boundary"
                ));
            }
            byte[] data = chunk.getData().toByteArray();
            if (data.length > transfer.chunkSizeBytes) {
                return DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer chunk exceeds negotiated chunk_size_bytes"
                ));
            }
            int actualCrc32 = crc32(data);
            if (chunk.getCrc32() != actualCrc32) {
                return DispatchResult.response(errorEnvelope(
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
                closeUploadTransfer(activeUploadTransfers.remove(transferKey));
                diagnosticsReporter.recordCounter("rpc.transfer.uploads.completed", 1);
            }
            return DispatchResult.response(streamEnvelope(
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
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "TransferChunk payload is invalid"
            ));
        } catch (DmFileProvider.ProviderCatalogException exception) {
            closeUploadTransfer(activeUploadTransfers.remove(transferKey(sessionId, streamId)));
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    exception.code,
                    exception.getMessage()
            ));
        }
    }

    private DispatchResult handleTransferChunkAck(RpcEnvelope request, long sessionId) {
        long streamId = request.getStreamId();
        try {
            TransferChunkAck ack = TransferChunkAck.parseFrom(request.getPayload().toByteArray());
            if (ack.getTransferId().isEmpty()) {
                diagnosticsReporter.recordState("rpc.transfer.ack.invalid_transfer_id");
                return DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer_id must be non-empty"
                ));
            }

            String transferKey = transferKey(sessionId, streamId);
            DownloadTransfer transfer = activeDownloadTransfers.get(transferKey);
            if (transfer == null) {
                return DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "unknown transfer stream"
                ));
            }
            if (!ack.getTransferId().equals(transfer.transferId)) {
                return DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                        "transfer_id does not match active stream"
                ));
            }

            AckResult ackResult = transfer.recordAck(ack.getNextOffsetBytes(), ack.getFinalAck());
            if (ackResult.error != null) {
                if (ackResult.closeTransfer) {
                    closeTransfer(activeDownloadTransfers.remove(transferKey));
                }
                return DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ackResult.errorCode,
                        ackResult.error
                ));
            }
            if (ackResult.finalAcknowledged) {
                closeTransfer(activeDownloadTransfers.remove(transferKey));
                diagnosticsReporter.recordCounter("rpc.transfer.final_acks.received", 1);
                return DispatchResult.empty();
            }

            List<RpcEnvelope> responses = fillDownloadWindow(request.getRequestId(), streamId, transfer);
            diagnosticsReporter.recordCounter("rpc.transfer.acks.received", 1);
            if (responses.isEmpty()) {
                return DispatchResult.empty();
            }
            return DispatchResult.responses(responses);
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.transfer.ack.invalid", exception);
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "TransferChunkAck payload is invalid"
            ));
        } catch (DmFileProvider.ProviderCatalogException exception) {
            closeTransfer(activeDownloadTransfers.remove(transferKey(sessionId, streamId)));
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    exception.code,
                    exception.getMessage()
            ));
        }
    }

    private List<RpcEnvelope> fillDownloadWindow(long requestId, long streamId, DownloadTransfer transfer)
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

    private DispatchResult handleCancelTransfer(RpcEnvelope request, long sessionId) {
        CancelTransferRequest cancelRequest;
        try {
            cancelRequest = CancelTransferRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.transfer.cancel.invalid", exception);
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "CancelTransferRequest payload is invalid"
            ));
        }

        String transferId = cancelRequest.getTransferId();
        if (transferId.isEmpty()) {
            return DispatchResult.response(cancelTransferResponse(
                    request.getRequestId(),
                    "",
                    false,
                    error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "transfer_id must be non-empty")
            ));
        }

        DownloadTransfer transfer = removeSessionTransfer(sessionId, transferId);
        if (transfer == null) {
            return DispatchResult.response(cancelTransferResponse(
                    request.getRequestId(),
                    transferId,
                    false,
                    error(ErrorCode.ERROR_CODE_NOT_FOUND, "unknown transfer")
            ));
        }

        closeTransfer(transfer);
        diagnosticsReporter.recordCounter("rpc.transfer.cancellations.received", 1);
        diagnosticsReporter.recordState("rpc.transfer.cancelled");
        return DispatchResult.response(cancelTransferResponse(
                request.getRequestId(),
                transferId,
                true,
                null
        ));
    }

    private DispatchResult handlePauseTransfer(RpcEnvelope request, long sessionId) {
        PauseTransferRequest pauseRequest;
        try {
            pauseRequest = PauseTransferRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.transfer.pause.invalid", exception);
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "PauseTransferRequest payload is invalid"
            ));
        }

        String transferId = pauseRequest.getTransferId();
        if (transferId.isEmpty()) {
            return DispatchResult.response(pauseTransferResponse(
                    request.getRequestId(),
                    "",
                    false,
                    0,
                    error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "transfer_id must be non-empty")
            ));
        }

        DownloadTransfer transfer = removeSessionTransfer(sessionId, transferId);
        if (transfer == null) {
            return DispatchResult.response(pauseTransferResponse(
                    request.getRequestId(),
                    transferId,
                    false,
                    0,
                    error(ErrorCode.ERROR_CODE_NOT_FOUND, "unknown transfer")
            ));
        }

        long resumableOffsetBytes = transfer.nextSendOffsetBytes;
        closeTransfer(transfer);
        diagnosticsReporter.recordCounter("rpc.transfer.pauses.received", 1);
        diagnosticsReporter.recordState("rpc.transfer.paused");
        return DispatchResult.response(pauseTransferResponse(
                request.getRequestId(),
                transferId,
                true,
                resumableOffsetBytes,
                null
        ));
    }

    private DispatchResult handleDiagnostics(RpcEnvelope request) {
        try {
            DiagnosticsRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.diagnostics.invalid", exception);
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "DiagnosticsRequest payload is invalid"
            ));
        }

        diagnosticsReporter.recordCounter("rpc.diagnostics.requests", 1);
        DiagnosticsResponse.Builder diagnostics = DiagnosticsResponse.newBuilder()
                .setTransport(TransportKind.TRANSPORT_KIND_ADB)
                .setServiceState(diagnosticsReporter.currentState());

        List<String> recentErrors = diagnosticsReporter.recentErrorEvents();
        for (String event : recentErrors) {
            diagnostics.addRecentErrors(event);
        }
        List<String> recentEvents = diagnosticsReporter.recentEvents();
        for (String event : recentEvents) {
            diagnostics.addRecentEvents(event);
        }
        for (Map.Entry<String, Long> counter : diagnosticsReporter.counters().entrySet()) {
            diagnostics.putCounters(counter.getKey(), Long.toString(counter.getValue()));
        }

        return DispatchResult.response(RpcEnvelope.newBuilder()
                .setFrameVersion(FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_RESPONSE)
                .setRequestId(request.getRequestId())
                .setPayloadType(PayloadType.PAYLOAD_TYPE_DIAGNOSTICS_RESPONSE)
                .setPayload(diagnostics.build().toByteString())
                .build());
    }

    private static RpcEnvelope errorEnvelope(long requestId, ErrorCode code, String message) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(FRAME_VERSION)
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
                .setFrameVersion(FRAME_VERSION)
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
                .setFrameVersion(FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_STREAM)
                .setRequestId(requestId)
                .setStreamId(streamId)
                .setPayloadType(payloadType)
                .setPayload(payload)
                .build();
    }

    private static TransferChunk transferChunk(String transferId, long offsetBytes, DmFileProvider.DownloadChunk chunk) {
        return TransferChunk.newBuilder()
                .setTransferId(transferId)
                .setOffsetBytes(offsetBytes)
                .setData(ByteString.copyFrom(chunk.data))
                .setCrc32(crc32(chunk.data))
                .setFinalChunk(chunk.finalChunk)
                .build();
    }

    private static DroidMatchError error(ErrorCode code, String message) {
        return DroidMatchError.newBuilder()
                .setCode(code)
                .setMessage(message == null ? "" : message)
                .build();
    }

    private static int negotiatedChunkSize(int preferredChunkSizeBytes) {
        long requestedSize = Integer.toUnsignedLong(preferredChunkSizeBytes);
        if (requestedSize == 0) {
            return DEFAULT_TRANSFER_CHUNK_SIZE_BYTES;
        }
        return (int) Math.min(requestedSize, MAX_TRANSFER_CHUNK_SIZE_BYTES);
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

    private static String transferKey(long sessionId, long streamId) {
        return sessionId + ":" + streamId;
    }

    private DownloadTransfer removeSessionTransfer(long sessionId, String transferId) {
        String prefix = sessionId + ":";
        for (Map.Entry<String, DownloadTransfer> entry : activeDownloadTransfers.entrySet()) {
            if (entry.getKey().startsWith(prefix)
                    && transferId.equals(entry.getValue().transferId)
                    && activeDownloadTransfers.remove(entry.getKey(), entry.getValue())) {
                return entry.getValue();
            }
        }
        return null;
    }

    private void closeSessionTransfers(long sessionId) {
        String prefix = sessionId + ":";
        for (Map.Entry<String, DownloadTransfer> entry : activeDownloadTransfers.entrySet()) {
            if (entry.getKey().startsWith(prefix)
                    && activeDownloadTransfers.remove(entry.getKey(), entry.getValue())) {
                entry.getValue().close();
            }
        }
        for (Map.Entry<String, UploadTransfer> entry : activeUploadTransfers.entrySet()) {
            if (entry.getKey().startsWith(prefix)
                    && activeUploadTransfers.remove(entry.getKey(), entry.getValue())) {
                entry.getValue().close();
            }
        }
    }

    private static void closeTransfer(DownloadTransfer transfer) {
        if (transfer != null) {
            transfer.close();
        }
    }

    private static void closeUploadTransfer(UploadTransfer transfer) {
        if (transfer != null) {
            transfer.close();
        }
    }

    private static final class DownloadTransfer {
        private final String transferId;
        private final DmFileProvider.DownloadReader reader;
        private final int chunkSizeBytes;
        private final Deque<SentChunk> outstandingChunks = new ArrayDeque<>();
        private long acknowledgedOffsetBytes;
        private long nextSendOffsetBytes;
        private boolean finalChunkSent;

        private DownloadTransfer(
                String transferId,
                DmFileProvider.DownloadReader reader,
                int chunkSizeBytes,
                long startingOffsetBytes
        ) {
            this.transferId = transferId;
            this.reader = reader;
            this.chunkSizeBytes = chunkSizeBytes;
            this.acknowledgedOffsetBytes = startingOffsetBytes;
            this.nextSendOffsetBytes = startingOffsetBytes;
        }

        private DmFileProvider.DownloadChunk readNextChunk() throws DmFileProvider.ProviderCatalogException {
            return reader.readNextChunk();
        }

        private void recordSent(long offsetBytes, DmFileProvider.DownloadChunk chunk) {
            long nextOffsetBytes = offsetBytes + chunk.data.length;
            outstandingChunks.addLast(new SentChunk(nextOffsetBytes, chunk.finalChunk));
            nextSendOffsetBytes = nextOffsetBytes;
            finalChunkSent = finalChunkSent || chunk.finalChunk;
        }

        private AckResult recordAck(long nextOffsetBytes, boolean finalAck) {
            SentChunk sentChunk = outstandingChunks.peekFirst();
            if (sentChunk == null) {
                return AckResult.error(
                        ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                        "transfer ack received with no outstanding chunk",
                        false
                );
            }
            if (nextOffsetBytes != sentChunk.nextOffsetBytes) {
                return AckResult.error(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "next_offset_bytes does not match the next sent chunk boundary",
                        false
                );
            }
            if (sentChunk.finalChunk && !finalAck) {
                return AckResult.error(
                        ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                        "final chunk requires final_ack",
                        true
                );
            }
            if (!sentChunk.finalChunk && finalAck) {
                return AckResult.error(
                        ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                        "final_ack received before final chunk",
                        true
                );
            }

            outstandingChunks.removeFirst();
            acknowledgedOffsetBytes = nextOffsetBytes;
            if (sentChunk.finalChunk) {
                return AckResult.finalAcknowledged();
            }
            return AckResult.ok();
        }

        private boolean canSendMore() {
            if (finalChunkSent) {
                return false;
            }
            if (outstandingChunks.size() >= MAX_DOWNLOAD_IN_FLIGHT_CHUNKS) {
                return false;
            }
            long outstandingBytes = nextSendOffsetBytes - acknowledgedOffsetBytes;
            return outstandingBytes + chunkSizeBytes <= MAX_DOWNLOAD_IN_FLIGHT_BYTES;
        }

        private void close() {
            reader.close();
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

    private static final class AckResult {
        private final boolean finalAcknowledged;
        private final ErrorCode errorCode;
        private final String error;
        private final boolean closeTransfer;

        private AckResult(
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

        private static AckResult ok() {
            return new AckResult(false, null, null, false);
        }

        private static AckResult finalAcknowledged() {
            return new AckResult(true, null, null, true);
        }

        private static AckResult error(ErrorCode errorCode, String error, boolean closeTransfer) {
            return new AckResult(false, errorCode, error, closeTransfer);
        }
    }

    private static final class UploadTransfer {
        private final String transferId;
        private final DmFileProvider.UploadWriter writer;
        private final int chunkSizeBytes;

        private UploadTransfer(String transferId, DmFileProvider.UploadWriter writer, int chunkSizeBytes) {
            this.transferId = transferId;
            this.writer = writer;
            this.chunkSizeBytes = chunkSizeBytes;
        }

        private long nextOffsetBytes() {
            return writer.nextOffsetBytes();
        }

        private void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
                throws DmFileProvider.ProviderCatalogException {
            writer.writeChunk(offsetBytes, data, finalChunk);
        }

        private void close() {
            writer.close();
        }
    }

    private static final class DispatchResult {
        private final List<RpcEnvelope> responses;
        private final boolean handshakeComplete;

        private DispatchResult(List<RpcEnvelope> responses, boolean handshakeComplete) {
            this.responses = responses;
            this.handshakeComplete = handshakeComplete;
        }

        private static DispatchResult empty() {
            return new DispatchResult(Arrays.asList(), false);
        }

        private static DispatchResult response(RpcEnvelope response) {
            return new DispatchResult(Arrays.asList(response), false);
        }

        private static DispatchResult responses(RpcEnvelope first, RpcEnvelope second) {
            return new DispatchResult(Arrays.asList(first, second), false);
        }

        private static DispatchResult responses(List<RpcEnvelope> responses) {
            return new DispatchResult(responses, false);
        }

        private static DispatchResult handshakeComplete(RpcEnvelope response) {
            return new DispatchResult(Arrays.asList(response), true);
        }
    }
}
