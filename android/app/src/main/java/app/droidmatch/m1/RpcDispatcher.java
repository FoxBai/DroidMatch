package app.droidmatch.m1;

import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.AuthenticateSessionRequest;
import app.droidmatch.proto.v1.AuthenticateSessionResponse;
import app.droidmatch.proto.v1.AuthenticationState;
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
import app.droidmatch.proto.v1.PairingConfirmRequest;
import app.droidmatch.proto.v1.PairingConfirmResponse;
import app.droidmatch.proto.v1.PairingFinalizeRequest;
import app.droidmatch.proto.v1.PairingFinalizeResponse;
import app.droidmatch.proto.v1.PairingStartRequest;
import app.droidmatch.proto.v1.PairingStartResponse;
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
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Deque;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.zip.CRC32;

public final class RpcDispatcher {
    private static final String TAG = "DroidMatchRpc";
    private static final int FRAME_VERSION = 1;
    private static final int PROTOCOL_MAJOR = 1;
    private static final int PROTOCOL_MINOR = 0;
    private static final int MIN_SESSION_NONCE_BYTES = 16;
    private static final int MAX_SESSION_NONCE_BYTES = 32;
    private static final int DEFAULT_TRANSFER_CHUNK_SIZE_BYTES = 256 * 1024;
    private static final int MAX_TRANSFER_CHUNK_SIZE_BYTES = 1024 * 1024;
    private static final int MAX_DOWNLOAD_IN_FLIGHT_CHUNKS = 4;
    private static final int MAX_DOWNLOAD_IN_FLIGHT_BYTES = 2 * 1024 * 1024;
    private static final int MAX_CONCURRENT_TRANSFER_STREAMS = 2;
    private static final long PAIRING_APPROVAL_TIMEOUT_MILLIS = 60_000L;
    private static final List<Capability> SUPPORTED_CAPABILITIES = Arrays.asList(
            Capability.CAPABILITY_FILE_LIST,
            Capability.CAPABILITY_FILE_READ,
            Capability.CAPABILITY_FILE_WRITE,
            Capability.CAPABILITY_RESUMABLE_TRANSFER,
            Capability.CAPABILITY_DIAGNOSTICS
    );

    private final DiagnosticsReporter diagnosticsReporter;
    private final PermissionStateProvider permissionStateProvider;
    private final DmFileProvider fileProvider;
    private final AndroidDeviceInfoProvider deviceInfoProvider;
    private final SessionAuthenticationMode authenticationMode;
    private final PairingKeyProvider pairingKeyProvider;
    private final PairingCredentialRepository pairingCredentialRepository;
    private final PairingApprovalController pairingApprovalController;
    private final DeviceIdentityProvider deviceIdentityProvider;
    private final AuthenticationRateLimiter authenticationRateLimiter;
    private final SecureRandom secureRandom;
    private final AtomicLong nextSessionId = new AtomicLong(1);
    private final ConcurrentMap<String, DownloadTransfer> activeDownloadTransfers = new ConcurrentHashMap<>();
    private final ConcurrentMap<String, UploadTransfer> activeUploadTransfers = new ConcurrentHashMap<>();

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
        this.deviceInfoProvider = deviceInfoProvider;
        this.authenticationMode = Objects.requireNonNull(authenticationMode, "authenticationMode");
        this.pairingKeyProvider = Objects.requireNonNull(pairingKeyProvider, "pairingKeyProvider");
        this.pairingCredentialRepository = pairingCredentialRepository;
        this.pairingApprovalController = pairingApprovalController;
        this.deviceIdentityProvider = deviceIdentityProvider;
        this.authenticationRateLimiter = Objects.requireNonNull(
                authenticationRateLimiter,
                "authenticationRateLimiter"
        );
        this.secureRandom = new SecureRandom();
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

            while (!client.isClosed()) {
                client.setSoTimeout(idleTimeoutMillis);
                byte[] frame = FramedIo.readFrame(client.getInputStream());
                diagnosticsReporter.recordCounter("rpc.frames.received", 1);
                android.util.Log.i(TAG, "session " + sessionId + " received frame bytes=" + frame.length);
                DispatchResult result = dispatch(frame, sessionState, sessionId);
                for (RpcEnvelope response : result.responses) {
                    FramedIo.writeFrame(client.getOutputStream(), response.toByteArray());
                    diagnosticsReporter.recordCounter("rpc.frames.sent", 1);
                    android.util.Log.i(
                            TAG,
                            "session " + sessionId + " sent " + response.getKind() + "/" + response.getPayloadType()
                    );
                }
                if (result.closeSession) {
                    diagnosticsReporter.recordState("rpc.session.closed:authentication");
                    break;
                }
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
            finishPairingAttempt(sessionState);
            sessionState.closeAndClear();
            closeSessionTransfers(sessionId);
        }
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

