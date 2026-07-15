package app.droidmatch.m1;

import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import com.google.protobuf.ByteString;
import com.google.protobuf.InvalidProtocolBufferException;

import java.io.EOFException;
import java.io.IOException;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

public final class RpcDispatcher {
    private static final String TAG = "DroidMatchRpc";
    static final int FRAME_VERSION = 1;
    private static final int PAIRING_CONFIRM_IDLE_TIMEOUT_MILLIS =
            (int) PairingApprovalController.DEFAULT_WINDOW_MILLIS + 5_000;
    private final DiagnosticsReporter diagnosticsReporter;
    private final PermissionStateProvider permissionStateProvider;
    private final DmFileProvider fileProvider;
    private final RpcAuthenticationHandler authenticationHandler;
    private final RpcPairingHandler pairingHandler;
    private final RpcControlHandler controlHandler;
    private final RpcTransferHandler transferHandler;
    private final AtomicLong nextSessionId = new AtomicLong(1);

    public RpcDispatcher(
            DiagnosticsReporter diagnosticsReporter,
            PermissionStateProvider permissionStateProvider,
            DmFileProvider fileProvider,
            AndroidDeviceInfoProvider deviceInfoProvider
    ) {
        this(
                diagnosticsReporter,
                permissionStateProvider,
                fileProvider,
                deviceInfoProvider,
                SessionAuthenticationMode.NONCE_ONLY,
                pairingId -> null,
                null,
                null,
                null
        );
    }

    public RpcDispatcher(
            DiagnosticsReporter diagnosticsReporter,
            PermissionStateProvider permissionStateProvider,
            DmFileProvider fileProvider,
            AndroidDeviceInfoProvider deviceInfoProvider,
            SessionAuthenticationMode authenticationMode,
            PairingKeyProvider pairingKeyProvider
    ) {
        this(
                diagnosticsReporter,
                permissionStateProvider,
                fileProvider,
                deviceInfoProvider,
                authenticationMode,
                pairingKeyProvider,
                null,
                null,
                null
        );
    }

    public RpcDispatcher(
            DiagnosticsReporter diagnosticsReporter,
            PermissionStateProvider permissionStateProvider,
            DmFileProvider fileProvider,
            AndroidDeviceInfoProvider deviceInfoProvider,
            SessionAuthenticationMode authenticationMode,
            PairingKeyProvider pairingKeyProvider,
            PairingCredentialRepository pairingCredentialRepository,
            PairingApprovalController pairingApprovalController,
            DeviceIdentityProvider deviceIdentityProvider
    ) {
        this(
                diagnosticsReporter,
                permissionStateProvider,
                fileProvider,
                deviceInfoProvider,
                authenticationMode,
                pairingKeyProvider,
                pairingCredentialRepository,
                pairingApprovalController,
                deviceIdentityProvider,
                new AuthenticationRateLimiter()
        );
    }

    RpcDispatcher(
            DiagnosticsReporter diagnosticsReporter,
            PermissionStateProvider permissionStateProvider,
            DmFileProvider fileProvider,
            AndroidDeviceInfoProvider deviceInfoProvider,
            SessionAuthenticationMode authenticationMode,
            PairingKeyProvider pairingKeyProvider,
            PairingCredentialRepository pairingCredentialRepository,
            PairingApprovalController pairingApprovalController,
            DeviceIdentityProvider deviceIdentityProvider,
            AuthenticationRateLimiter authenticationRateLimiter
    ) {
        this.diagnosticsReporter = diagnosticsReporter;
        this.permissionStateProvider = permissionStateProvider;
        this.fileProvider = fileProvider;
        this.controlHandler = new RpcControlHandler(
                diagnosticsReporter,
                fileProvider,
                deviceInfoProvider
        );
        this.authenticationHandler = new RpcAuthenticationHandler(
                diagnosticsReporter,
                authenticationMode,
                pairingKeyProvider,
                deviceIdentityProvider,
                authenticationRateLimiter
        );
        this.pairingHandler = new RpcPairingHandler(
                diagnosticsReporter,
                pairingCredentialRepository,
                pairingApprovalController,
                deviceIdentityProvider,
                authenticationRateLimiter
        );
        this.transferHandler = new RpcTransferHandler(diagnosticsReporter, fileProvider);
    }

