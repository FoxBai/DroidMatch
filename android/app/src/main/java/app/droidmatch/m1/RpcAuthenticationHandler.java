package app.droidmatch.m1;

import app.droidmatch.proto.v1.AuthenticateSessionRequest;
import app.droidmatch.proto.v1.AuthenticateSessionResponse;
import app.droidmatch.proto.v1.AuthenticationState;
import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.ClientHello;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.PairingConfirmRequest;
import app.droidmatch.proto.v1.PairingConfirmResponse;
import app.droidmatch.proto.v1.PairingFinalizeRequest;
import app.droidmatch.proto.v1.PairingFinalizeResponse;
import app.droidmatch.proto.v1.PairingStartRequest;
import app.droidmatch.proto.v1.PairingStartResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.ServerHello;
import app.droidmatch.proto.v1.TransportKind;

import com.google.protobuf.ByteString;
import com.google.protobuf.InvalidProtocolBufferException;

import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Objects;

/**
 * Owns reconnect authentication and visible first-pairing exchanges.
 *
 * <p>The session dispatcher remains responsible for envelope ordering. This
 * handler owns proof verification, generic failure shapes, rate limiting,
 * pairing approval, credential persistence, and all authentication transitions
 * on {@link RpcSessionState}.</p>
 */
final class RpcAuthenticationHandler {
    private static final int PROTOCOL_MAJOR = 1;
    private static final int PROTOCOL_MINOR = 0;
    private static final int MIN_SESSION_NONCE_BYTES = 16;
    private static final int MAX_SESSION_NONCE_BYTES = 32;
    private static final long PAIRING_APPROVAL_TIMEOUT_MILLIS = 60_000L;
    private static final List<Capability> SUPPORTED_CAPABILITIES = Arrays.asList(
            Capability.CAPABILITY_FILE_LIST,
            Capability.CAPABILITY_FILE_READ,
            Capability.CAPABILITY_FILE_WRITE,
            Capability.CAPABILITY_RESUMABLE_TRANSFER,
            Capability.CAPABILITY_DIAGNOSTICS
    );

    private final DiagnosticsReporter diagnosticsReporter;
    private final SessionAuthenticationMode authenticationMode;
    private final PairingKeyProvider pairingKeyProvider;
    private final PairingCredentialRepository pairingCredentialRepository;
    private final PairingApprovalController pairingApprovalController;
    private final DeviceIdentityProvider deviceIdentityProvider;
    private final AuthenticationRateLimiter authenticationRateLimiter;
    private final SecureRandom secureRandom = new SecureRandom();

    RpcAuthenticationHandler(
            DiagnosticsReporter diagnosticsReporter,
            SessionAuthenticationMode authenticationMode,
            PairingKeyProvider pairingKeyProvider,
            PairingCredentialRepository pairingCredentialRepository,
            PairingApprovalController pairingApprovalController,
            DeviceIdentityProvider deviceIdentityProvider,
            AuthenticationRateLimiter authenticationRateLimiter
    ) {
        this.diagnosticsReporter = diagnosticsReporter;
        this.authenticationMode = Objects.requireNonNull(authenticationMode, "authenticationMode");
        this.pairingKeyProvider = Objects.requireNonNull(pairingKeyProvider, "pairingKeyProvider");
        this.pairingCredentialRepository = pairingCredentialRepository;
        this.pairingApprovalController = pairingApprovalController;
        this.deviceIdentityProvider = deviceIdentityProvider;
        this.authenticationRateLimiter = Objects.requireNonNull(
                authenticationRateLimiter,
                "authenticationRateLimiter"
        );
    }

    void markReadyForTest(RpcSessionState sessionState) {
        sessionState.markReadyAndClear(SUPPORTED_CAPABILITIES);
    }

