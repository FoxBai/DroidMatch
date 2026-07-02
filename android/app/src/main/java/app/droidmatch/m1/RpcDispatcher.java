package app.droidmatch.m1;

import app.droidmatch.proto.v1.Capability;
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
import java.util.Arrays;
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

    private final DiagnosticsReporter diagnosticsReporter;
    private final PermissionStateProvider permissionStateProvider;
    private final DmFileProvider fileProvider;
    private final AndroidDeviceInfoProvider deviceInfoProvider;
    private final AtomicLong nextSessionId = new AtomicLong(1);
    private final ConcurrentMap<String, DownloadTransfer> activeDownloadTransfers = new ConcurrentHashMap<>();

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

        boolean isTransferAck = request.getKind() == RpcFrameKind.RPC_FRAME_KIND_STREAM
                && request.getPayloadType() == PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK;
        if (request.getKind() != RpcFrameKind.RPC_FRAME_KIND_REQUEST && !isTransferAck) {
            diagnosticsReporter.recordState("rpc.envelope.unexpected:" + request.getKind() + ":" + request.getPayloadType());
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "expected request envelope"
            ));
        }

        if (isTransferAck && request.getStreamId() == 0) {
            diagnosticsReporter.recordState("rpc.transfer.ack.invalid_stream_id");
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "stream_id must be non-zero for transfer acknowledgements"
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
            case PAYLOAD_TYPE_TRANSFER_CHUNK_ACK:
                return handleTransferChunkAck(request, sessionId);
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
        if (openRequest.getDirection() != TransferDirection.TRANSFER_DIRECTION_DOWNLOAD) {
            return DispatchResult.response(openTransferResponse(
                    request.getRequestId(),
                    openRequest.getTransferId(),
                    0,
                    0,
                    0,
                    request.getRequestId(),
                    error(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, "M1 currently supports download only")
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
                    reader
            );
            reader = null;
            transfer.recordSent(openRequest.getRequestedOffsetBytes(), chunk);
            String transferKey = transferKey(sessionId, request.getRequestId());
            closeTransfer(activeDownloadTransfers.put(transferKey, transfer));
            diagnosticsReporter.recordCounter("rpc.open_transfer.download.requests", 1);
            diagnosticsReporter.recordCounter("rpc.transfer.bytes.sent", chunk.data.length);
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
            if (ack.getNextOffsetBytes() != transfer.nextOffsetBytes) {
                return DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "next_offset_bytes does not match the sent chunk boundary"
                ));
            }

            if (transfer.lastChunkFinal) {
                if (!ack.getFinalAck()) {
                    closeTransfer(activeDownloadTransfers.remove(transferKey));
                    return DispatchResult.response(errorEnvelope(
                            request.getRequestId(),
                            ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                            "final chunk requires final_ack"
                    ));
                }
                closeTransfer(activeDownloadTransfers.remove(transferKey));
                diagnosticsReporter.recordCounter("rpc.transfer.final_acks.received", 1);
                return DispatchResult.empty();
            }

            if (ack.getFinalAck()) {
                closeTransfer(activeDownloadTransfers.remove(transferKey));
                return DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                        "final_ack received before final chunk"
                ));
            }

            DmFileProvider.DownloadChunk chunk = transfer.readNextChunk();
            transfer.recordSent(ack.getNextOffsetBytes(), chunk);
            diagnosticsReporter.recordCounter("rpc.transfer.acks.received", 1);
            diagnosticsReporter.recordCounter("rpc.transfer.bytes.sent", chunk.data.length);
            return DispatchResult.response(streamEnvelope(
                    request.getRequestId(),
                    streamId,
                    PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK,
                    transferChunk(transfer.transferId, ack.getNextOffsetBytes(), chunk).toByteString()
            ));
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

    private void closeSessionTransfers(long sessionId) {
        String prefix = sessionId + ":";
        for (Map.Entry<String, DownloadTransfer> entry : activeDownloadTransfers.entrySet()) {
            if (entry.getKey().startsWith(prefix)
                    && activeDownloadTransfers.remove(entry.getKey(), entry.getValue())) {
                entry.getValue().close();
            }
        }
    }

    private static void closeTransfer(DownloadTransfer transfer) {
        if (transfer != null) {
            transfer.close();
        }
    }

    private static final class DownloadTransfer {
        private final String transferId;
        private final DmFileProvider.DownloadReader reader;
        private long nextOffsetBytes;
        private boolean lastChunkFinal;

        private DownloadTransfer(String transferId, DmFileProvider.DownloadReader reader) {
            this.transferId = transferId;
            this.reader = reader;
        }

        private DmFileProvider.DownloadChunk readNextChunk() throws DmFileProvider.ProviderCatalogException {
            return reader.readNextChunk();
        }

        private void recordSent(long offsetBytes, DmFileProvider.DownloadChunk chunk) {
            nextOffsetBytes = offsetBytes + chunk.data.length;
            lastChunkFinal = chunk.finalChunk;
        }

        private void close() {
            reader.close();
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

        private static DispatchResult handshakeComplete(RpcEnvelope response) {
            return new DispatchResult(Arrays.asList(response), true);
        }
    }
}