    public void handle(Socket socket, int idleTimeoutMillis) {
        long sessionId = nextSessionId.getAndIncrement();
        SessionState sessionState = new SessionState();
        try (Socket client = socket) {
            diagnosticsReporter.recordState("rpc.session.open");
            diagnosticsReporter.recordState("permission.media_read:" + permissionStateProvider.publicMediaReadState());
            diagnosticsReporter.recordState("permission.notifications:" + permissionStateProvider.notificationPostState());
            diagnosticsReporter.recordState("permission.saf_roots:" + permissionStateProvider.persistedSafRootCount());
            diagnosticsReporter.recordState("provider.roots:" + fileProvider.listRoots().length);
            android.util.Log.i(TAG, "session " + sessionId + " open");

            // Keep aggregate frame counts in two fixed structured counters.
            // Emitting an Info logcat record for every received and emitted frame
            // adds formatting/logd work to the transfer loop on older devices.
            while (!client.isClosed()) {
                client.setSoTimeout(readTimeoutMillis(sessionState.phase, idleTimeoutMillis));
                byte[] frame = FramedIo.readFrame(client.getInputStream());
                diagnosticsReporter.recordCounter("rpc.frames.received", 1);
                DispatchResult result = dispatch(frame, sessionState, sessionId);
                for (RpcEnvelope response : result.responses) {
                    FramedIo.writeFrame(client.getOutputStream(), response.toByteArray());
                    diagnosticsReporter.recordCounter("rpc.frames.sent", 1);
                }
                if (result.closeSession) {
                    diagnosticsReporter.recordState("rpc.session.closed:authentication");
                    break;
                }
            }
        } catch (SocketTimeoutException exception) {
            diagnosticsReporter.recordError("rpc.session.idle_timeout", exception);
            android.util.Log.w(
                    TAG,
                    AndroidLogLabel.error("session " + sessionId + " idle timeout", exception)
            );
        } catch (EOFException exception) {
            // EOF messages are transport-owned and may include private provider
            // details on some Android implementations. Keep the structured
            // state and Logcat label bounded. 中文：EOF 原文不得进入诊断状态或系统日志。
            diagnosticsReporter.recordState("rpc.session.closed:eof");
            android.util.Log.i(TAG, "session " + sessionId + " closed by peer");
        } catch (IOException exception) {
            diagnosticsReporter.recordError("rpc.session.closed", exception);
            android.util.Log.w(
                    TAG,
                    AndroidLogLabel.error("session " + sessionId + " closed", exception)
            );
        } catch (RuntimeException exception) {
            diagnosticsReporter.recordError("rpc.session.crashed", exception);
            android.util.Log.e(
                    TAG,
                    AndroidLogLabel.error("session " + sessionId + " crashed", exception)
            );
        } finally {
            pairingHandler.finishAttempt(sessionState);
            sessionState.closeAndClear();
            transferHandler.closeSession(sessionId);
        }
    }

    /**
     * Keeps the socket alive while a human compares the visible SAS.
     *
     * <p>中文：仅在等待首次配对确认时延长读取超时；其他会话阶段继续使用调用方的
     * 空闲上限，避免把普通连接无界保活。</p>
     */
    static int readTimeoutMillis(RpcSessionState.Phase phase, int idleTimeoutMillis) {
        if (phase == RpcSessionState.Phase.PAIRING_AWAITING_CONFIRM) {
            return Math.max(idleTimeoutMillis, PAIRING_CONFIRM_IDLE_TIMEOUT_MILLIS);
        }
        return idleTimeoutMillis;
    }

