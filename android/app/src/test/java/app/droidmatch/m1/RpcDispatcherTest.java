package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.AuthenticateSessionRequest;
import app.droidmatch.proto.v1.AuthenticateSessionResponse;
import app.droidmatch.proto.v1.AuthenticationState;
import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.CancelTransferRequest;
import app.droidmatch.proto.v1.CancelTransferResponse;
import app.droidmatch.proto.v1.ClientHello;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.HeartbeatRequest;
import app.droidmatch.proto.v1.HeartbeatResponse;
import app.droidmatch.proto.v1.ListDirRequest;
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

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Collections;
import java.util.zip.CRC32;

import org.junit.Test;

import static app.droidmatch.m1.RpcDispatcherTestFixtures.*;

public final class RpcDispatcherTest {
    @Test
    public void heartbeatRoundTripsMonotonicMillisAfterHandshake() throws Exception {
        DiagnosticsReporter reporter = new DiagnosticsReporter(() -> 1L, () -> "test-thread");
        RpcDispatcher dispatcher = new RpcDispatcher(
                reporter,
                null,
                null,
                null
        );
        HeartbeatRequest heartbeat = HeartbeatRequest.newBuilder()
                .setMonotonicMillis(123456789L)
                .build();
        RpcEnvelope request = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(7)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_HEARTBEAT_REQUEST)
                .setPayload(heartbeat.toByteString())
                .build();

        RpcEnvelope[] responses = dispatcher.dispatchForTest(request.toByteArray(), true, 1);

