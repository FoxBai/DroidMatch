package app.droidmatch.m1;

import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.ClientHello;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.ServerHello;
import app.droidmatch.proto.v1.TransportKind;
import com.google.protobuf.ByteString;
import com.google.protobuf.InvalidProtocolBufferException;

import java.io.EOFException;
import java.io.IOException;
import java.net.Socket;
import java.net.SocketTimeoutException;

public final class RpcDispatcher {
    private static final int FRAME_VERSION = 1;
    private static final int PROTOCOL_MAJOR = 1;
    private static final int PROTOCOL_MINOR = 0;

    private final DiagnosticsReporter diagnosticsReporter;
    private final PermissionStateProvider permissionStateProvider;
    private final DmFileProvider fileProvider;

    public RpcDispatcher(
            DiagnosticsReporter diagnosticsReporter,
            PermissionStateProvider permissionStateProvider,
            DmFileProvider fileProvider
    ) {
        this.diagnosticsReporter = diagnosticsReporter;
        this.permissionStateProvider = permissionStateProvider;
        this.fileProvider = fileProvider;
    }

    public void handle(Socket socket, int idleTimeoutMillis) {
        try (Socket client = socket) {
            diagnosticsReporter.recordState("rpc.session.open");
            diagnosticsReporter.recordState("permission.media_read:" + permissionStateProvider.publicMediaReadState());
            diagnosticsReporter.recordState("permission.saf_roots:" + permissionStateProvider.persistedSafRootCount());
            diagnosticsReporter.recordState("provider.roots:" + fileProvider.listRoots().length);

            while (!client.isClosed()) {
                client.setSoTimeout(idleTimeoutMillis);
                byte[] frame = FramedIo.readFrame(client.getInputStream());
                diagnosticsReporter.recordCounter("rpc.frames.received", 1);
                RpcEnvelope response = dispatch(frame);
                FramedIo.writeFrame(client.getOutputStream(), response.toByteArray());
                diagnosticsReporter.recordCounter("rpc.frames.sent", 1);
            }
        } catch (SocketTimeoutException exception) {
            diagnosticsReporter.recordError("rpc.session.idle_timeout", exception);
        } catch (EOFException exception) {
            String message = exception.getMessage();
            diagnosticsReporter.recordState("rpc.session.closed:eof" + (message == null ? "" : ":" + message));
        } catch (IOException exception) {
            diagnosticsReporter.recordError("rpc.session.closed", exception);
        }
    }

    private RpcEnvelope dispatch(byte[] frame) {
        RpcEnvelope request;
        try {
            request = RpcEnvelope.parseFrom(frame);
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.envelope.invalid", exception);
            return errorEnvelope(0, ErrorCode.ERROR_CODE_PROTOCOL_ERROR, "frame payload is not RpcEnvelope");
        }

        if (request.getFrameVersion() != FRAME_VERSION) {
            diagnosticsReporter.recordState("rpc.envelope.unsupported_frame_version:" + request.getFrameVersion());
            return errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNSUPPORTED_VERSION,
                    "unsupported frame_version: " + request.getFrameVersion()
            );
        }

        if (request.getKind() != RpcFrameKind.RPC_FRAME_KIND_REQUEST
                || request.getPayloadType() != PayloadType.PAYLOAD_TYPE_CLIENT_HELLO) {
            diagnosticsReporter.recordState("rpc.envelope.unexpected:" + request.getKind() + ":" + request.getPayloadType());
            return errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "expected ClientHello request"
            );
        }

        ClientHello hello;
        try {
            hello = ClientHello.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.client_hello.invalid", exception);
            return errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "ClientHello payload is invalid"
            );
        }

        if (hello.getProtocolMajor() != PROTOCOL_MAJOR) {
            diagnosticsReporter.recordState("rpc.client_hello.unsupported_protocol:" + hello.getProtocolMajor());
            return errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNSUPPORTED_VERSION,
                    "unsupported protocol_major: " + hello.getProtocolMajor()
            );
        }

        if (hello.getTransport() != TransportKind.TRANSPORT_KIND_ADB) {
            diagnosticsReporter.recordState("rpc.client_hello.unsupported_transport:" + hello.getTransport());
            return errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "ADB endpoint requires TRANSPORT_KIND_ADB"
            );
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
        return RpcEnvelope.newBuilder()
                .setFrameVersion(FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_RESPONSE)
                .setRequestId(request.getRequestId())
                .setPayloadType(PayloadType.PAYLOAD_TYPE_SERVER_HELLO)
                .setPayload(serverHello.build().toByteString())
                .build();
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
                .setPayload(ByteString.copyFrom(error.toByteArray()))
                .setError(error)
                .build();
    }
}