    private DispatchResult dispatch(byte[] frame, SessionState sessionState, long sessionId) {
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
            transferHandler.abortCorrelatedStream(sessionId, request.getRequestId());
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNSUPPORTED_VERSION,
                    "unsupported frame_version: " + request.getFrameVersion()
            ));
        }

        boolean isTransferPayload = request.getPayloadType() == PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK
                || request.getPayloadType() == PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK;
        boolean payloadChecksumMatches = RpcEnvelopeValidator.payloadChecksumMatches(request);
        if (isTransferPayload && transferHandler.consumeTerminalFrame(sessionId, request.getRequestId())) {
            // A sender may already have filled the negotiated transfer window
            // when the first terminal response arrives. Drain only late
            // transfer frames for that route; an ordinary unknown ID still
            // receives NOT_FOUND. 中文：仅吸收已终止路由的迟到数据帧。
            if (!payloadChecksumMatches) {
                diagnosticsReporter.recordState("rpc.envelope.payload_crc32_mismatch");
            }
            diagnosticsReporter.recordCounter("rpc.transfer.terminal_frames.drained", 1);
            return DispatchResult.empty();
        }
        if (!payloadChecksumMatches) {
            diagnosticsReporter.recordState("rpc.envelope.payload_crc32_mismatch");
            // The error is correlated by request_id. If a malformed peer reused
            // an active transfer request ID with the wrong payload_type, the Mac
            // route still treats that top-level error as terminal; mirror that
            // ownership decision before replying. 中文：无匹配 route 时为 no-op。
            transferHandler.abortCorrelatedStream(sessionId, request.getRequestId());
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_CHECKSUM_MISMATCH,
                    "envelope payload crc32 mismatch"
            ));
        }

        boolean isTransferStream = request.getKind() == RpcFrameKind.RPC_FRAME_KIND_STREAM && isTransferPayload;
        if (isTransferPayload && !isTransferStream) {
            diagnosticsReporter.recordState("rpc.transfer.invalid_frame_kind");
            transferHandler.abortCorrelatedStream(sessionId, request.getRequestId());
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "transfer chunks and acknowledgements must use stream envelopes"
            ));
        }

        if (request.getKind() != RpcFrameKind.RPC_FRAME_KIND_REQUEST && !isTransferStream) {
            diagnosticsReporter.recordState("rpc.envelope.unexpected:" + request.getKind() + ":" + request.getPayloadType());
            transferHandler.abortCorrelatedStream(sessionId, request.getRequestId());
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "expected request envelope"
            ));
        }

        if (isTransferStream && request.getStreamId() == 0) {
            diagnosticsReporter.recordState("rpc.transfer.stream.invalid_stream_id");
            transferHandler.abortCorrelatedStream(sessionId, request.getRequestId());
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

        if (isTransferStream && request.getRequestId() != request.getStreamId()) {
            diagnosticsReporter.recordState("rpc.transfer.stream.identity_mismatch");
            transferHandler.abortCorrelatedStream(sessionId, request.getRequestId());
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "transfer request_id and stream_id must identify the same active stream"
            ));
        }

        if (sessionState.phase == RpcSessionState.Phase.AWAITING_HELLO
                && request.getPayloadType() != PayloadType.PAYLOAD_TYPE_CLIENT_HELLO
                && request.getPayloadType() != PayloadType.PAYLOAD_TYPE_PAIRING_START_REQUEST) {
            diagnosticsReporter.recordState("rpc.envelope.handshake_required:" + request.getPayloadType());
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNAUTHORIZED,
                    "ClientHello must be the first request on a session"
            ));
        }

        if (sessionState.phase == RpcSessionState.Phase.AWAITING_AUTH
                && request.getPayloadType() != PayloadType.PAYLOAD_TYPE_AUTHENTICATE_SESSION_REQUEST) {
            diagnosticsReporter.recordState("rpc.envelope.authentication_required:" + request.getPayloadType());
            sessionState.closeAndClear();
            return DispatchResult.close(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNAUTHORIZED,
                    "AuthenticateSession must complete before other requests"
            ));
        }

        if (sessionState.phase == RpcSessionState.Phase.PAIRING_AWAITING_CONFIRM
                && request.getPayloadType() != PayloadType.PAYLOAD_TYPE_PAIRING_CONFIRM_REQUEST) {
            diagnosticsReporter.recordState("rpc.pairing.confirm_required:" + request.getPayloadType());
            pairingHandler.finishAttempt(sessionState);
            sessionState.closeAndClear();
            return DispatchResult.close(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNAUTHORIZED,
                    "PairingConfirm must follow PairingStart"
            ));
        }

        if (sessionState.phase == RpcSessionState.Phase.PAIRING_AWAITING_FINALIZE
                && request.getPayloadType() != PayloadType.PAYLOAD_TYPE_PAIRING_FINALIZE_REQUEST) {
            diagnosticsReporter.recordState("rpc.pairing.finalize_required:" + request.getPayloadType());
            pairingHandler.finishAttempt(sessionState);
            sessionState.closeAndClear();
            return DispatchResult.close(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNAUTHORIZED,
                    "PairingFinalize must follow PairingConfirm"
            ));
        }

        if (sessionState.phase == RpcSessionState.Phase.READY
                && (request.getPayloadType() == PayloadType.PAYLOAD_TYPE_CLIENT_HELLO
                || request.getPayloadType() == PayloadType.PAYLOAD_TYPE_AUTHENTICATE_SESSION_REQUEST
                || RpcAuthenticationPolicy.isPairingPayload(request.getPayloadType()))) {
            diagnosticsReporter.recordState("rpc.client_hello.duplicate");
            transferHandler.abortCorrelatedStream(sessionId, request.getRequestId());
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "authentication messages are only valid during session setup"
            ));
        }

        if (sessionState.phase == RpcSessionState.Phase.CLOSED) {
            return DispatchResult.close(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNAUTHORIZED,
                    "session authentication failed"
            ));
        }

        if (sessionState.phase == RpcSessionState.Phase.READY) {
            Capability requiredCapability = requiredCapability(request.getPayloadType());
            if (requiredCapability != null && !sessionState.grantedCapabilities.contains(requiredCapability)) {
                transferHandler.abortCorrelatedStream(sessionId, request.getRequestId());
                return capabilityDenied(request, requiredCapability);
            }
        }

        switch (request.getPayloadType()) {
            case PAYLOAD_TYPE_CLIENT_HELLO:
                return authenticationHandler.clientHello(request, sessionState);
            case PAYLOAD_TYPE_AUTHENTICATE_SESSION_REQUEST:
                return authenticationHandler.authenticateSession(request, sessionState);
            case PAYLOAD_TYPE_PAIRING_START_REQUEST:
                return pairingHandler.start(request, sessionState);
            case PAYLOAD_TYPE_PAIRING_CONFIRM_REQUEST:
                return pairingHandler.confirm(request, sessionState);
            case PAYLOAD_TYPE_PAIRING_FINALIZE_REQUEST:
                return pairingHandler.finalizePairing(request, sessionState);
            case PAYLOAD_TYPE_HEARTBEAT_REQUEST:
                return controlHandler.heartbeat(request);
            case PAYLOAD_TYPE_DEVICE_INFO_REQUEST:
                return controlHandler.deviceInfo(request);
            case PAYLOAD_TYPE_DIAGNOSTICS_REQUEST:
                return controlHandler.diagnostics(request);
            case PAYLOAD_TYPE_LIST_DIR_REQUEST:
                return controlHandler.listDir(request);
            case PAYLOAD_TYPE_CREATE_DIRECTORY_REQUEST:
                return controlHandler.createDirectory(request);
            case PAYLOAD_TYPE_RENAME_PATH_REQUEST:
                return controlHandler.renamePath(request);
            case PAYLOAD_TYPE_DELETE_PATH_REQUEST:
                return controlHandler.deletePath(request);
            case PAYLOAD_TYPE_THUMBNAIL_REQUEST:
                return controlHandler.thumbnail(request);
            case PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST:
                return transferHandler.open(request, sessionState.grantedCapabilities, sessionId);
            case PAYLOAD_TYPE_TRANSFER_CHUNK:
                return transferHandler.receiveChunk(request, sessionId);
            case PAYLOAD_TYPE_TRANSFER_CHUNK_ACK:
                return transferHandler.acknowledgeChunk(request, sessionId);
            case PAYLOAD_TYPE_CANCEL_TRANSFER_REQUEST:
                return transferHandler.cancel(request, sessionId);
            case PAYLOAD_TYPE_PAUSE_TRANSFER_REQUEST:
                return transferHandler.pause(request, sessionId);
            default:
                diagnosticsReporter.recordState("rpc.envelope.unsupported_payload:" + request.getPayloadType());
                transferHandler.abortCorrelatedStream(sessionId, request.getRequestId());
                return DispatchResult.response(errorEnvelope(
                        request.getRequestId(),
                        ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                        "unsupported payload_type: " + request.getPayloadType()
                ));
        }
    }

    RpcEnvelope[] dispatchForTest(byte[] frame, boolean ready, long sessionId) {
        SessionState state = new SessionState();
        if (ready) {
            authenticationHandler.markReadyForTest(state);
        }
        DispatchResult result = dispatch(frame, state, sessionId);
        return result.responses.toArray(new RpcEnvelope[0]);
    }

    SessionState newSessionStateForTest() {
        return new SessionState();
    }

    RpcEnvelope[] dispatchForTest(byte[] frame, SessionState state, long sessionId) {
        DispatchResult result = dispatch(frame, state, sessionId);
        return result.responses.toArray(new RpcEnvelope[0]);
    }

    static RpcEnvelope errorEnvelope(long requestId, ErrorCode code, String message) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_ERROR)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_DROIDMATCH_ERROR)
                .setError(error(code, message))
                .build();
    }

    static RpcEnvelope responseEnvelope(long requestId, PayloadType payloadType, ByteString payload) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_RESPONSE)
                .setRequestId(requestId)
                .setPayloadType(payloadType)
                .setPayload(payload)
                .build();
    }

    private DispatchResult capabilityDenied(RpcEnvelope request, Capability capability) {
        diagnosticsReporter.recordState("rpc.capability.denied:" + capability);
        return DispatchResult.response(errorEnvelope(
                request.getRequestId(),
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "capability not granted: " + capability
        ));
    }

    private static Capability requiredCapability(PayloadType payloadType) {
        switch (payloadType) {
            case PAYLOAD_TYPE_DEVICE_INFO_REQUEST:
            case PAYLOAD_TYPE_DIAGNOSTICS_REQUEST:
                return Capability.CAPABILITY_DIAGNOSTICS;
            case PAYLOAD_TYPE_LIST_DIR_REQUEST:
                return Capability.CAPABILITY_FILE_LIST;
            case PAYLOAD_TYPE_THUMBNAIL_REQUEST:
                return Capability.CAPABILITY_FILE_READ;
            case PAYLOAD_TYPE_CREATE_DIRECTORY_REQUEST:
            case PAYLOAD_TYPE_DELETE_PATH_REQUEST:
            case PAYLOAD_TYPE_RENAME_PATH_REQUEST:
                return Capability.CAPABILITY_FILE_WRITE;
            case PAYLOAD_TYPE_TRANSFER_CHUNK:
                return Capability.CAPABILITY_FILE_WRITE;
            case PAYLOAD_TYPE_TRANSFER_CHUNK_ACK:
                return Capability.CAPABILITY_FILE_READ;
            case PAYLOAD_TYPE_CANCEL_TRANSFER_REQUEST:
            case PAYLOAD_TYPE_PAUSE_TRANSFER_REQUEST:
                return Capability.CAPABILITY_RESUMABLE_TRANSFER;
            default:
                return null;
        }
    }

    static DroidMatchError error(ErrorCode code, String message) {
        return DroidMatchError.newBuilder()
                .setCode(code)
                .setMessage(message == null ? "" : message)
                .build();
    }

    /** Test-source compatibility alias; product code uses RpcSessionState. */
    static final class SessionState extends RpcSessionState {
    }

    static final class DispatchResult {
        private final List<RpcEnvelope> responses;
        private final boolean closeSession;

        private DispatchResult(List<RpcEnvelope> responses, boolean closeSession) {
            this.responses = responses;
            this.closeSession = closeSession;
        }

        static DispatchResult empty() {
            return new DispatchResult(Arrays.asList(), false);
        }

        static DispatchResult response(RpcEnvelope response) {
            return new DispatchResult(Arrays.asList(response), false);
        }

        static DispatchResult responses(RpcEnvelope first, RpcEnvelope second) {
            return new DispatchResult(Arrays.asList(first, second), false);
        }

        static DispatchResult responses(List<RpcEnvelope> responses) {
            return new DispatchResult(responses, false);
        }

        static DispatchResult close(RpcEnvelope response) {
            return new DispatchResult(Arrays.asList(response), true);
        }
    }
}