        if (sessionState.phase == SessionPhase.AWAITING_HELLO
                && request.getPayloadType() != PayloadType.PAYLOAD_TYPE_CLIENT_HELLO
                && request.getPayloadType() != PayloadType.PAYLOAD_TYPE_PAIRING_START_REQUEST) {
            diagnosticsReporter.recordState("rpc.envelope.handshake_required:" + request.getPayloadType());
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNAUTHORIZED,
                    "ClientHello must be the first request on a session"
            ));
        }

        if (sessionState.phase == SessionPhase.AWAITING_AUTH
                && request.getPayloadType() != PayloadType.PAYLOAD_TYPE_AUTHENTICATE_SESSION_REQUEST) {
            diagnosticsReporter.recordState("rpc.envelope.authentication_required:" + request.getPayloadType());
            sessionState.closeAndClear();
            return DispatchResult.close(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNAUTHORIZED,
                    "AuthenticateSession must complete before other requests"
            ));
        }

        if (sessionState.phase == SessionPhase.PAIRING_AWAITING_CONFIRM
                && request.getPayloadType() != PayloadType.PAYLOAD_TYPE_PAIRING_CONFIRM_REQUEST) {
            diagnosticsReporter.recordState("rpc.pairing.confirm_required:" + request.getPayloadType());
            finishPairingAttempt(sessionState);
            sessionState.closeAndClear();
            return DispatchResult.close(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNAUTHORIZED,
                    "PairingConfirm must follow PairingStart"
            ));
        }

        if (sessionState.phase == SessionPhase.PAIRING_AWAITING_FINALIZE
                && request.getPayloadType() != PayloadType.PAYLOAD_TYPE_PAIRING_FINALIZE_REQUEST) {
            diagnosticsReporter.recordState("rpc.pairing.finalize_required:" + request.getPayloadType());
            finishPairingAttempt(sessionState);
            sessionState.closeAndClear();
            return DispatchResult.close(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNAUTHORIZED,
                    "PairingFinalize must follow PairingConfirm"
            ));
        }

        if (sessionState.phase == SessionPhase.READY
                && (request.getPayloadType() == PayloadType.PAYLOAD_TYPE_CLIENT_HELLO
                || request.getPayloadType() == PayloadType.PAYLOAD_TYPE_AUTHENTICATE_SESSION_REQUEST
                || isPairingPayload(request.getPayloadType()))) {
            diagnosticsReporter.recordState("rpc.client_hello.duplicate");
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "authentication messages are only valid during session setup"
            ));
        }

        if (sessionState.phase == SessionPhase.CLOSED) {
            return DispatchResult.close(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNAUTHORIZED,
                    "session authentication failed"
            ));
        }

        if (sessionState.phase == SessionPhase.READY) {
            Capability requiredCapability = requiredCapability(request.getPayloadType());
            if (requiredCapability != null && !sessionState.grantedCapabilities.contains(requiredCapability)) {
                return capabilityDenied(request, requiredCapability);
            }
        }

        switch (request.getPayloadType()) {
            case PAYLOAD_TYPE_CLIENT_HELLO:
                return handleClientHello(request, sessionState);
            case PAYLOAD_TYPE_AUTHENTICATE_SESSION_REQUEST:
                return handleAuthenticateSession(request, sessionState);
            case PAYLOAD_TYPE_PAIRING_START_REQUEST:
                return handlePairingStart(request, sessionState);
            case PAYLOAD_TYPE_PAIRING_CONFIRM_REQUEST:
                return handlePairingConfirm(request, sessionState);
            case PAYLOAD_TYPE_PAIRING_FINALIZE_REQUEST:
                return handlePairingFinalize(request, sessionState);
            case PAYLOAD_TYPE_HEARTBEAT_REQUEST:
                return handleHeartbeat(request);
            case PAYLOAD_TYPE_DEVICE_INFO_REQUEST:
                return handleDeviceInfo(request);
            case PAYLOAD_TYPE_DIAGNOSTICS_REQUEST:
                return handleDiagnostics(request);
            case PAYLOAD_TYPE_LIST_DIR_REQUEST:
                return handleListDir(request);
            case PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST:
                return handleOpenTransfer(request, sessionState, sessionId);
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

    RpcEnvelope[] dispatchForTest(byte[] frame, boolean ready, long sessionId) {
        SessionState state = new SessionState();
        if (ready) {
            state.markReadyAndClear(SUPPORTED_CAPABILITIES);
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

    private DispatchResult handleClientHello(RpcEnvelope request, SessionState sessionState) {
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

        int sessionNonceLength = hello.getSessionNonce().size();
        if (sessionNonceLength < MIN_SESSION_NONCE_BYTES
                || sessionNonceLength > MAX_SESSION_NONCE_BYTES) {
            // Log only the length. The nonce itself must never enter diagnostics.
            diagnosticsReporter.recordState("rpc.client_hello.invalid_nonce_length:" + sessionNonceLength);
            return DispatchResult.response(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "session_nonce must be 16 to 32 bytes"
            ));
        }

        if (authenticationMode == SessionAuthenticationMode.PAIRED_REQUIRED
                && sessionNonceLength != SessionAuthenticator.NONCE_LENGTH) {
            diagnosticsReporter.recordState("rpc.client_hello.paired_nonce_length:" + sessionNonceLength);
            sessionState.closeAndClear();
            return DispatchResult.close(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "paired sessions require a 32-byte session_nonce"
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

        if (authenticationMode == SessionAuthenticationMode.NONCE_ONLY) {
            serverHello.setAuthenticationState(AuthenticationState.AUTHENTICATION_STATE_CORRELATED);
            List<Capability> grantedCapabilities = grantCapabilities(hello.getRequestedCapabilitiesList());
            serverHello.addAllGrantedCapabilities(grantedCapabilities);
            sessionState.markReadyAndClear(grantedCapabilities);
            diagnosticsReporter.recordCounter("rpc.handshakes.accepted", 1);
            return DispatchResult.response(serverHelloEnvelope(request.getRequestId(), serverHello));
        }

        int pairingIdLength = hello.getPairingId().size();
        if (pairingIdLength == 0) {
            serverHello.setAuthenticationState(AuthenticationState.AUTHENTICATION_STATE_PAIRING_REQUIRED);
            sessionState.phase = SessionPhase.CLOSED;
            diagnosticsReporter.recordState("rpc.authentication.pairing_required");
            return DispatchResult.close(serverHelloEnvelope(request.getRequestId(), serverHello));
        }
        if (pairingIdLength != SessionAuthenticator.PAIRING_ID_LENGTH) {
            diagnosticsReporter.recordState("rpc.authentication.invalid_pairing_id_length:" + pairingIdLength);
            sessionState.phase = SessionPhase.CLOSED;
            return DispatchResult.close(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "pairing_id must be 16 bytes"
            ));
        }

        byte[] pairingId = hello.getPairingId().toByteArray();
        byte[] storedPairingKey = pairingKeyProvider.pairingKey(Arrays.copyOf(pairingId, pairingId.length));
        boolean pairingRecognized = storedPairingKey != null;
        byte[] proofKey;
        if (pairingRecognized) {
            if (storedPairingKey.length != SessionAuthenticator.PAIRING_KEY_LENGTH) {
                Arrays.fill(storedPairingKey, (byte) 0);
                throw new IllegalStateException("PairingKeyProvider returned an invalid key length");
            }
            proofKey = Arrays.copyOf(storedPairingKey, storedPairingKey.length);
        } else {
            // Unknown identifiers take the same challenge/proof path as known ones.
            proofKey = new byte[SessionAuthenticator.PAIRING_KEY_LENGTH];
            secureRandom.nextBytes(proofKey);
        }

        byte[] serverNonce = new byte[SessionAuthenticator.NONCE_LENGTH];
        try {
            secureRandom.nextBytes(serverNonce);
            int selectedMinor = Math.min(hello.getProtocolMinor(), PROTOCOL_MINOR);
            byte[] transcriptHash = SessionAuthenticator.transcriptHash(SessionAuthenticator.transcript(
                    pairingId,
                    hello.getSessionNonce().toByteArray(),
                    serverNonce,
                    PROTOCOL_MAJOR,
                    selectedMinor,
                    TransportKind.TRANSPORT_KIND_ADB.getNumber()
            ));
            sessionState.beginAuthentication(
                    pairingId,
                    proofKey,
                    transcriptHash,
                    pairingRecognized,
                    hello.getRequestedCapabilitiesList()
            );
        } finally {
            Arrays.fill(proofKey, (byte) 0);
            if (storedPairingKey != null) {
                Arrays.fill(storedPairingKey, (byte) 0);
            }
        }
        serverHello
                .setServerNonce(ByteString.copyFrom(serverNonce))
                .setAuthenticationState(AuthenticationState.AUTHENTICATION_STATE_REQUIRED);
        diagnosticsReporter.recordCounter("rpc.authentication.challenges", 1);
        return DispatchResult.response(serverHelloEnvelope(request.getRequestId(), serverHello));
    }

    private RpcEnvelope serverHelloEnvelope(long requestId, ServerHello.Builder serverHello) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_RESPONSE)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_SERVER_HELLO)
                .setPayload(serverHello.build().toByteString())
                .build();
    }

    private DispatchResult handleAuthenticateSession(RpcEnvelope request, SessionState sessionState) {
        AuthenticateSessionRequest authenticate;
        try {
            authenticate = AuthenticateSessionRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.authentication.invalid", exception);
            if (sessionState.pairingId != null) {
                authenticationRateLimiter.recordReconnectFailure(sessionState.pairingId);
            }
            sessionState.closeAndClear();
            return DispatchResult.close(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "AuthenticateSessionRequest payload is invalid"
            ));
        }

        byte[] candidatePairingId = authenticate.getPairingId().toByteArray();
        byte[] candidateProof = authenticate.getClientProof().toByteArray();
        boolean pairingMatches = MessageDigest.isEqual(sessionState.pairingId, candidatePairingId);
        boolean proofMatches = SessionAuthenticator.verifyClientProof(
                candidateProof,
                sessionState.proofKey,
                sessionState.transcriptHash
        );
        boolean proofAuthenticated = sessionState.pairingRecognized
                && pairingMatches
                && proofMatches;
        boolean rateLimitAllowed = authenticationRateLimiter.reconnectAllowed(
                sessionState.pairingId
        );
        boolean authenticated = proofAuthenticated && rateLimitAllowed;

        AuthenticateSessionResponse.Builder response = AuthenticateSessionResponse.newBuilder();
        if (!authenticated) {
            diagnosticsReporter.recordCounter("rpc.authentication.rejected", 1);
            if (proofAuthenticated) {
                // A correct proof is still rejected during backoff, but receives
                // the same response as every other failure to avoid an oracle.
                diagnosticsReporter.recordCounter("rpc.authentication.rate_limited", 1);
            } else if (rateLimitAllowed) {
                authenticationRateLimiter.recordReconnectFailure(sessionState.pairingId);
            }
            response.setAuthenticated(false).setError(DroidMatchError.newBuilder()
                    .setCode(ErrorCode.ERROR_CODE_UNAUTHORIZED)
                    .setMessage("session authentication failed"));
            sessionState.closeAndClear();
            return DispatchResult.close(responseEnvelope(
                    request.getRequestId(),
                    PayloadType.PAYLOAD_TYPE_AUTHENTICATE_SESSION_RESPONSE,
                    response.build().toByteString()
            ));
        }

        authenticationRateLimiter.recordReconnectSuccess(sessionState.pairingId);
        response
                .setAuthenticated(true)
                .setServerProof(ByteString.copyFrom(SessionAuthenticator.serverProof(
                        sessionState.proofKey,
                        sessionState.transcriptHash
                )));
        List<Capability> grantedCapabilities = grantCapabilities(sessionState.requestedCapabilities);
        response.addAllGrantedCapabilities(grantedCapabilities);
        sessionState.markReadyAndClear(grantedCapabilities);
        diagnosticsReporter.recordCounter("rpc.handshakes.accepted", 1);
        diagnosticsReporter.recordCounter("rpc.authentication.accepted", 1);
        return DispatchResult.response(responseEnvelope(
                request.getRequestId(),
                PayloadType.PAYLOAD_TYPE_AUTHENTICATE_SESSION_RESPONSE,
                response.build().toByteString()
        ));
    }

    private DispatchResult handlePairingStart(RpcEnvelope request, SessionState sessionState) {
        if (!pairingRuntimeAvailable()
                || !pairingApprovalController.snapshot().windowOpen()) {
            diagnosticsReporter.recordState("rpc.pairing.window_closed");
            return closePairingStartError(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "a visible Android pairing window is required",
                    "Open DroidMatch on Android and tap Open pairing window"
            );
        }
        if (!authenticationRateLimiter.firstPairingAllowed()) {
            diagnosticsReporter.recordCounter("rpc.pairing.rate_limited", 1);
            return closePairingStartError(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_TIMEOUT,
                    "pairing is temporarily unavailable",
                    "Wait briefly and try again while the pairing window is open"
            );
        }

        PairingStartRequest start;
        try {
            start = PairingStartRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.pairing.start.invalid", exception);
            authenticationRateLimiter.recordFirstPairingFailure();
            return DispatchResult.close(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "PairingStartRequest payload is invalid"
            ));
        }
        if (start.getPairingVersion() != PairingAuthenticator.VERSION) {
            authenticationRateLimiter.recordFirstPairingFailure();
            return closePairingStartError(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNSUPPORTED_VERSION,
                    "unsupported pairing version",
                    "Update DroidMatch on both devices"
            );
        }

        byte[] pairingId;
        try {
            pairingId = generateUniquePairingId();
        } catch (RuntimeException exception) {
            diagnosticsReporter.recordError("rpc.pairing.id_generation_failed", exception);
            return closePairingStartError(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "pairing identifier could not be allocated",
                    "Close and reopen the pairing window"
            );
        }
        byte[] serverNonce = new byte[PairingAuthenticator.NONCE_LENGTH];
        secureRandom.nextBytes(serverNonce);
        PairingKeyAgreement serverKeyAgreement = PairingKeyAgreement.generate();
        byte[] clientPublicKey = start.getClientPublicKey().toByteArray();
        byte[] serverPublicKey = serverKeyAgreement.publicKeyX963Representation();
        byte[] deviceIdentityPublicKey = deviceIdentityProvider.publicKeyX963Representation();
        byte[] deviceIdentityFingerprint = deviceIdentityProvider.fingerprint();
        byte[] expectedFingerprint = PairingAuthenticator.transcriptHash(deviceIdentityPublicKey);
        if (!MessageDigest.isEqual(deviceIdentityFingerprint, expectedFingerprint)) {
            diagnosticsReporter.recordState("rpc.pairing.identity_fingerprint_mismatch");
            return closePairingStartError(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "device identity is unavailable",
                    "Reopen DroidMatch and try again"
            );
        }

        byte[] sharedSecret = null;
        byte[] transcriptHash = null;
        byte[] confirmationKey = null;
        byte[] pairingKey = null;
        try {
            sharedSecret = serverKeyAgreement.sharedSecret(clientPublicKey);
            byte[] transcript = PairingAuthenticator.transcript(
                    start.getPairingVersion(),
                    pairingId,
                    clientPublicKey,
                    serverPublicKey,
                    deviceIdentityPublicKey,
                    start.getClientNonce().toByteArray(),
                    serverNonce,
                    start.getClientName(),
                    "DroidMatch Android"
            );
            transcriptHash = PairingAuthenticator.transcriptHash(transcript);
            byte[] identitySignature = deviceIdentityProvider.signPairingTranscript(transcript);
            try (PairingAuthenticator.DerivedSecrets secrets = PairingAuthenticator.deriveSecrets(
                    sharedSecret,
                    transcriptHash
            )) {
                confirmationKey = secrets.confirmationKey();
                pairingKey = secrets.pairingKey();
                if (!pairingApprovalController.beginAttempt(
                        pairingId,
                        start.getClientName(),
                        secrets.shortAuthenticationString()
                )) {
                    diagnosticsReporter.recordState("rpc.pairing.window_unavailable");
                    return closePairingStartError(
                            request.getRequestId(),
                            ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                            "pairing window expired or already has a request",
                            "Open a new pairing window and try again"
                    );
                }
            }

            sessionState.beginFirstPairing(
                    pairingId,
                    transcriptHash,
                    confirmationKey,
                    pairingKey,
                    deviceIdentityFingerprint,
                    start.getClientName()
            );
            diagnosticsReporter.recordCounter("rpc.pairing.started", 1);
            PairingStartResponse response = PairingStartResponse.newBuilder()
                    .setPairingVersion(PairingAuthenticator.VERSION)
                    .setServerName("DroidMatch Android")
                    .setServerPublicKey(ByteString.copyFrom(serverPublicKey))
                    .setServerNonce(ByteString.copyFrom(serverNonce))
                    .setPairingId(ByteString.copyFrom(pairingId))
                    .setDeviceIdentityPublicKey(ByteString.copyFrom(deviceIdentityPublicKey))
                    .setDeviceIdentitySignature(ByteString.copyFrom(identitySignature))
                    .build();
            return DispatchResult.response(responseEnvelope(
                    request.getRequestId(),
                    PayloadType.PAYLOAD_TYPE_PAIRING_START_RESPONSE,
                    response.toByteString()
            ));
        } catch (IllegalArgumentException exception) {
            diagnosticsReporter.recordState("rpc.pairing.start.rejected_input");
            authenticationRateLimiter.recordFirstPairingFailure();
            finishPairingAttempt(sessionState, pairingId);
            sessionState.closeAndClear();
            return DispatchResult.close(errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "pairing start fields are invalid"
            ));
        } catch (RuntimeException exception) {
            diagnosticsReporter.recordError("rpc.pairing.start.failed", exception);
            finishPairingAttempt(sessionState, pairingId);
            sessionState.closeAndClear();
            return closePairingStartError(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "pairing could not start",
                    "Close and reopen the pairing window"
            );
        } finally {
            clear(sharedSecret);
            clear(transcriptHash);
            clear(confirmationKey);
            clear(pairingKey);
        }
    }

    private DispatchResult handlePairingConfirm(RpcEnvelope request, SessionState sessionState) {
        PairingConfirmRequest confirm;
        try {
            confirm = PairingConfirmRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.pairing.confirm.invalid", exception);
            authenticationRateLimiter.recordFirstPairingFailure();
            return closePairingConfirmError(
                    request.getRequestId(),
                    sessionState,
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "PairingConfirmRequest payload is invalid"
            );
        }

        byte[] candidatePairingId = confirm.getPairingId().toByteArray();
        boolean pairingIdMatches = sessionState.matchesFirstPairingId(candidatePairingId);
        boolean confirmationMatches = PairingAuthenticator.verifyClientConfirmation(
                confirm.getClientConfirmation().toByteArray(),
                sessionState.firstPairingConfirmationKey,
                sessionState.firstPairingTranscriptHash
        );
        if (!confirm.getClientApproved() || !pairingIdMatches || !confirmationMatches) {
            diagnosticsReporter.recordCounter("rpc.pairing.confirm_rejected", 1);
            if (confirm.getClientApproved() && (!pairingIdMatches || !confirmationMatches)) {
                authenticationRateLimiter.recordFirstPairingFailure();
            }
            return closePairingConfirmError(
                    request.getRequestId(),
                    sessionState,
                    ErrorCode.ERROR_CODE_UNAUTHORIZED,
                    "pairing confirmation failed"
            );
        }

        PairingApprovalController.Decision decision;
        try {
            decision = pairingApprovalController.awaitDecision(
                    sessionState.firstPairingId,
                    PAIRING_APPROVAL_TIMEOUT_MILLIS
            );
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            return closePairingConfirmError(
                    request.getRequestId(),
                    sessionState,
                    ErrorCode.ERROR_CODE_CANCELLED,
                    "pairing approval was interrupted"
            );
        }
        if (decision != PairingApprovalController.Decision.APPROVED) {
            ErrorCode code = decision == PairingApprovalController.Decision.EXPIRED
                    ? ErrorCode.ERROR_CODE_TIMEOUT
                    : ErrorCode.ERROR_CODE_CANCELLED;
            return closePairingConfirmError(
                    request.getRequestId(),
                    sessionState,
                    code,
                    decision == PairingApprovalController.Decision.EXPIRED
                            ? "pairing approval timed out"
                            : "pairing was rejected on Android"
            );
        }

        byte[] serverConfirmation = PairingAuthenticator.serverConfirmation(
                sessionState.firstPairingConfirmationKey,
                sessionState.firstPairingTranscriptHash
        );
        sessionState.markFirstPairingConfirmed(serverConfirmation);
        diagnosticsReporter.recordCounter("rpc.pairing.confirmed", 1);
        PairingConfirmResponse response = PairingConfirmResponse.newBuilder()
                .setClientConfirmationAccepted(true)
                .setServerApproved(true)
                .setServerConfirmation(ByteString.copyFrom(serverConfirmation))
                .build();
        clear(serverConfirmation);
        return DispatchResult.response(responseEnvelope(
                request.getRequestId(),
                PayloadType.PAYLOAD_TYPE_PAIRING_CONFIRM_RESPONSE,
                response.toByteString()
        ));
    }

    private DispatchResult handlePairingFinalize(RpcEnvelope request, SessionState sessionState) {
        PairingFinalizeRequest finalize;
        try {
            finalize = PairingFinalizeRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.pairing.finalize.invalid", exception);
            authenticationRateLimiter.recordFirstPairingFailure();
            return closePairingFinalizeError(
                    request.getRequestId(),
                    sessionState,
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "PairingFinalizeRequest payload is invalid"
            );
        }
        boolean pairingIdMatches = sessionState.matchesFirstPairingId(
                finalize.getPairingId().toByteArray()
        );
        boolean finalConfirmationMatches = PairingAuthenticator.verifyFinalConfirmation(
                finalize.getFinalConfirmation().toByteArray(),
                sessionState.firstPairingConfirmationKey,
                sessionState.firstPairingTranscriptHash,
                sessionState.firstPairingServerConfirmation
        );
        if (!pairingIdMatches || !finalConfirmationMatches) {
            diagnosticsReporter.recordCounter("rpc.pairing.finalize_rejected", 1);
            authenticationRateLimiter.recordFirstPairingFailure();
            return closePairingFinalizeError(
                    request.getRequestId(),
                    sessionState,
                    ErrorCode.ERROR_CODE_UNAUTHORIZED,
                    "pairing finalization failed"
            );
        }

        byte[] pairingKey = Arrays.copyOf(
                sessionState.firstPairingKey,
                sessionState.firstPairingKey.length
        );
        try {
            long now = System.currentTimeMillis();
            pairingCredentialRepository.save(new PairingCredentialRecord(
                    sessionState.firstPairingId,
                    sessionState.firstPairingDeviceFingerprint,
                    pairingKey,
                    sessionState.firstPairingClientName,
                    now,
                    now
            ));
        } catch (RuntimeException exception) {
            diagnosticsReporter.recordError("rpc.pairing.persist_failed", exception);
            return closePairingFinalizeError(
                    request.getRequestId(),
                    sessionState,
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "pairing credential could not be stored"
            );
        } finally {
            clear(pairingKey);
        }

        PairingFinalizeResponse response = PairingFinalizeResponse.newBuilder()
                .setPaired(true)
                .build();
        authenticationRateLimiter.recordFirstPairingSuccess();
        diagnosticsReporter.recordCounter("rpc.pairing.completed", 1);
        finishPairingAttempt(sessionState);
        sessionState.closeAndClear();
        return DispatchResult.close(responseEnvelope(
                request.getRequestId(),
                PayloadType.PAYLOAD_TYPE_PAIRING_FINALIZE_RESPONSE,
                response.toByteString()
        ));
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

    private DispatchResult handleOpenTransfer(
            RpcEnvelope request,
            SessionState sessionState,
            long sessionId
    ) {
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
        TransferDirection direction = openRequest.getDirection();
        if (direction != TransferDirection.TRANSFER_DIRECTION_DOWNLOAD
                && direction != TransferDirection.TRANSFER_DIRECTION_UPLOAD) {
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
        Capability requiredCapability = direction == TransferDirection.TRANSFER_DIRECTION_UPLOAD
                ? Capability.CAPABILITY_FILE_WRITE
                : Capability.CAPABILITY_FILE_READ;
        if (!sessionState.grantedCapabilities.contains(requiredCapability)) {
            return capabilityDenied(request, requiredCapability);
        }
        if (openRequest.getRequestedOffsetBytes() > 0
                && !sessionState.grantedCapabilities.contains(Capability.CAPABILITY_RESUMABLE_TRANSFER)) {
            return capabilityDenied(request, Capability.CAPABILITY_RESUMABLE_TRANSFER);
        }

        if (hasActiveTransferId(sessionId, openRequest.getTransferId())) {
            return DispatchResult.response(openTransferResponse(
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
            return DispatchResult.response(openTransferResponse(
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
            return DispatchResult.response(openTransferResponse(
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
            return handleOpenUploadTransfer(request, openRequest, sessionId);
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

        DownloadTransfer downloadTransfer = removeSessionTransfer(sessionId, transferId);
        UploadTransfer uploadTransfer = null;
        if (downloadTransfer == null) {
            uploadTransfer = removeSessionUploadTransfer(sessionId, transferId);
        }
        if (downloadTransfer == null && uploadTransfer == null) {
            return DispatchResult.response(cancelTransferResponse(
                    request.getRequestId(),
                    transferId,
                    false,
                    error(ErrorCode.ERROR_CODE_NOT_FOUND, "unknown transfer")
            ));
        }

        closeTransfer(downloadTransfer);
        closeUploadTransfer(uploadTransfer);
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

        long resumableOffsetBytes = transfer.acknowledgedOffsetBytes;
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

    private DispatchResult closePairingStartError(
            long requestId,
            ErrorCode code,
            String message,
            String userAction
    ) {
        PairingStartResponse response = PairingStartResponse.newBuilder()
                .setError(DroidMatchError.newBuilder()
                        .setCode(code)
                        .setMessage(message)
                        .setUserAction(userAction))
                .build();
        return DispatchResult.close(responseEnvelope(
                requestId,
                PayloadType.PAYLOAD_TYPE_PAIRING_START_RESPONSE,
                response.toByteString()
        ));
    }

    private DispatchResult closePairingConfirmError(
            long requestId,
            SessionState sessionState,
            ErrorCode code,
            String message
    ) {
        PairingConfirmResponse response = PairingConfirmResponse.newBuilder()
                .setError(error(code, message))
                .build();
        finishPairingAttempt(sessionState);
        sessionState.closeAndClear();
        return DispatchResult.close(responseEnvelope(
                requestId,
                PayloadType.PAYLOAD_TYPE_PAIRING_CONFIRM_RESPONSE,
                response.toByteString()
        ));
    }

    private DispatchResult closePairingFinalizeError(
            long requestId,
            SessionState sessionState,
            ErrorCode code,
            String message
    ) {
        PairingFinalizeResponse response = PairingFinalizeResponse.newBuilder()
                .setError(error(code, message))
                .build();
        finishPairingAttempt(sessionState);
        sessionState.closeAndClear();
        return DispatchResult.close(responseEnvelope(
                requestId,
                PayloadType.PAYLOAD_TYPE_PAIRING_FINALIZE_RESPONSE,
                response.toByteString()
        ));
    }

    private boolean pairingRuntimeAvailable() {
        return pairingCredentialRepository != null
                && pairingApprovalController != null
                && deviceIdentityProvider != null;
    }

    private byte[] generateUniquePairingId() {
        for (int attempt = 0; attempt < 16; attempt += 1) {
            byte[] candidate = new byte[PairingAuthenticator.PAIRING_ID_LENGTH];
            secureRandom.nextBytes(candidate);
            if (pairingCredentialRepository.load(candidate) == null) {
                return candidate;
            }
            clear(candidate);
        }
        throw new IllegalStateException("could not allocate a unique pairing ID");
    }

    private void finishPairingAttempt(SessionState sessionState) {
        finishPairingAttempt(sessionState, sessionState.firstPairingId);
    }

    private void finishPairingAttempt(SessionState sessionState, byte[] pairingId) {
        if (pairingApprovalController != null && pairingId != null
                && pairingId.length == PairingAuthenticator.PAIRING_ID_LENGTH) {
            pairingApprovalController.finishAttempt(pairingId);
        }
    }

    private static boolean isPairingPayload(PayloadType payloadType) {
        return payloadType == PayloadType.PAYLOAD_TYPE_PAIRING_START_REQUEST
                || payloadType == PayloadType.PAYLOAD_TYPE_PAIRING_START_RESPONSE
                || payloadType == PayloadType.PAYLOAD_TYPE_PAIRING_CONFIRM_REQUEST
                || payloadType == PayloadType.PAYLOAD_TYPE_PAIRING_CONFIRM_RESPONSE
                || payloadType == PayloadType.PAYLOAD_TYPE_PAIRING_FINALIZE_REQUEST
                || payloadType == PayloadType.PAYLOAD_TYPE_PAIRING_FINALIZE_RESPONSE;
    }

    private static void clear(byte[] bytes) {
        if (bytes != null) {
            Arrays.fill(bytes, (byte) 0);
        }
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

    private static List<Capability> grantCapabilities(List<Capability> requestedCapabilities) {
        List<Capability> granted = new ArrayList<>();
        for (Capability supported : SUPPORTED_CAPABILITIES) {
            if (requestedCapabilities.contains(supported)) {
                granted.add(supported);
            }
        }
        return granted;
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
        for (Map.Entry<String, DownloadTransfer> entry : activeDownloadTransfers.entrySet()) {
            if (entry.getKey().startsWith(prefix)
                    && transferId.equals(entry.getValue().transferId)) {
                return true;
            }
        }
        for (Map.Entry<String, UploadTransfer> entry : activeUploadTransfers.entrySet()) {
            if (entry.getKey().startsWith(prefix)
                    && transferId.equals(entry.getValue().transferId)) {
                return true;
            }
        }
        return false;
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

    private UploadTransfer removeSessionUploadTransfer(long sessionId, String transferId) {
        String prefix = sessionId + ":";
        for (Map.Entry<String, UploadTransfer> entry : activeUploadTransfers.entrySet()) {
            if (entry.getKey().startsWith(prefix)
                    && transferId.equals(entry.getValue().transferId)
                    && activeUploadTransfers.remove(entry.getKey(), entry.getValue())) {
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

    private enum SessionPhase {
        AWAITING_HELLO,
        AWAITING_AUTH,
        PAIRING_AWAITING_CONFIRM,
        PAIRING_AWAITING_FINALIZE,
        READY,
        CLOSED
    }

    static final class SessionState {
        private SessionPhase phase = SessionPhase.AWAITING_HELLO;
        private byte[] pairingId;
        private byte[] proofKey;
        private byte[] transcriptHash;
        private boolean pairingRecognized;
        private List<Capability> requestedCapabilities = Arrays.asList();
        private List<Capability> grantedCapabilities = Arrays.asList();
        private byte[] firstPairingId;
        private byte[] firstPairingTranscriptHash;
        private byte[] firstPairingConfirmationKey;
        private byte[] firstPairingKey;
        private byte[] firstPairingDeviceFingerprint;
        private byte[] firstPairingServerConfirmation;
        private String firstPairingClientName;

        private void beginAuthentication(
                byte[] pairingId,
                byte[] proofKey,
                byte[] transcriptHash,
                boolean pairingRecognized,
                List<Capability> requestedCapabilities
        ) {
            this.pairingId = Arrays.copyOf(pairingId, pairingId.length);
            this.proofKey = Arrays.copyOf(proofKey, proofKey.length);
            this.transcriptHash = Arrays.copyOf(transcriptHash, transcriptHash.length);
            this.pairingRecognized = pairingRecognized;
            this.requestedCapabilities = new ArrayList<>(requestedCapabilities);
            this.phase = SessionPhase.AWAITING_AUTH;
        }

        private void markReadyAndClear(List<Capability> grantedCapabilities) {
            clearProvisionalSecrets();
            this.grantedCapabilities = new ArrayList<>(grantedCapabilities);
            phase = SessionPhase.READY;
        }

        private void beginFirstPairing(
                byte[] pairingId,
                byte[] transcriptHash,
                byte[] confirmationKey,
                byte[] pairingKey,
                byte[] deviceFingerprint,
                String clientName
        ) {
            firstPairingId = Arrays.copyOf(pairingId, pairingId.length);
            firstPairingTranscriptHash = Arrays.copyOf(transcriptHash, transcriptHash.length);
            firstPairingConfirmationKey = Arrays.copyOf(confirmationKey, confirmationKey.length);
            firstPairingKey = Arrays.copyOf(pairingKey, pairingKey.length);
            firstPairingDeviceFingerprint = Arrays.copyOf(deviceFingerprint, deviceFingerprint.length);
            firstPairingClientName = clientName;
            phase = SessionPhase.PAIRING_AWAITING_CONFIRM;
        }

        private boolean matchesFirstPairingId(byte[] candidate) {
            return firstPairingId != null && MessageDigest.isEqual(firstPairingId, candidate);
        }

        private void markFirstPairingConfirmed(byte[] serverConfirmation) {
            firstPairingServerConfirmation = Arrays.copyOf(
                    serverConfirmation,
                    serverConfirmation.length
            );
            phase = SessionPhase.PAIRING_AWAITING_FINALIZE;
        }

        private void closeAndClear() {
            clearProvisionalSecrets();
            grantedCapabilities = Arrays.asList();
            phase = SessionPhase.CLOSED;
        }

        private void clearProvisionalSecrets() {
            if (proofKey != null) {
                Arrays.fill(proofKey, (byte) 0);
            }
            if (transcriptHash != null) {
                Arrays.fill(transcriptHash, (byte) 0);
            }
            pairingId = null;
            proofKey = null;
            transcriptHash = null;
            pairingRecognized = false;
            requestedCapabilities = Arrays.asList();
            clear(firstPairingId);
            clear(firstPairingTranscriptHash);
            clear(firstPairingConfirmationKey);
            clear(firstPairingKey);
            clear(firstPairingDeviceFingerprint);
            clear(firstPairingServerConfirmation);
            firstPairingId = null;
            firstPairingTranscriptHash = null;
            firstPairingConfirmationKey = null;
            firstPairingKey = null;
            firstPairingDeviceFingerprint = null;
            firstPairingServerConfirmation = null;
            firstPairingClientName = null;
        }
    }

    private static final class DispatchResult {
        private final List<RpcEnvelope> responses;
        private final boolean closeSession;

        private DispatchResult(List<RpcEnvelope> responses, boolean closeSession) {
            this.responses = responses;
            this.closeSession = closeSession;
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

        private static DispatchResult close(RpcEnvelope response) {
            return new DispatchResult(Arrays.asList(response), true);
        }
    }
}