    RpcDispatcher.DispatchResult clientHello(RpcEnvelope request, RpcSessionState sessionState) {
        ClientHello hello;
        try {
            hello = ClientHello.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.client_hello.invalid", exception);
            return RpcDispatcher.DispatchResult.response(RpcDispatcher.errorEnvelope(
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
            return RpcDispatcher.DispatchResult.response(RpcDispatcher.errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "session_nonce must be 16 to 32 bytes"
            ));
        }

        if (authenticationMode == SessionAuthenticationMode.PAIRED_REQUIRED
                && sessionNonceLength != SessionAuthenticator.NONCE_LENGTH) {
            diagnosticsReporter.recordState("rpc.client_hello.paired_nonce_length:" + sessionNonceLength);
            sessionState.closeAndClear();
            return RpcDispatcher.DispatchResult.close(RpcDispatcher.errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "paired sessions require a 32-byte session_nonce"
            ));
        }

        if (hello.getProtocolMajor() != PROTOCOL_MAJOR) {
            diagnosticsReporter.recordState("rpc.client_hello.unsupported_protocol:" + hello.getProtocolMajor());
            return RpcDispatcher.DispatchResult.response(RpcDispatcher.errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_UNSUPPORTED_VERSION,
                    "unsupported protocol_major: " + hello.getProtocolMajor()
            ));
        }