        assertEquals(1, responses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_RESPONSE, responses[0].getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_HEARTBEAT_RESPONSE, responses[0].getPayloadType());
        assertEquals(7, responses[0].getRequestId());
        HeartbeatResponse response = HeartbeatResponse.parseFrom(responses[0].getPayload());
        assertEquals(123456789L, response.getMonotonicMillis());
        assertEquals(1L, reporter.counters().get("rpc.heartbeat.requests").longValue());
    }

    @Test
    public void clientHelloEchoesValidSessionNonce() throws Exception {
        DiagnosticsReporter reporter = new DiagnosticsReporter(() -> 1L, () -> "test-thread");
        RpcDispatcher dispatcher = new RpcDispatcher(reporter, null, null, null);
        ByteString nonce = ByteString.copyFrom(new byte[32]);
        ClientHello hello = ClientHello.newBuilder()
                .setClientName("DroidMatchTests")
                .setClientVersion("test")
                .setProtocolMajor(1)
                .setProtocolMinor(0)
                .setTransport(TransportKind.TRANSPORT_KIND_ADB)
                .addRequestedCapabilities(Capability.CAPABILITY_DIAGNOSTICS)
                .setSessionNonce(nonce)
                .build();
        RpcEnvelope request = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(1)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_CLIENT_HELLO)
                .setPayload(hello.toByteString())
                .build();

        RpcEnvelope[] responses = dispatcher.dispatchForTest(request.toByteArray(), false, 1);

        assertEquals(1, responses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_RESPONSE, responses[0].getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_SERVER_HELLO, responses[0].getPayloadType());
        ServerHello response = ServerHello.parseFrom(responses[0].getPayload());
        assertEquals(nonce, response.getSessionNonce());
        assertEquals(AuthenticationState.AUTHENTICATION_STATE_CORRELATED, response.getAuthenticationState());
        assertEquals(1L, reporter.counters().get("rpc.handshakes.accepted").longValue());
    }

    @Test
    public void pairedSessionRequiresAndVerifiesMutualProofs() throws Exception {
        byte[] pairingId = sequentialBytes(0xa0, SessionAuthenticator.PAIRING_ID_LENGTH);
        byte[] pairingKey = sequentialBytes(0x00, SessionAuthenticator.PAIRING_KEY_LENGTH);
        byte[] clientNonce = sequentialBytes(0x10, SessionAuthenticator.NONCE_LENGTH);
        RpcDispatcher dispatcher = pairedDispatcher(pairingId, pairingKey);
        RpcDispatcher.SessionState orderingState = dispatcher.newSessionStateForTest();

        dispatcher.dispatchForTest(
                clientHelloEnvelope(1, clientNonce, pairingId).toByteArray(),
                orderingState,
                99
        );
        RpcEnvelope[] prematureHeartbeat = dispatcher.dispatchForTest(
                heartbeatEnvelope(2).toByteArray(),
                orderingState,
                99
        );
        assertEquals(ErrorCode.ERROR_CODE_UNAUTHORIZED, prematureHeartbeat[0].getError().getCode());
        RpcEnvelope[] requestAfterProtocolFailure = dispatcher.dispatchForTest(
                authenticationEnvelope(3, pairingId, new byte[SessionAuthenticator.DIGEST_LENGTH]).toByteArray(),
                orderingState,
                99
        );
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_ERROR, requestAfterProtocolFailure[0].getKind());

        RpcDispatcher.SessionState state = dispatcher.newSessionStateForTest();

        RpcEnvelope[] helloResponses = dispatcher.dispatchForTest(
                clientHelloEnvelope(4, clientNonce, pairingId).toByteArray(),
                state,
                1
        );
        ServerHello serverHello = ServerHello.parseFrom(helloResponses[0].getPayload());
        assertEquals(AuthenticationState.AUTHENTICATION_STATE_REQUIRED, serverHello.getAuthenticationState());
        assertEquals(SessionAuthenticator.NONCE_LENGTH, serverHello.getServerNonce().size());
        assertEquals(0, serverHello.getGrantedCapabilitiesCount());

        byte[] transcriptHash = SessionAuthenticator.transcriptHash(SessionAuthenticator.transcript(
                pairingId,
                clientNonce,
                serverHello.getServerNonce().toByteArray(),
                serverHello.getProtocolMajor(),
                serverHello.getProtocolMinor(),
                serverHello.getTransport().getNumber()
        ));
        RpcEnvelope authentication = authenticationEnvelope(
                5,
                pairingId,
                SessionAuthenticator.clientProof(pairingKey, transcriptHash)
        );
        RpcEnvelope[] authenticationResponses = dispatcher.dispatchForTest(
                authentication.toByteArray(),
                state,
                1
        );

        AuthenticateSessionResponse authenticated = AuthenticateSessionResponse.parseFrom(
                authenticationResponses[0].getPayload()
        );
        assertTrue(authenticated.getAuthenticated());
        assertTrue(SessionAuthenticator.verifyServerProof(
                authenticated.getServerProof().toByteArray(),
                pairingKey,
                transcriptHash
        ));
        assertEquals(1, authenticated.getGrantedCapabilitiesCount());
        assertEquals(Capability.CAPABILITY_DIAGNOSTICS, authenticated.getGrantedCapabilities(0));

        RpcEnvelope[] heartbeatResponses = dispatcher.dispatchForTest(
                heartbeatEnvelope(6).toByteArray(),
                state,
                1
        );
        assertEquals(PayloadType.PAYLOAD_TYPE_HEARTBEAT_RESPONSE, heartbeatResponses[0].getPayloadType());
    }

    @Test
    public void pairedSessionRejectsBadProofAndReplayAgainstFreshChallenge() throws Exception {
        byte[] pairingId = sequentialBytes(0xa0, SessionAuthenticator.PAIRING_ID_LENGTH);
        byte[] pairingKey = sequentialBytes(0x00, SessionAuthenticator.PAIRING_KEY_LENGTH);
        byte[] clientNonce = sequentialBytes(0x10, SessionAuthenticator.NONCE_LENGTH);
        RpcDispatcher dispatcher = pairedDispatcher(pairingId, pairingKey);

        RpcDispatcher.SessionState firstState = dispatcher.newSessionStateForTest();
        ServerHello firstHello = ServerHello.parseFrom(dispatcher.dispatchForTest(
                clientHelloEnvelope(1, clientNonce, pairingId).toByteArray(),
                firstState,
                1
        )[0].getPayload());
        byte[] firstHash = SessionAuthenticator.transcriptHash(SessionAuthenticator.transcript(
                pairingId,
                clientNonce,
                firstHello.getServerNonce().toByteArray(),
                1,
                0,
                TransportKind.TRANSPORT_KIND_ADB.getNumber()
        ));
        byte[] firstProof = SessionAuthenticator.clientProof(pairingKey, firstHash);
        firstProof[0] ^= 0x01;
        AuthenticateSessionResponse badProofResponse = AuthenticateSessionResponse.parseFrom(
                dispatcher.dispatchForTest(
                        authenticationEnvelope(2, pairingId, firstProof).toByteArray(),
                        firstState,
                        1
                )[0].getPayload()
        );
        assertFalse(badProofResponse.getAuthenticated());
        assertEquals(ErrorCode.ERROR_CODE_UNAUTHORIZED, badProofResponse.getError().getCode());

        RpcDispatcher.SessionState secondState = dispatcher.newSessionStateForTest();
        ServerHello secondHello = ServerHello.parseFrom(dispatcher.dispatchForTest(
                clientHelloEnvelope(3, clientNonce, pairingId).toByteArray(),
                secondState,
                2
        )[0].getPayload());
        assertFalse(firstHello.getServerNonce().equals(secondHello.getServerNonce()));
        byte[] replayedProof = SessionAuthenticator.clientProof(pairingKey, firstHash);
        AuthenticateSessionResponse replayResponse = AuthenticateSessionResponse.parseFrom(
                dispatcher.dispatchForTest(
                        authenticationEnvelope(4, pairingId, replayedProof).toByteArray(),
                        secondState,
                        2
                )[0].getPayload()
        );
        assertFalse(replayResponse.getAuthenticated());
        assertEquals(ErrorCode.ERROR_CODE_UNAUTHORIZED, replayResponse.getError().getCode());
    }

    @Test
    public void pairedSessionRateLimitRejectsCorrectProofUntilBackoffExpires() throws Exception {
        byte[] pairingId = sequentialBytes(0xa0, SessionAuthenticator.PAIRING_ID_LENGTH);
        byte[] pairingKey = sequentialBytes(0x00, SessionAuthenticator.PAIRING_KEY_LENGTH);
        byte[] clientNonce = sequentialBytes(0x10, SessionAuthenticator.NONCE_LENGTH);
        FakeAuthenticationClock clock = new FakeAuthenticationClock();
        AuthenticationRateLimiter limiter = new AuthenticationRateLimiter(clock);
        RpcDispatcher dispatcher = pairedDispatcher(pairingId, pairingKey, limiter);

        for (int attempt = 0;
             attempt < AuthenticationRateLimiter.RECONNECT_IDENTIFIER_FAILURES_BEFORE_BACKOFF;
             attempt += 1) {
            RpcDispatcher.SessionState state = dispatcher.newSessionStateForTest();
            dispatcher.dispatchForTest(
                    clientHelloEnvelope(attempt * 2L + 1, clientNonce, pairingId).toByteArray(),
                    state,
                    attempt + 1
            );
            AuthenticateSessionResponse rejected = AuthenticateSessionResponse.parseFrom(
                    dispatcher.dispatchForTest(
                            authenticationEnvelope(
                                    attempt * 2L + 2,
                                    pairingId,
                                    new byte[SessionAuthenticator.DIGEST_LENGTH]
                            ).toByteArray(),
                            state,
                            attempt + 1
                    )[0].getPayload()
            );
            assertFalse(rejected.getAuthenticated());
            assertEquals(ErrorCode.ERROR_CODE_UNAUTHORIZED, rejected.getError().getCode());
        }

        RpcDispatcher.SessionState blockedState = dispatcher.newSessionStateForTest();
        ServerHello blockedHello = ServerHello.parseFrom(dispatcher.dispatchForTest(
                clientHelloEnvelope(20, clientNonce, pairingId).toByteArray(),
                blockedState,
                20
        )[0].getPayload());
        byte[] blockedHash = SessionAuthenticator.transcriptHash(SessionAuthenticator.transcript(
                pairingId,
                clientNonce,
                blockedHello.getServerNonce().toByteArray(),
                1,
                0,
                TransportKind.TRANSPORT_KIND_ADB.getNumber()
        ));
        AuthenticateSessionResponse blocked = AuthenticateSessionResponse.parseFrom(
                dispatcher.dispatchForTest(
                        authenticationEnvelope(
                                21,
                                pairingId,
                                SessionAuthenticator.clientProof(pairingKey, blockedHash)
                        ).toByteArray(),
                        blockedState,
                        20
                )[0].getPayload()
        );
        assertFalse(blocked.getAuthenticated());
        assertEquals("session authentication failed", blocked.getError().getMessage());

        clock.advance(AuthenticationRateLimiter.BASE_BACKOFF_MILLIS);
        RpcDispatcher.SessionState recoveredState = dispatcher.newSessionStateForTest();
        ServerHello recoveredHello = ServerHello.parseFrom(dispatcher.dispatchForTest(
                clientHelloEnvelope(22, clientNonce, pairingId).toByteArray(),
                recoveredState,
                22
        )[0].getPayload());
        byte[] recoveredHash = SessionAuthenticator.transcriptHash(SessionAuthenticator.transcript(
                pairingId,
                clientNonce,
                recoveredHello.getServerNonce().toByteArray(),
                1,
                0,
                TransportKind.TRANSPORT_KIND_ADB.getNumber()
        ));
        AuthenticateSessionResponse recovered = AuthenticateSessionResponse.parseFrom(
                dispatcher.dispatchForTest(
                        authenticationEnvelope(
                                23,
                                pairingId,
                                SessionAuthenticator.clientProof(pairingKey, recoveredHash)
                        ).toByteArray(),
                        recoveredState,
                        22
                )[0].getPayload()
        );
        assertTrue(recovered.getAuthenticated());
    }

    @Test
    public void pairedSessionDoesNotRevealUnknownPairingDuringChallenge() throws Exception {
        byte[] knownPairingId = sequentialBytes(0xa0, SessionAuthenticator.PAIRING_ID_LENGTH);
        byte[] unknownPairingId = sequentialBytes(0xb0, SessionAuthenticator.PAIRING_ID_LENGTH);
        byte[] pairingKey = sequentialBytes(0x00, SessionAuthenticator.PAIRING_KEY_LENGTH);
        byte[] clientNonce = sequentialBytes(0x10, SessionAuthenticator.NONCE_LENGTH);
        RpcDispatcher dispatcher = pairedDispatcher(knownPairingId, pairingKey);
        RpcDispatcher.SessionState state = dispatcher.newSessionStateForTest();

        ServerHello challenge = ServerHello.parseFrom(dispatcher.dispatchForTest(
                clientHelloEnvelope(1, clientNonce, unknownPairingId).toByteArray(),
                state,
                1
        )[0].getPayload());
        assertEquals(AuthenticationState.AUTHENTICATION_STATE_REQUIRED, challenge.getAuthenticationState());
        assertEquals(SessionAuthenticator.NONCE_LENGTH, challenge.getServerNonce().size());

        AuthenticateSessionResponse response = AuthenticateSessionResponse.parseFrom(
                dispatcher.dispatchForTest(
                        authenticationEnvelope(
                                2,
                                unknownPairingId,
                                new byte[SessionAuthenticator.DIGEST_LENGTH]
                        ).toByteArray(),
                        state,
                        1
                )[0].getPayload()
        );
        assertFalse(response.getAuthenticated());
        assertEquals("session authentication failed", response.getError().getMessage());
    }

    @Test
    public void pairedSessionWithoutIdentifierRequiresFirstPairing() throws Exception {
        byte[] pairingId = sequentialBytes(0xa0, SessionAuthenticator.PAIRING_ID_LENGTH);
        byte[] pairingKey = sequentialBytes(0x00, SessionAuthenticator.PAIRING_KEY_LENGTH);
        byte[] clientNonce = sequentialBytes(0x10, SessionAuthenticator.NONCE_LENGTH);
        RpcDispatcher dispatcher = pairedDispatcher(pairingId, pairingKey);
        RpcDispatcher.SessionState state = dispatcher.newSessionStateForTest();

        ServerHello response = ServerHello.parseFrom(dispatcher.dispatchForTest(
                clientHelloEnvelope(1, clientNonce, new byte[0]).toByteArray(),
                state,
                1
        )[0].getPayload());
        assertEquals(AuthenticationState.AUTHENTICATION_STATE_PAIRING_REQUIRED, response.getAuthenticationState());
        assertEquals(0, response.getGrantedCapabilitiesCount());
        assertEquals(0, response.getServerNonce().size());
        assertEquals(PairingAuthenticator.DIGEST_LENGTH, response.getDeviceIdentityFingerprint().size());
    }

    @Test
    public void readySessionEnforcesNegotiatedCapabilityIntersection() throws Exception {
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                null,
                null
        );
        byte[] nonce = sequentialBytes(0x10, SessionAuthenticator.NONCE_LENGTH);
        RpcDispatcher.SessionState diagnosticsOnly = dispatcher.newSessionStateForTest();
        ServerHello diagnosticsHello = ServerHello.parseFrom(dispatcher.dispatchForTest(
                clientHelloEnvelope(
                        1,
                        nonce,
                        new byte[0],
                        Capability.CAPABILITY_DIAGNOSTICS
                ).toByteArray(),
                diagnosticsOnly,
                1
        )[0].getPayload());
        assertEquals(1, diagnosticsHello.getGrantedCapabilitiesCount());
        assertEquals(Capability.CAPABILITY_DIAGNOSTICS, diagnosticsHello.getGrantedCapabilities(0));

        RpcEnvelope listRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(2)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_LIST_DIR_REQUEST)
                .setPayload(ListDirRequest.newBuilder().setPath("dm://roots/").build().toByteString())
                .build();
        RpcEnvelope deniedList = dispatcher.dispatchForTest(
                listRequest.toByteArray(),
                diagnosticsOnly,
                1
        )[0];
        assertEquals(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, deniedList.getError().getCode());

        RpcDispatcher.SessionState filteredState = dispatcher.newSessionStateForTest();
        ServerHello filteredHello = ServerHello.parseFrom(dispatcher.dispatchForTest(
                clientHelloEnvelope(
                        3,
                        nonce,
                        new byte[0],
                        Capability.CAPABILITY_FILE_LIST,
                        Capability.CAPABILITY_FILE_DELETE
                ).toByteArray(),
                filteredState,
                2
        )[0].getPayload());
        assertEquals(1, filteredHello.getGrantedCapabilitiesCount());
        assertEquals(Capability.CAPABILITY_FILE_LIST, filteredHello.getGrantedCapabilities(0));
    }

    @Test
    public void clientHelloRejectsInvalidSessionNonceLengths() throws Exception {
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                null,
                null
        );

        for (int nonceLength : new int[] {0, 15, 33}) {
            ClientHello hello = ClientHello.newBuilder()
                    .setClientName("DroidMatchTests")
                    .setClientVersion("test")
                    .setProtocolMajor(1)
                    .setTransport(TransportKind.TRANSPORT_KIND_ADB)
                    .setSessionNonce(ByteString.copyFrom(new byte[nonceLength]))
                    .build();
            RpcEnvelope request = RpcEnvelope.newBuilder()
                    .setFrameVersion(1)
                    .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                    .setRequestId(nonceLength + 1L)
                    .setPayloadType(PayloadType.PAYLOAD_TYPE_CLIENT_HELLO)
                    .setPayload(hello.toByteString())
                    .build();

            RpcEnvelope[] responses = dispatcher.dispatchForTest(request.toByteArray(), false, 1);

            assertEquals(1, responses.length);
            assertEquals(RpcFrameKind.RPC_FRAME_KIND_ERROR, responses[0].getKind());
            assertEquals(ErrorCode.ERROR_CODE_PROTOCOL_ERROR, responses[0].getError().getCode());
            assertEquals(request.getRequestId(), responses[0].getRequestId());
        }
    }

}
