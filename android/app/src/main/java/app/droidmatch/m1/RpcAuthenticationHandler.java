package app.droidmatch.m1;

import app.droidmatch.proto.v1.AuthenticateSessionRequest;
import app.droidmatch.proto.v1.AuthenticateSessionResponse;
import app.droidmatch.proto.v1.AuthenticationState;
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

import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.List;
import java.util.Objects;

import static app.droidmatch.m1.RpcAuthenticationPolicy.*;

/**
 * Owns nonce correlation and paired reconnect authentication.
 *
 * <p>The session dispatcher remains responsible for envelope ordering. This
 * handler owns reconnect proof verification, generic failure shapes, capability
 * grants, and the corresponding transitions on {@link RpcSessionState}. Visible
 * first pairing is isolated in {@link RpcPairingHandler}; both paths share one
 * process-local rate limiter.</p>
 */
final class RpcAuthenticationHandler {
    private final DiagnosticsReporter diagnosticsReporter;
    private final SessionAuthenticationMode authenticationMode;
    private final PairingKeyProvider pairingKeyProvider;
    private final PairingCredentialRepository pairingCredentialRepository;
    private final DeviceIdentityProvider deviceIdentityProvider;
    private final AuthenticationRateLimiter authenticationRateLimiter;
    private final SecureRandom secureRandom = new SecureRandom();

    RpcAuthenticationHandler(
            DiagnosticsReporter diagnosticsReporter,
            SessionAuthenticationMode authenticationMode,
            PairingKeyProvider pairingKeyProvider,
            DeviceIdentityProvider deviceIdentityProvider,
            AuthenticationRateLimiter authenticationRateLimiter
    ) {
        this(
                diagnosticsReporter,
                authenticationMode,
                pairingKeyProvider,
                null,
                deviceIdentityProvider,
                authenticationRateLimiter
        );
    }

    RpcAuthenticationHandler(
            DiagnosticsReporter diagnosticsReporter,
            SessionAuthenticationMode authenticationMode,
            PairingKeyProvider pairingKeyProvider,
            PairingCredentialRepository pairingCredentialRepository,
            DeviceIdentityProvider deviceIdentityProvider,
            AuthenticationRateLimiter authenticationRateLimiter
    ) {
        this.diagnosticsReporter = diagnosticsReporter;
        this.authenticationMode = Objects.requireNonNull(authenticationMode, "authenticationMode");
        this.pairingKeyProvider = Objects.requireNonNull(pairingKeyProvider, "pairingKeyProvider");
        this.pairingCredentialRepository = pairingCredentialRepository;
        this.deviceIdentityProvider = authenticationMode == SessionAuthenticationMode.PAIRED_REQUIRED
                ? Objects.requireNonNull(deviceIdentityProvider, "deviceIdentityProvider")
                : deviceIdentityProvider;
        this.authenticationRateLimiter = Objects.requireNonNull(
                authenticationRateLimiter,
                "authenticationRateLimiter"
        );
    }

    void markReadyForTest(RpcSessionState sessionState) {
        sessionState.markReadyAndClear(allCapabilities());
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
        if (!isSessionNonceLengthAllowed(sessionNonceLength)) {
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

        byte[] deviceIdentityFingerprint = deviceIdentityProvider.fingerprint();
        if (deviceIdentityFingerprint.length != PairingAuthenticator.DIGEST_LENGTH) {
            throw new IllegalStateException("DeviceIdentityProvider returned an invalid fingerprint length");
        }
        serverHello.setDeviceIdentityFingerprint(ByteString.copyFrom(deviceIdentityFingerprint));

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
        if (pairingCredentialRepository != null) {
            try {
                pairingCredentialRepository.markUsed(
                        Arrays.copyOf(sessionState.pairingId, sessionState.pairingId.length),
                        Math.max(0L, System.currentTimeMillis())
                );
            } catch (RuntimeException exception) {
                // Recency is UI metadata, not authentication authority. Keep a
                // valid session usable while recording only a bounded label.
                diagnosticsReporter.recordState("rpc.authentication.last_used_update_failed");
            }
        }
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
    private static void clear(byte[] bytes) {
        if (bytes != null) {
            Arrays.fill(bytes, (byte) 0);
        }
    }
}
