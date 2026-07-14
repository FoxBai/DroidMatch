package app.droidmatch.m1;

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

import com.google.protobuf.ByteString;
import com.google.protobuf.InvalidProtocolBufferException;

import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Objects;

/**
 * Owns the visible first-pairing exchange after dispatcher phase admission.
 *
 * <p>The dispatcher remains the only owner of envelope ordering. This handler
 * owns start/confirm/finalize payloads, visible approval, first-pairing rate
 * limits, and final-confirmation-before-persistence. Provisional secrets remain
 * owned and zeroized by {@link RpcSessionState}.</p>
 */
final class RpcPairingHandler {
    private static final long PAIRING_APPROVAL_TIMEOUT_MILLIS = 60_000L;

    private final DiagnosticsReporter diagnosticsReporter;
    private final PairingCredentialRepository pairingCredentialRepository;
    private final PairingApprovalController pairingApprovalController;
    private final DeviceIdentityProvider deviceIdentityProvider;
    private final AuthenticationRateLimiter authenticationRateLimiter;
    private final SecureRandom secureRandom = new SecureRandom();

    RpcPairingHandler(
            DiagnosticsReporter diagnosticsReporter,
            PairingCredentialRepository pairingCredentialRepository,
            PairingApprovalController pairingApprovalController,
            DeviceIdentityProvider deviceIdentityProvider,
            AuthenticationRateLimiter authenticationRateLimiter
    ) {
        this.diagnosticsReporter = diagnosticsReporter;
        this.pairingCredentialRepository = pairingCredentialRepository;
        this.pairingApprovalController = pairingApprovalController;
        this.deviceIdentityProvider = deviceIdentityProvider;
        this.authenticationRateLimiter = Objects.requireNonNull(
                authenticationRateLimiter,
                "authenticationRateLimiter"
        );
    }

    RpcDispatcher.DispatchResult start(RpcEnvelope request, RpcSessionState sessionState) {
        if (!pairingRuntimeAvailable()
                || !pairingApprovalController.snapshot().windowOpen()) {
            diagnosticsReporter.recordState("rpc.pairing.window_closed");
            return closeStartError(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "a visible Android pairing window is required",
                    "Open DroidMatch on Android and tap Open pairing window"
            );
        }
        if (!authenticationRateLimiter.firstPairingAllowed()) {
            diagnosticsReporter.recordCounter("rpc.pairing.rate_limited", 1);
            return closeStartError(
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
            return closeStartError(
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
            return closeStartError(
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
            return closeStartError(
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
                    return closeStartError(
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
            finishAttempt(sessionState, pairingId);
            sessionState.closeAndClear();
            return RpcDispatcher.DispatchResult.close(RpcDispatcher.errorEnvelope(
                    request.getRequestId(),
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                    "pairing start fields are invalid"
            ));
        } catch (RuntimeException exception) {
            diagnosticsReporter.recordError("rpc.pairing.start.failed", exception);
            finishAttempt(sessionState, pairingId);
            sessionState.closeAndClear();
            return closeStartError(
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

    RpcDispatcher.DispatchResult confirm(RpcEnvelope request, RpcSessionState sessionState) {
        PairingConfirmRequest confirm;
        try {
            confirm = PairingConfirmRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.pairing.confirm.invalid", exception);
            authenticationRateLimiter.recordFirstPairingFailure();
            return closeConfirmError(
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
            return closeConfirmError(
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
            return closeConfirmError(
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
            return closeConfirmError(
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

    RpcDispatcher.DispatchResult finalizePairing(
            RpcEnvelope request,
            RpcSessionState sessionState
    ) {
        PairingFinalizeRequest finalize;
        try {
            finalize = PairingFinalizeRequest.parseFrom(request.getPayload().toByteArray());
        } catch (InvalidProtocolBufferException exception) {
            diagnosticsReporter.recordError("rpc.pairing.finalize.invalid", exception);
            authenticationRateLimiter.recordFirstPairingFailure();
            return closeFinalizeError(
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
            return closeFinalizeError(
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
            return closeFinalizeError(
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
        finishAttempt(sessionState);
        sessionState.closeAndClear();
        return RpcDispatcher.DispatchResult.close(RpcDispatcher.responseEnvelope(
                request.getRequestId(),
                PayloadType.PAYLOAD_TYPE_PAIRING_FINALIZE_RESPONSE,
                response.toByteString()
        ));
    }

    private RpcDispatcher.DispatchResult closeStartError(
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

    private RpcDispatcher.DispatchResult closeConfirmError(
            long requestId,
            RpcSessionState sessionState,
            ErrorCode code,
            String message
    ) {
        PairingConfirmResponse response = PairingConfirmResponse.newBuilder()
                .setError(RpcDispatcher.error(code, message))
                .build();
        finishAttempt(sessionState);
        sessionState.closeAndClear();
        return RpcDispatcher.DispatchResult.close(RpcDispatcher.responseEnvelope(
                requestId,
                PayloadType.PAYLOAD_TYPE_PAIRING_CONFIRM_RESPONSE,
                response.toByteString()
        ));
    }

    private RpcDispatcher.DispatchResult closeFinalizeError(
            long requestId,
            RpcSessionState sessionState,
            ErrorCode code,
            String message
    ) {
        PairingFinalizeResponse response = PairingFinalizeResponse.newBuilder()
                .setError(RpcDispatcher.error(code, message))
                .build();
        finishAttempt(sessionState);
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

    void finishAttempt(RpcSessionState sessionState) {
        finishAttempt(sessionState, sessionState.firstPairingId);
    }

    private void finishAttempt(RpcSessionState sessionState, byte[] pairingId) {
        if (pairingApprovalController != null && pairingId != null
                && pairingId.length == PairingAuthenticator.PAIRING_ID_LENGTH) {
            pairingApprovalController.finishAttempt(pairingId);
        }
    }

    private static void clear(byte[] bytes) {
        if (bytes != null) {
            Arrays.fill(bytes, (byte) 0);
        }
    }
}
