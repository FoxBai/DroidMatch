package app.droidmatch.m1;

import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.ClientHello;
import app.droidmatch.proto.v1.DeviceInfoRequest;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.DiagnosticsRequest;
import app.droidmatch.proto.v1.DiagnosticsResponse;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.ServerHello;
import app.droidmatch.proto.v1.TransportKind;
import com.google.protobuf.InvalidProtocolBufferException;

import java.io.EOFException;
import java.io.IOException;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.util.List;
import java.util.Map;

public final class RpcDispatcher {
    private static final int FRAME_VERSION = 1;
    private static final int PROTOCOL_MAJOR = 1;
    private static final int PROTOCOL_MINOR = 0;

    private final DiagnosticsReporter diagnosticsReporter;
    private final PermissionStateProvider permissionStateProvider;
    private final DmFileProvider fileProvider;
    private final AndroidDeviceInfoProvider deviceInfoProvider;

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
        try (Socket client = socket) {
            boolean handshakeComplete = false;
            diagnosticsReporter.recordState("rpc.session.open");
            diagnosticsReporter.recordState("permission.media_read:" + permissionStateProvider.publicMediaReadState());
            diagnosticsReporter.recordState("permission.saf_roots:" + permissionStateProvider.persistedSafRootCount());
            diagnosticsReporter.recordState("provider.roots:" + fileProvider.listRoots().length);

            while (!client.isClosed()) {
                client.setSoTimeout(idleTimeoutMillis);
                byte[] frame = FramedIo.readFrame(client.getInputStream());
                diagnosticsReporter.recordCounter("rpc.frames.received", 1);
                DispatchResult result = dispatch(frame, handshakeComplete);
                RpcEnvelope response = result.response;
                FramedIo.writeFrame(client.getOutputStream(), response.toByteArray());
                diagnosticsReporter.recordCounter("rpc.frames.sent", 1);
                handshakeComplete = handshakeComplete || result.handshakeComplete;
            }
        } catch (SocketTimeoutException exception) {
            diagnosticsReporter.recordError("rpc.session.idle_timeout", exception);
        } catch (EOFException exception) {
            String message = exception.getMessage();
            diagnosticsReporter.recordState("rpc.session.closed:eof" + (message == null ? "" : ":" + message));
        } catch (IOException exception) {
            diagnosticsReporter.recordError("rpc.session.closed", exception);
        } catch (RuntimeException exception) {
            diagnosticsReporter.recordError("rpc.session.crashed", exception);
        }
    }

    private DispatchResult dispatch(byte[] frame, boolean handshakeComplete) {
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

        if (request.getKind() != RpcFrameKind.RPC_FRAME_KIND_REQUEST) {
            diagnosticsReporter.recordState("rpc.envelope.unexpected:" + request.getKind() + ":" + request.getPayloadType());
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "expected request envelope"
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
            case PAYLOAD_TYPE_DEVICE_INFO_REQUEST:
                return handleDeviceInfo(request);
            case PAYLOAD_TYPE_DIAGNOSTICS_REQUEST:
                return handleDiagnostics(request);
            default:
                diagnosticsReporter.recordState("rpc.envelope.unsupported_payload:" + request.getPayloadType());
                return DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                        "unsupported payload_type: " + request.getPayloadType()
                ));
        }
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
        DroidMatchError error = DroidMatchError.newBuilder()
                .setCode(code)
                .setMessage(message)
                .build();
        return RpcEnvelope.newBuilder()
                .setFrameVersion(FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_ERROR)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_DROIDMATCH_ERROR)
                .setError(error)
                .build();
    }

    private static final class DispatchResult {
        private final RpcEnvelope response;
        private final boolean handshakeComplete;

        private DispatchResult(RpcEnvelope response, boolean handshakeComplete) {
            this.response = response;
            this.handshakeComplete = handshakeComplete;
        }

        private static DispatchResult response(RpcEnvelope response) {
            return new DispatchResult(response, false);
        }

        private static DispatchResult handshakeComplete(RpcEnvelope response) {
            return new DispatchResult(response, true);
        }
    }
}