        if (hello.getTransport() != TransportKind.TRANSPORT_KIND_ADB) {
            diagnosticsReporter.recordState("rpc.client_hello.unsupported_transport:" + hello.getTransport());
            return RpcDispatcher.DispatchResult.response(RpcDispatcher.errorEnvelope(
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
            return RpcDispatcher.DispatchResult.response(serverHelloEnvelope(request.getRequestId(), serverHello));
        }

        int pairingIdLength = hello.getPairingId().size();
        if (pairingIdLength == 0) {
            serverHello.setAuthenticationState(AuthenticationState.AUTHENTICATION_STATE_PAIRING_REQUIRED);
            sessionState.phase = RpcSessionState.Phase.CLOSED;
            diagnosticsReporter.recordState("rpc.authentication.pairing_required");
            return RpcDispatcher.DispatchResult.close(serverHelloEnvelope(request.getRequestId(), serverHello));
        }
        if (pairingIdLength != SessionAuthenticator.PAIRING_ID_LENGTH) {
            diagnosticsReporter.recordState("rpc.authentication.invalid_pairing_id_length:" + pairingIdLength);
            sessionState.phase = RpcSessionState.Phase.CLOSED;
            return RpcDispatcher.DispatchResult.close(RpcDispatcher.errorEnvelope(
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
        return RpcDispatcher.DispatchResult.response(serverHelloEnvelope(request.getRequestId(), serverHello));
    }

    private RpcEnvelope serverHelloEnvelope(long requestId, ServerHello.Builder serverHello) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(RpcDispatcher.FRAME_VERSION)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_RESPONSE)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_SERVER_HELLO)
                .setPayload(serverHello.build().toByteString())
                .build();
    }

    RpcDispatcher.DispatchResult authenticateSession(RpcEnvelope request, RpcSessionState sessionState) {
        AuthenticateSessionRequest authenticate;
        try {
            authenticate = AuthenticateSessionRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.authentication.invalid", exception);
            if (sessionState.pairingId != null) {
                authenticationRateLimiter.recordReconnectFailure(sessionState.pairingId);
            }
            sessionState.closeAndClear();
            return RpcDispatcher.DispatchResult.close(RpcDispatcher.errorEnvelope(
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
            return RpcDispatcher.DispatchResult.close(RpcDispatcher.responseEnvelope(
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
        return RpcDispatcher.DispatchResult.response(RpcDispatcher.responseEnvelope(
                request.getRequestId(),
                PayloadType.PAYLOAD_TYPE_AUTHENTICATE_SESSION_RESPONSE,
                response.build().toByteString()
        ));
    }

    RpcDispatcher.DispatchResult pairingStart(RpcEnvelope request, RpcSessionState sessionState) {
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
            return RpcDispatcher.DispatchResult.close(RpcDispatcher.errorEnvelope(
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
            return RpcDispatcher.DispatchResult.response(RpcDispatcher.responseEnvelope(
                    request.getRequestId(),
                    PayloadType.PAYLOAD_TYPE_PAIRING_START_RESPONSE,
                    response.toByteString()
            ));
        } catch (IllegalArgumentException exception) {
            diagnosticsReporter.recordState("rpc.pairing.start.rejected_input");
            authenticationRateLimiter.recordFirstPairingFailure();
            finishPairingAttempt(sessionState, pairingId);
            sessionState.closeAndClear();
            return RpcDispatcher.DispatchResult.close(RpcDispatcher.errorEnvelope(
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

    RpcDispatcher.DispatchResult pairingConfirm(RpcEnvelope request, RpcSessionState sessionState) {
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
        return RpcDispatcher.DispatchResult.response(RpcDispatcher.responseEnvelope(
                request.getRequestId(),
                PayloadType.PAYLOAD_TYPE_PAIRING_CONFIRM_RESPONSE,
                response.toByteString()
        ));
    }

    RpcDispatcher.DispatchResult pairingFinalize(RpcEnvelope request, RpcSessionState sessionState) {
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
        return RpcDispatcher.DispatchResult.close(RpcDispatcher.responseEnvelope(
                request.getRequestId(),
                PayloadType.PAYLOAD_TYPE_PAIRING_FINALIZE_RESPONSE,
                response.toByteString()
        ));
    }


    private RpcDispatcher.DispatchResult closePairingStartError(
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
        return RpcDispatcher.DispatchResult.close(RpcDispatcher.responseEnvelope(
                requestId,
                PayloadType.PAYLOAD_TYPE_PAIRING_START_RESPONSE,
                response.toByteString()
        ));
    }

    private RpcDispatcher.DispatchResult closePairingConfirmError(
            long requestId,
            RpcSessionState sessionState,
            ErrorCode code,
            String message
    ) {
        PairingConfirmResponse response = PairingConfirmResponse.newBuilder()
                .setError(RpcDispatcher.error(code, message))
                .build();
        finishPairingAttempt(sessionState);
        sessionState.closeAndClear();
        return RpcDispatcher.DispatchResult.close(RpcDispatcher.responseEnvelope(
                requestId,
                PayloadType.PAYLOAD_TYPE_PAIRING_CONFIRM_RESPONSE,
                response.toByteString()
        ));
    }

    private RpcDispatcher.DispatchResult closePairingFinalizeError(
            long requestId,
            RpcSessionState sessionState,
            ErrorCode code,
            String message
    ) {
        PairingFinalizeResponse response = PairingFinalizeResponse.newBuilder()
                .setError(RpcDispatcher.error(code, message))
                .build();
        finishPairingAttempt(sessionState);
        sessionState.closeAndClear();
        return RpcDispatcher.DispatchResult.close(RpcDispatcher.responseEnvelope(
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

    void finishPairingAttempt(RpcSessionState sessionState) {
        finishPairingAttempt(sessionState, sessionState.firstPairingId);
    }

    private void finishPairingAttempt(RpcSessionState sessionState, byte[] pairingId) {
        if (pairingApprovalController != null && pairingId != null
                && pairingId.length == PairingAuthenticator.PAIRING_ID_LENGTH) {
            pairingApprovalController.finishAttempt(pairingId);
        }
    }

    static boolean isPairingPayload(PayloadType payloadType) {
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


    private static List<Capability> grantCapabilities(List<Capability> requestedCapabilities) {
        List<Capability> granted = new ArrayList<>();
        for (Capability supported : SUPPORTED_CAPABILITIES) {
            if (requestedCapabilities.contains(supported)) {
                granted.add(supported);
            }
        }
        return granted;
    }

}
