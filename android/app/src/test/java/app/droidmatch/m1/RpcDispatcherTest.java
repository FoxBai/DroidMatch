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

public final class RpcDispatcherTest {
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
    public void cancelTransferClosesActiveDownloadAndRejectsLaterAck() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdef".getBytes(StandardCharsets.UTF_8));
        DiagnosticsReporter reporter = new DiagnosticsReporter(() -> 1L, () -> "test-thread");
        RpcDispatcher dispatcher = new RpcDispatcher(
                reporter,
                null,
                new DmFileProvider(catalog),
                null
        );
        RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(11)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("cancel-me")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_DOWNLOAD)
                        .setSourcePath("dm://media-images/media/42")
                        .setPreferredChunkSizeBytes(2)
                        .build()
                        .toByteString())
                .build();
        RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 7);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());
        assertEquals("cancel-me", openResponse.getTransferId());
        assertEquals(2, catalog.openChunkSizeBytes);

        RpcEnvelope cancelRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(12)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_CANCEL_TRANSFER_REQUEST)
                .setPayload(CancelTransferRequest.newBuilder()
                        .setTransferId("cancel-me")
                        .setReason("unit-test")
                        .build()
                        .toByteString())
                .build();
        RpcEnvelope[] cancelResponses = dispatcher.dispatchForTest(cancelRequest.toByteArray(), true, 7);

        assertEquals(1, cancelResponses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_RESPONSE, cancelResponses[0].getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_CANCEL_TRANSFER_RESPONSE, cancelResponses[0].getPayloadType());
        CancelTransferResponse cancelResponse = CancelTransferResponse.parseFrom(cancelResponses[0].getPayload());
        assertEquals("cancel-me", cancelResponse.getTransferId());
        assertEquals(true, cancelResponse.getOk());
        assertEquals(1, catalog.closeCount);
        assertEquals(1L, reporter.counters().get("rpc.transfer.cancellations.received").longValue());

        TransferChunkAck ack = TransferChunkAck.newBuilder()
                .setTransferId("cancel-me")
                .setNextOffsetBytes(2)
                .build();
        RpcEnvelope ackRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_STREAM)
                .setRequestId(11)
                .setStreamId(openResponse.getStreamId())
                .setPayloadType(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK)
                .setPayload(ack.toByteString())
                .build();
        RpcEnvelope[] ackResponses = dispatcher.dispatchForTest(ackRequest.toByteArray(), true, 7);

        assertEquals(1, ackResponses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_ERROR, ackResponses[0].getKind());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, ackResponses[0].getError().getCode());
    }

    @Test
    public void cancelTransferReturnsNotFoundForUnknownTransfer() throws Exception {
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                null,
                null
        );
        RpcEnvelope request = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(10)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_CANCEL_TRANSFER_REQUEST)
                .setPayload(CancelTransferRequest.newBuilder()
                        .setTransferId("missing-transfer")
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] responses = dispatcher.dispatchForTest(request.toByteArray(), true, 1);

        assertEquals(1, responses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_RESPONSE, responses[0].getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_CANCEL_TRANSFER_RESPONSE, responses[0].getPayloadType());
        CancelTransferResponse response = CancelTransferResponse.parseFrom(responses[0].getPayload());
        assertEquals("missing-transfer", response.getTransferId());
        assertEquals(false, response.getOk());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, response.getError().getCode());
    }

    @Test
    public void pauseActiveDownloadClosesReaderAndReturnsAcknowledgedOffset() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdef".getBytes(StandardCharsets.UTF_8));
        DiagnosticsReporter reporter = new DiagnosticsReporter(() -> 1L, () -> "test-thread");
        RpcDispatcher dispatcher = new RpcDispatcher(
                reporter,
                null,
                new DmFileProvider(catalog),
                null
        );
        RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(21)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("pause-me")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_DOWNLOAD)
                        .setSourcePath("dm://media-images/media/42")
                        .setPreferredChunkSizeBytes(2)
                        .build()
                        .toByteString())
                .build();
        RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 9);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());
        assertEquals("pause-me", openResponse.getTransferId());

        RpcEnvelope pauseRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(22)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_PAUSE_TRANSFER_REQUEST)
                .setPayload(PauseTransferRequest.newBuilder()
                        .setTransferId("pause-me")
                        .build()
                        .toByteString())
                .build();
        RpcEnvelope[] pauseResponses = dispatcher.dispatchForTest(pauseRequest.toByteArray(), true, 9);

        assertEquals(1, pauseResponses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_RESPONSE, pauseResponses[0].getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_PAUSE_TRANSFER_RESPONSE, pauseResponses[0].getPayloadType());
        PauseTransferResponse pauseResponse = PauseTransferResponse.parseFrom(pauseResponses[0].getPayload());
        assertEquals("pause-me", pauseResponse.getTransferId());
        assertEquals(true, pauseResponse.getOk());
        assertEquals(0, pauseResponse.getResumableOffsetBytes());
        assertEquals(1, catalog.closeCount);
        assertEquals(1L, reporter.counters().get("rpc.transfer.pauses.received").longValue());

        TransferChunkAck ack = TransferChunkAck.newBuilder()
                .setTransferId("pause-me")
                .setNextOffsetBytes(2)
                .build();
        RpcEnvelope ackRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_STREAM)
                .setRequestId(21)
                .setStreamId(openResponse.getStreamId())
                .setPayloadType(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK)
                .setPayload(ack.toByteString())
                .build();
        RpcEnvelope[] ackResponses = dispatcher.dispatchForTest(ackRequest.toByteArray(), true, 9);

        assertEquals(1, ackResponses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_ERROR, ackResponses[0].getKind());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, ackResponses[0].getError().getCode());
    }

    @Test
    public void pauseWithWindowedChunksReturnsLastAckNotLastSentOffset() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdefghij".getBytes(StandardCharsets.UTF_8));
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                new DmFileProvider(catalog),
                null
        );
        long sessionId = 19;
        RpcEnvelope[] openResponses = dispatcher.dispatchForTest(
                downloadOpenEnvelope(81, "pause-window", 2).toByteArray(),
                true,
                sessionId
        );
        assertEquals(2, openResponses.length);

        RpcEnvelope[] refillResponses = dispatcher.dispatchForTest(transferChunkAckEnvelope(
                81,
                81,
                "pause-window",
                2,
                false
        ).toByteArray(), true, sessionId);
        assertEquals(4, refillResponses.length);
        assertDownloadChunk(refillResponses[3], "pause-window", 8, "ij", true);

        RpcEnvelope pauseRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(82)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_PAUSE_TRANSFER_REQUEST)
                .setPayload(PauseTransferRequest.newBuilder()
                        .setTransferId("pause-window")
                        .build()
                        .toByteString())
                .build();
        RpcEnvelope[] pauseResponses = dispatcher.dispatchForTest(
                pauseRequest.toByteArray(),
                true,
                sessionId
        );

        assertEquals(1, pauseResponses.length);
        PauseTransferResponse response = PauseTransferResponse.parseFrom(
                pauseResponses[0].getPayload()
        );
        assertEquals(true, response.getOk());
        assertEquals(2, response.getResumableOffsetBytes());
        assertEquals(1, catalog.closeCount);
    }

    @Test
    public void pauseTransferReturnsNotFoundForUnknownTransfer() throws Exception {
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                null,
                null
        );
        RpcEnvelope request = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(10)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_PAUSE_TRANSFER_REQUEST)
                .setPayload(PauseTransferRequest.newBuilder()
                        .setTransferId("missing-transfer")
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] responses = dispatcher.dispatchForTest(request.toByteArray(), true, 1);

        assertEquals(1, responses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_RESPONSE, responses[0].getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_PAUSE_TRANSFER_RESPONSE, responses[0].getPayloadType());
        PauseTransferResponse response = PauseTransferResponse.parseFrom(responses[0].getPayload());
        assertEquals("missing-transfer", response.getTransferId());
        assertEquals(false, response.getOk());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, response.getError().getCode());
    }

    @Test
    public void downloadResumeRequiresSourceFingerprint() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdef".getBytes(StandardCharsets.UTF_8));
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                new DmFileProvider(catalog),
                null
        );
        RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(31)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("resume-download")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_DOWNLOAD)
                        .setSourcePath("dm://media-images/media/42")
                        .setRequestedOffsetBytes(3)
                        .setPreferredChunkSizeBytes(2)
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] responses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 7);

        assertEquals(1, responses.length);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(responses[0].getPayload());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, openResponse.getError().getCode());
        assertEquals("source_fingerprint is required for resume", openResponse.getError().getMessage());
        assertEquals(0, catalog.openChunkSizeBytes);
    }

    @Test
    public void downloadResumeRejectsChangedSourceFingerprintAndClosesReader() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdef".getBytes(StandardCharsets.UTF_8));
        catalog.modifiedUnixMillis = 1_700_000_001_000L;
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                new DmFileProvider(catalog),
                null
        );
        RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(32)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("resume-download")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_DOWNLOAD)
                        .setSourcePath("dm://media-images/media/42")
                        .setRequestedOffsetBytes(3)
                        .setSourceFingerprint(testSourceFingerprint())
                        .setPreferredChunkSizeBytes(2)
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] responses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 7);

        assertEquals(1, responses.length);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(responses[0].getPayload());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, openResponse.getError().getCode());
        assertEquals("source fingerprint changed", openResponse.getError().getMessage());
        assertEquals(1, catalog.closeCount);
    }

    @Test
    public void downloadResumeReportsNotFoundWhenSourceDisappears() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdef".getBytes(StandardCharsets.UTF_8));
        catalog.downloadAvailable = false;
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                new DmFileProvider(catalog),
                null
        );
        RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(33)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("resume-download")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_DOWNLOAD)
                        .setSourcePath("dm://media-images/media/42")
                        .setRequestedOffsetBytes(3)
                        .setSourceFingerprint(testSourceFingerprint())
                        .setPreferredChunkSizeBytes(2)
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] responses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 7);

        assertEquals(1, responses.length);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(responses[0].getPayload());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, openResponse.getError().getCode());
        assertEquals("download source is not available", openResponse.getError().getMessage());
        assertEquals(0, catalog.closeCount);
    }

    @Test
    public void downloadAckRefillsWindowUpToProtocolLimit() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdefghij".getBytes(StandardCharsets.UTF_8));
        DiagnosticsReporter reporter = new DiagnosticsReporter(() -> 1L, () -> "test-thread");
        RpcDispatcher dispatcher = new RpcDispatcher(
                reporter,
                null,
                new DmFileProvider(catalog),
                null
        );
        RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(51)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("windowed-download")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_DOWNLOAD)
                        .setSourcePath("dm://media-images/media/42")
                        .setPreferredChunkSizeBytes(2)
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 3);

        assertEquals(2, openResponses.length);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());
        assertEquals(51, openResponse.getStreamId());
        assertDownloadChunk(openResponses[1], "windowed-download", 0, "ab", false);

        RpcEnvelope[] refillResponses = dispatcher.dispatchForTest(transferChunkAckEnvelope(
                51,
                openResponse.getStreamId(),
                "windowed-download",
                2,
                false
        ).toByteArray(), true, 3);

        assertEquals(4, refillResponses.length);
        assertDownloadChunk(refillResponses[0], "windowed-download", 2, "cd", false);
        assertDownloadChunk(refillResponses[1], "windowed-download", 4, "ef", false);
        assertDownloadChunk(refillResponses[2], "windowed-download", 6, "gh", false);
        assertDownloadChunk(refillResponses[3], "windowed-download", 8, "ij", true);
        assertEquals(10L, reporter.counters().get("rpc.transfer.bytes.sent").longValue());
        assertEquals(5L, reporter.counters().get("rpc.transfer.chunks.sent").longValue());

        assertEquals(0, dispatcher.dispatchForTest(transferChunkAckEnvelope(
                51,
                openResponse.getStreamId(),
                "windowed-download",
                4,
                false
        ).toByteArray(), true, 3).length);
        assertEquals(0, dispatcher.dispatchForTest(transferChunkAckEnvelope(
                51,
                openResponse.getStreamId(),
                "windowed-download",
                6,
                false
        ).toByteArray(), true, 3).length);
        assertEquals(0, dispatcher.dispatchForTest(transferChunkAckEnvelope(
                51,
                openResponse.getStreamId(),
                "windowed-download",
                8,
                false
        ).toByteArray(), true, 3).length);
        assertEquals(0, dispatcher.dispatchForTest(transferChunkAckEnvelope(
                51,
                openResponse.getStreamId(),
                "windowed-download",
                10,
                true
        ).toByteArray(), true, 3).length);
        assertEquals(1L, reporter.counters().get("rpc.transfer.final_acks.received").longValue());
    }

    @Test
    public void dualDownloadStreamsInterleaveKeepHeartbeatResponsiveAndEnforceLimit() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdefgh".getBytes(StandardCharsets.UTF_8));
        DiagnosticsReporter reporter = new DiagnosticsReporter(() -> 1L, () -> "test-thread");
        RpcDispatcher dispatcher = new RpcDispatcher(
                reporter,
                null,
                new DmFileProvider(catalog),
                null
        );
        long sessionId = 33;

        RpcEnvelope[] firstOpen = dispatcher.dispatchForTest(
                downloadOpenEnvelope(71, "dual-a", 2).toByteArray(),
                true,
                sessionId
        );
        RpcEnvelope[] secondOpen = dispatcher.dispatchForTest(
                downloadOpenEnvelope(72, "dual-b", 2).toByteArray(),
                true,
                sessionId
        );
        assertEquals(2, firstOpen.length);
        assertEquals(2, secondOpen.length);
        assertDownloadChunk(firstOpen[1], "dual-a", 0, "ab", false);
        assertDownloadChunk(secondOpen[1], "dual-b", 0, "ab", false);

        RpcEnvelope[] heartbeat = dispatcher.dispatchForTest(
                heartbeatEnvelope(73).toByteArray(),
                true,
                sessionId
        );
        assertEquals(PayloadType.PAYLOAD_TYPE_HEARTBEAT_RESPONSE, heartbeat[0].getPayloadType());
        assertEquals(73, HeartbeatResponse.parseFrom(heartbeat[0].getPayload()).getMonotonicMillis());

        RpcEnvelope invalidDirection = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(74)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("dual-invalid")
                        .setSourcePath("dm://media-images/media/42")
                        .build()
                        .toByteString())
                .build();
        RpcEnvelope[] invalidDirectionResponse = dispatcher.dispatchForTest(
                invalidDirection.toByteArray(),
                true,
                sessionId
        );
        assertEquals(1, invalidDirectionResponse.length);
        assertEquals(
                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                OpenTransferResponse.parseFrom(invalidDirectionResponse[0].getPayload())
                        .getError()
                        .getCode()
        );

        RpcEnvelope[] duplicateTransfer = dispatcher.dispatchForTest(
                downloadOpenEnvelope(75, "dual-a", 2).toByteArray(),
                true,
                sessionId
        );
        assertEquals(1, duplicateTransfer.length);
        OpenTransferResponse duplicate = OpenTransferResponse.parseFrom(
                duplicateTransfer[0].getPayload()
        );
        assertEquals(ErrorCode.ERROR_CODE_ALREADY_EXISTS, duplicate.getError().getCode());
        assertEquals(
                "transfer_id is already active in this session",
                duplicate.getError().getMessage()
        );

        RpcEnvelope[] rejectedThird = dispatcher.dispatchForTest(
                downloadOpenEnvelope(76, "dual-c", 2).toByteArray(),
                true,
                sessionId
        );
        assertEquals(1, rejectedThird.length);
        OpenTransferResponse rejected = OpenTransferResponse.parseFrom(rejectedThird[0].getPayload());
        assertEquals(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, rejected.getError().getCode());
        assertEquals(
                "maximum concurrent transfer streams reached",
                rejected.getError().getMessage()
        );

        RpcEnvelope[] firstRefill = dispatcher.dispatchForTest(transferChunkAckEnvelope(
                71,
                71,
                "dual-a",
                2,
                false
        ).toByteArray(), true, sessionId);
        RpcEnvelope[] secondRefill = dispatcher.dispatchForTest(transferChunkAckEnvelope(
                72,
                72,
                "dual-b",
                2,
                false
        ).toByteArray(), true, sessionId);
        assertEquals(3, firstRefill.length);
        assertEquals(3, secondRefill.length);
        assertDownloadChunk(firstRefill[0], "dual-a", 2, "cd", false);
        assertDownloadChunk(secondRefill[0], "dual-b", 2, "cd", false);
        assertDownloadChunk(firstRefill[2], "dual-a", 6, "gh", true);
        assertDownloadChunk(secondRefill[2], "dual-b", 6, "gh", true);

        long[] offsets = {4, 6, 8};
        for (int index = 0; index < offsets.length; index += 1) {
            boolean finalAck = index == offsets.length - 1;
            assertEquals(0, dispatcher.dispatchForTest(transferChunkAckEnvelope(
                    71,
                    71,
                    "dual-a",
                    offsets[index],
                    finalAck
            ).toByteArray(), true, sessionId).length);
            assertEquals(0, dispatcher.dispatchForTest(transferChunkAckEnvelope(
                    72,
                    72,
                    "dual-b",
                    offsets[index],
                    finalAck
            ).toByteArray(), true, sessionId).length);
        }
        assertEquals(2, catalog.closeCount);
        assertEquals(
                1L,
                reporter.counters().get("rpc.transfer.concurrent_limit_rejected").longValue()
        );

        RpcEnvelope[] replacementOpen = dispatcher.dispatchForTest(
                downloadOpenEnvelope(77, "dual-c", 2).toByteArray(),
                true,
                sessionId
        );
        assertEquals(2, replacementOpen.length);
        assertDownloadChunk(replacementOpen[1], "dual-c", 0, "ab", false);
    }

    @Test
    public void uploadWritesChunksToAppSandboxAndAcksBoundaries() throws Exception {
        File root = Files.createTempDirectory("droidmatch-upload").toFile();
        try {
            DiagnosticsReporter reporter = new DiagnosticsReporter(() -> 1L, () -> "test-thread");
            RpcDispatcher dispatcher = new RpcDispatcher(
                    reporter,
                    null,
                    new DmFileProvider(root),
                    null
            );
            RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                    .setFrameVersion(1)
                    .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                    .setRequestId(31)
                    .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                    .setPayload(OpenTransferRequest.newBuilder()
                            .setTransferId("upload-me")
                            .setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                            .setSourcePath("/tmp/payload.bin")
                            .setDestinationPath("dm://app-sandbox/uploads/payload.bin")
                            .setExpectedSizeBytes(6)
                            .setPreferredChunkSizeBytes(4)
                            .build()
                            .toByteString())
                    .build();

            RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 5);

            assertEquals(1, openResponses.length);
            assertEquals(RpcFrameKind.RPC_FRAME_KIND_RESPONSE, openResponses[0].getKind());
            assertEquals(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_RESPONSE, openResponses[0].getPayloadType());
            OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());
            assertEquals("upload-me", openResponse.getTransferId());
            assertEquals(0, openResponse.getAcceptedOffsetBytes());
            assertEquals(4, openResponse.getChunkSizeBytes());
            assertEquals(6, openResponse.getTotalSizeBytes());
            assertEquals(31, openResponse.getStreamId());

            RpcEnvelope[] firstAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                    31,
                    openResponse.getStreamId(),
                    "upload-me",
                    0,
                    "abc",
                    false
            ).toByteArray(), true, 5);
            TransferChunkAck first = TransferChunkAck.parseFrom(firstAck[0].getPayload());
            assertEquals(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK, firstAck[0].getPayloadType());
            assertEquals(3, first.getNextOffsetBytes());
            assertEquals(false, first.getFinalAck());

            RpcEnvelope[] finalAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                    31,
                    openResponse.getStreamId(),
                    "upload-me",
                    3,
                    "def",
                    true
            ).toByteArray(), true, 5);
            TransferChunkAck finalResponse = TransferChunkAck.parseFrom(finalAck[0].getPayload());
            assertEquals(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK, finalAck[0].getPayloadType());
            assertEquals(6, finalResponse.getNextOffsetBytes());
            assertEquals(true, finalResponse.getFinalAck());
            assertEquals("abcdef", new String(
                    Files.readAllBytes(new File(root, "uploads/payload.bin").toPath()),
                    StandardCharsets.UTF_8
            ));
            assertEquals(6L, reporter.counters().get("rpc.transfer.bytes.received").longValue());
            assertEquals(1L, reporter.counters().get("rpc.transfer.uploads.completed").longValue());
        } finally {
            deleteRecursively(root);
        }
    }

    @Test
    public void cancelActiveUploadReleasesWriterAndAllowsSafeResume() throws Exception {
        File root = Files.createTempDirectory("droidmatch-upload-cancel").toFile();
        try {
            RpcDispatcher dispatcher = new RpcDispatcher(
                    new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                    null,
                    new DmFileProvider(root),
                    null
            );
            long sessionId = 21;
            RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                    .setFrameVersion(1)
                    .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                    .setRequestId(41)
                    .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                    .setPayload(OpenTransferRequest.newBuilder()
                            .setTransferId("cancel-upload")
                            .setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                            .setSourcePath("/tmp/payload.bin")
                            .setDestinationPath("dm://app-sandbox/uploads/cancel.bin")
                            .setExpectedSizeBytes(6)
                            .setPreferredChunkSizeBytes(4)
                            .build()
                            .toByteString())
                    .build();
            OpenTransferResponse opened = OpenTransferResponse.parseFrom(
                    dispatcher.dispatchForTest(openRequest.toByteArray(), true, sessionId)[0]
                            .getPayload()
            );
            RpcEnvelope[] firstAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                    41,
                    opened.getStreamId(),
                    "cancel-upload",
                    0,
                    "abc",
                    false
            ).toByteArray(), true, sessionId);
            assertEquals(3, TransferChunkAck.parseFrom(firstAck[0].getPayload()).getNextOffsetBytes());

            RpcEnvelope cancelRequest = RpcEnvelope.newBuilder()
                    .setFrameVersion(1)
                    .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                    .setRequestId(42)
                    .setPayloadType(PayloadType.PAYLOAD_TYPE_CANCEL_TRANSFER_REQUEST)
                    .setPayload(CancelTransferRequest.newBuilder()
                            .setTransferId("cancel-upload")
                            .setReason("unit-test")
                            .build()
                            .toByteString())
                    .build();
            CancelTransferResponse cancelled = CancelTransferResponse.parseFrom(
                    dispatcher.dispatchForTest(cancelRequest.toByteArray(), true, sessionId)[0]
                            .getPayload()
            );
            assertEquals(true, cancelled.getOk());

            RpcEnvelope resumeRequest = RpcEnvelope.newBuilder()
                    .setFrameVersion(1)
                    .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                    .setRequestId(43)
                    .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                    .setPayload(OpenTransferRequest.newBuilder()
                            .setTransferId("cancel-upload")
                            .setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                            .setSourcePath("/tmp/payload.bin")
                            .setDestinationPath("dm://app-sandbox/uploads/cancel.bin")
                            .setRequestedOffsetBytes(3)
                            .setExpectedSizeBytes(6)
                            .setPreferredChunkSizeBytes(4)
                            .build()
                            .toByteString())
                    .build();
            OpenTransferResponse resumed = OpenTransferResponse.parseFrom(
                    dispatcher.dispatchForTest(resumeRequest.toByteArray(), true, sessionId)[0]
                            .getPayload()
            );
            assertEquals(3, resumed.getAcceptedOffsetBytes());

            RpcEnvelope[] finalAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                    43,
                    resumed.getStreamId(),
                    "cancel-upload",
                    3,
                    "def",
                    true
            ).toByteArray(), true, sessionId);
            assertEquals(true, TransferChunkAck.parseFrom(finalAck[0].getPayload()).getFinalAck());
            assertEquals("abcdef", new String(
                    Files.readAllBytes(new File(root, "uploads/cancel.bin").toPath()),
                    StandardCharsets.UTF_8
            ));
        } finally {
            deleteRecursively(root);
        }
    }

    @Test
    public void uploadChunkRejectsBadCrc32() throws Exception {
        File root = Files.createTempDirectory("droidmatch-upload-crc").toFile();
        try {
            RpcDispatcher dispatcher = new RpcDispatcher(
                    new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                    null,
                    new DmFileProvider(root),
                    null
            );
            RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                    .setFrameVersion(1)
                    .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                    .setRequestId(35)
                    .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                    .setPayload(OpenTransferRequest.newBuilder()
                            .setTransferId("bad-crc-upload")
                            .setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                            .setSourcePath("/tmp/payload.bin")
                            .setDestinationPath("dm://app-sandbox/uploads/payload.bin")
                            .setExpectedSizeBytes(3)
                            .setPreferredChunkSizeBytes(4)
                            .build()
                            .toByteString())
                    .build();
            RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 5);
            OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());

            RpcEnvelope[] responses = dispatcher.dispatchForTest(uploadChunkEnvelope(
                    35,
                    openResponse.getStreamId(),
                    "bad-crc-upload",
                    0,
                    "abc",
                    false,
                    0
            ).toByteArray(), true, 5);

            assertEquals(1, responses.length);
            assertEquals(RpcFrameKind.RPC_FRAME_KIND_ERROR, responses[0].getKind());
            assertEquals(ErrorCode.ERROR_CODE_CHECKSUM_MISMATCH, responses[0].getError().getCode());
            assertEquals("transfer chunk crc32 mismatch", responses[0].getError().getMessage());
        } finally {
            deleteRecursively(root);
        }
    }

    @Test
    public void uploadWritesChunksToSafDestinationAndAcksBoundaries() throws Exception {
        TestSafCatalog safCatalog = new TestSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:Docs", "Documents", true)
        );
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                new DmFileProvider(new TestMediaCatalog(new byte[0]), safCatalog),
                null
        );
        RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(37)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("saf-upload")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                        .setSourcePath("/tmp/payload.txt")
                        .setDestinationPath("dm://saf-abc123/payload.txt")
                        .setExpectedSizeBytes(6)
                        .setPreferredChunkSizeBytes(4)
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 7);

        assertEquals(1, openResponses.length);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());
        assertEquals(0, openResponse.getAcceptedOffsetBytes());
        assertEquals(37, openResponse.getStreamId());

        RpcEnvelope[] firstAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                37,
                openResponse.getStreamId(),
                "saf-upload",
                0,
                "abc",
                false
        ).toByteArray(), true, 7);
        TransferChunkAck first = TransferChunkAck.parseFrom(firstAck[0].getPayload());
        assertEquals(3, first.getNextOffsetBytes());
        assertEquals(false, first.getFinalAck());

        RpcEnvelope[] finalAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                37,
                openResponse.getStreamId(),
                "saf-upload",
                3,
                "def",
                true
        ).toByteArray(), true, 7);
        TransferChunkAck finalResponse = TransferChunkAck.parseFrom(finalAck[0].getPayload());
        assertEquals(6, finalResponse.getNextOffsetBytes());
        assertEquals(true, finalResponse.getFinalAck());
        assertEquals("primary:Docs", safCatalog.uploadParentDocumentId);
        assertEquals("payload.txt", safCatalog.uploadDisplayName);
        assertEquals("saf-upload", safCatalog.uploadTransferId);
        assertEquals("abcdef", safCatalog.uploadedText());
    }

    @Test
    public void uploadWritesChunksToMediaStoreDestinationAndAcksBoundaries() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog(new byte[0]);
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                new DmFileProvider(catalog),
                null
        );
        RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(39)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("media-upload")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                        .setSourcePath("/tmp/payload.jpg")
                        .setDestinationPath("dm://media-images/payload.jpg")
                        .setExpectedSizeBytes(6)
                        .setPreferredChunkSizeBytes(4)
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 7);

        assertEquals(1, openResponses.length);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());
        assertEquals(0, openResponse.getAcceptedOffsetBytes());
        assertEquals(39, openResponse.getStreamId());

        RpcEnvelope[] firstAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                39,
                openResponse.getStreamId(),
                "media-upload",
                0,
                "abc",
                false
        ).toByteArray(), true, 7);
        TransferChunkAck first = TransferChunkAck.parseFrom(firstAck[0].getPayload());
        assertEquals(3, first.getNextOffsetBytes());
        assertEquals(false, first.getFinalAck());

        RpcEnvelope[] finalAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                39,
                openResponse.getStreamId(),
                "media-upload",
                3,
                "def",
                true
        ).toByteArray(), true, 7);
        TransferChunkAck finalResponse = TransferChunkAck.parseFrom(finalAck[0].getPayload());
        assertEquals(6, finalResponse.getNextOffsetBytes());
        assertEquals(true, finalResponse.getFinalAck());
        assertEquals(DmFileProvider.RootKind.MEDIA_IMAGES, catalog.uploadRootKind);
        assertEquals("payload.jpg", catalog.uploadDisplayName);
        assertEquals("abcdef", catalog.uploadedText());
    }

    @Test
    public void uploadResumeAcceptsExistingAppSandboxPartialOffset() throws Exception {
        File root = Files.createTempDirectory("droidmatch-upload-resume").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);
            DmFileProvider.UploadWriter partialWriter = provider.openUpload(
                    "dm://app-sandbox/uploads/payload.bin",
                    0,
                    6
            );
            partialWriter.writeChunk(0, "abc".getBytes(StandardCharsets.UTF_8), false);
            partialWriter.close();
            RpcDispatcher dispatcher = new RpcDispatcher(
                    new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                    null,
                    provider,
                    null
            );
            RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                    .setFrameVersion(1)
                    .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                    .setRequestId(41)
                    .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                    .setPayload(OpenTransferRequest.newBuilder()
                            .setTransferId("resume-upload")
                            .setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                            .setSourcePath("/tmp/payload.bin")
                            .setDestinationPath("dm://app-sandbox/uploads/payload.bin")
                            .setRequestedOffsetBytes(3)
                            .setExpectedSizeBytes(6)
                            .setPreferredChunkSizeBytes(4)
                            .build()
                            .toByteString())
                    .build();

            RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 8);

            assertEquals(1, openResponses.length);
            OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());
            assertEquals(3, openResponse.getAcceptedOffsetBytes());
            assertEquals(41, openResponse.getStreamId());

            RpcEnvelope[] finalAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                    41,
                    openResponse.getStreamId(),
                    "resume-upload",
                    3,
                    "def",
                    true
            ).toByteArray(), true, 8);
            TransferChunkAck finalResponse = TransferChunkAck.parseFrom(finalAck[0].getPayload());
            assertEquals(6, finalResponse.getNextOffsetBytes());
            assertEquals(true, finalResponse.getFinalAck());
            assertEquals("abcdef", new String(
                    Files.readAllBytes(new File(root, "uploads/payload.bin").toPath()),
                    StandardCharsets.UTF_8
            ));
        } finally {
            deleteRecursively(root);
        }
    }

    @Test
    public void transferAckRejectsReservedZeroStreamId() throws Exception {
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                null,
                null
        );
        TransferChunkAck ack = TransferChunkAck.newBuilder()
                .setTransferId("loopback-transfer")
                .setNextOffsetBytes(1)
                .build();
        RpcEnvelope request = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_STREAM)
                .setRequestId(9)
                .setStreamId(0)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK)
                .setPayload(ack.toByteString())
                .build();

        RpcEnvelope[] responses = dispatcher.dispatchForTest(request.toByteArray(), true, 1);

        assertEquals(1, responses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_ERROR, responses[0].getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_DROIDMATCH_ERROR, responses[0].getPayloadType());
        assertEquals(ErrorCode.ERROR_CODE_PROTOCOL_ERROR, responses[0].getError().getCode());
        assertEquals("stream_id must be non-zero for transfer acknowledgements", responses[0].getError().getMessage());
    }

    private static RpcEnvelope uploadChunkEnvelope(
            long requestId,
            long streamId,
            String transferId,
            long offsetBytes,
            String text,
            boolean finalChunk
    ) {
        byte[] data = text.getBytes(StandardCharsets.UTF_8);
        return uploadChunkEnvelope(
                requestId,
                streamId,
                transferId,
                offsetBytes,
                text,
                finalChunk,
                crc32(data)
        );
    }

    private static RpcDispatcher pairedDispatcher(byte[] pairingId, byte[] pairingKey) {
        PairingKeyProvider provider = candidate -> Arrays.equals(candidate, pairingId)
                ? Arrays.copyOf(pairingKey, pairingKey.length)
                : null;
        return new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                null,
                null,
                SessionAuthenticationMode.PAIRED_REQUIRED,
                provider,
                null,
                null,
                testDeviceIdentity()
        );
    }

    private static RpcDispatcher pairedDispatcher(
            byte[] pairingId,
            byte[] pairingKey,
            AuthenticationRateLimiter limiter
    ) {
        PairingKeyProvider provider = candidate -> Arrays.equals(candidate, pairingId)
                ? Arrays.copyOf(pairingKey, pairingKey.length)
                : null;
        return new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                null,
                null,
                SessionAuthenticationMode.PAIRED_REQUIRED,
                provider,
                null,
                null,
                testDeviceIdentity(),
                limiter
        );
    }

    private static DeviceIdentityProvider testDeviceIdentity() {
        return new DeviceIdentityProvider() {
            @Override
            public byte[] publicKeyX963Representation() {
                return new byte[PairingAuthenticator.PUBLIC_KEY_LENGTH];
            }

            @Override
            public byte[] fingerprint() {
                return sequentialBytes(0x50, PairingAuthenticator.DIGEST_LENGTH);
            }

            @Override
            public byte[] signPairingTranscript(byte[] transcript) {
                return new byte[] {0x01};
            }
        };
    }

    private static final class FakeAuthenticationClock implements AuthenticationRateLimiter.Clock {
        private long nowMillis;

        @Override
        public long nowMillis() {
            return nowMillis;
        }

        private void advance(long millis) {
            nowMillis += millis;
        }
    }

    private static RpcEnvelope clientHelloEnvelope(long requestId, byte[] nonce, byte[] pairingId) {
        return clientHelloEnvelope(
                requestId,
                nonce,
                pairingId,
                Capability.CAPABILITY_DIAGNOSTICS
        );
    }

    private static RpcEnvelope clientHelloEnvelope(
            long requestId,
            byte[] nonce,
            byte[] pairingId,
            Capability... requestedCapabilities
    ) {
        ClientHello hello = ClientHello.newBuilder()
                .setClientName("DroidMatchTests")
                .setClientVersion("test")
                .setProtocolMajor(1)
                .setProtocolMinor(0)
                .setTransport(TransportKind.TRANSPORT_KIND_ADB)
                .addAllRequestedCapabilities(Arrays.asList(requestedCapabilities))
                .setSessionNonce(ByteString.copyFrom(nonce))
                .setPairingId(ByteString.copyFrom(pairingId))
                .build();
        return RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_CLIENT_HELLO)
                .setPayload(hello.toByteString())
                .build();
    }

    private static RpcEnvelope authenticationEnvelope(long requestId, byte[] pairingId, byte[] clientProof) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_AUTHENTICATE_SESSION_REQUEST)
                .setPayload(AuthenticateSessionRequest.newBuilder()
                        .setPairingId(ByteString.copyFrom(pairingId))
                        .setClientProof(ByteString.copyFrom(clientProof))
                        .build()
                        .toByteString())
                .build();
    }

    private static RpcEnvelope heartbeatEnvelope(long requestId) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_HEARTBEAT_REQUEST)
                .setPayload(HeartbeatRequest.newBuilder().setMonotonicMillis(requestId).build().toByteString())
                .build();
    }

    private static RpcEnvelope downloadOpenEnvelope(
            long requestId,
            String transferId,
            int preferredChunkSizeBytes
    ) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId(transferId)
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_DOWNLOAD)
                        .setSourcePath("dm://media-images/media/42")
                        .setPreferredChunkSizeBytes(preferredChunkSizeBytes)
                        .build()
                        .toByteString())
                .build();
    }

    private static byte[] sequentialBytes(int start, int count) {
        byte[] bytes = new byte[count];
        for (int index = 0; index < count; index += 1) {
            bytes[index] = (byte) (start + index);
        }
        return bytes;
    }

    private static RpcEnvelope uploadChunkEnvelope(
            long requestId,
            long streamId,
            String transferId,
            long offsetBytes,
            String text,
            boolean finalChunk,
            int crc32
    ) {
        byte[] data = text.getBytes(StandardCharsets.UTF_8);
        return RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_STREAM)
                .setRequestId(requestId)
                .setStreamId(streamId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK)
                .setPayload(TransferChunk.newBuilder()
                        .setTransferId(transferId)
                        .setOffsetBytes(offsetBytes)
                        .setData(com.google.protobuf.ByteString.copyFrom(data))
                        .setCrc32(crc32)
                        .setFinalChunk(finalChunk)
                        .build()
                        .toByteString())
                .build();
    }

    private static RpcEnvelope transferChunkAckEnvelope(
            long requestId,
            long streamId,
            String transferId,
            long nextOffsetBytes,
            boolean finalAck
    ) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_STREAM)
                .setRequestId(requestId)
                .setStreamId(streamId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK)
                .setPayload(TransferChunkAck.newBuilder()
                        .setTransferId(transferId)
                        .setNextOffsetBytes(nextOffsetBytes)
                        .setFinalAck(finalAck)
                        .build()
                        .toByteString())
                .build();
    }

    private static void assertDownloadChunk(
            RpcEnvelope envelope,
            String transferId,
            long offsetBytes,
            String text,
            boolean finalChunk
    ) throws Exception {
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_STREAM, envelope.getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK, envelope.getPayloadType());
        TransferChunk chunk = TransferChunk.parseFrom(envelope.getPayload());
        byte[] expectedData = text.getBytes(StandardCharsets.UTF_8);
        assertEquals(transferId, chunk.getTransferId());
        assertEquals(offsetBytes, chunk.getOffsetBytes());
        assertEquals(text, new String(chunk.getData().toByteArray(), StandardCharsets.UTF_8));
        assertEquals(crc32(expectedData), chunk.getCrc32());
        assertEquals(finalChunk, chunk.getFinalChunk());
    }

    private static int crc32(byte[] data) {
        CRC32 crc32 = new CRC32();
        crc32.update(data);
        return (int) crc32.getValue();
    }

    private static TransferFingerprint testSourceFingerprint() {
        return TransferFingerprint.newBuilder()
                .setSizeBytes(6)
                .setModifiedUnixMillis(1_700_000_000_000L)
                .setProviderEtag("test-etag")
                .build();
    }

    private static void deleteRecursively(File file) {
        if (file == null || !file.exists()) {
            return;
        }
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) {
                deleteRecursively(child);
            }
        }
        file.delete();
    }

    private static final class TestMediaCatalog implements DmFileProvider.MediaCatalog {
        private final byte[] data;
        private boolean downloadAvailable = true;
        private long modifiedUnixMillis = 1_700_000_000_000L;
        private String providerEtag = "test-etag";
        private int openChunkSizeBytes;
        private int closeCount;
        private DmFileProvider.RootKind uploadRootKind;
        private String uploadDisplayName;
        private ByteArrayOutputStream uploadedBytes;

        private TestMediaCatalog(byte[] data) {
            this.data = data;
        }

        @Override
        public DmFileProvider.MediaPage listMedia(
                DmFileProvider.RootKind rootKind,
                DmFileProvider.ProviderQuery query
        ) {
            return new DmFileProvider.MediaPage(Collections.emptyList(), false);
        }

        @Override
        public DmFileProvider.DownloadChunk readMedia(
                DmFileProvider.RootKind rootKind,
                long mediaId,
                long offsetBytes,
                int chunkSizeBytes
        ) throws DmFileProvider.ProviderCatalogException {
            if (!downloadAvailable) {
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "download source is not available"
                );
            }
            int start = (int) offsetBytes;
            int end = Math.min(start + chunkSizeBytes, data.length);
            return new DmFileProvider.DownloadChunk(
                    Arrays.copyOfRange(data, start, end),
                    data.length,
                    modifiedUnixMillis,
                    providerEtag,
                    end >= data.length
            );
        }

        @Override
        public DmFileProvider.DownloadReader openMedia(
                DmFileProvider.RootKind rootKind,
                long mediaId,
                long offsetBytes,
                int chunkSizeBytes
        ) throws DmFileProvider.ProviderCatalogException {
            if (!downloadAvailable) {
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "download source is not available"
                );
            }
            openChunkSizeBytes = chunkSizeBytes;
            return new DmFileProvider.DownloadReader() {
                private int offset = (int) offsetBytes;
                private boolean closed;

                @Override
                public DmFileProvider.DownloadChunk readNextChunk() {
                    int end = Math.min(offset + chunkSizeBytes, data.length);
                    byte[] chunk = Arrays.copyOfRange(data, offset, end);
                    offset = end;
                    return new DmFileProvider.DownloadChunk(
                            chunk,
                            data.length,
                            modifiedUnixMillis,
                            providerEtag,
                            offset >= data.length
                    );
                }

                @Override
                public void close() {
                    if (closed) {
                        return;
                    }
                    closed = true;
                    closeCount++;
                }
            };
        }

        @Override
        public DmFileProvider.UploadWriter openUploadMedia(
                DmFileProvider.RootKind rootKind,
                String displayName,
                long offsetBytes,
                long expectedSizeBytes
        ) {
            this.uploadRootKind = rootKind;
            this.uploadDisplayName = displayName;
            this.uploadedBytes = new ByteArrayOutputStream();
            return new DmFileProvider.UploadWriter() {
                private long nextOffsetBytes = offsetBytes;
                private boolean closed;

                @Override
                public long nextOffsetBytes() {
                    return nextOffsetBytes;
                }

                @Override
                public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
                        throws DmFileProvider.ProviderCatalogException {
                    if (closed) {
                        throw new DmFileProvider.ProviderCatalogException(
                                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                                "upload writer is closed"
                        );
                    }
                    if (offsetBytes != nextOffsetBytes) {
                        throw new DmFileProvider.ProviderCatalogException(
                                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                                "transfer chunk offset does not match the expected write boundary"
                        );
                    }
                    uploadedBytes.write(data, 0, data.length);
                    nextOffsetBytes += data.length;
                    if (finalChunk) {
                        close();
                    }
                }

                @Override
                public void close() {
                    closed = true;
                }
            };
        }

        private String uploadedText() {
            return new String(uploadedBytes.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    private static final class TestSafCatalog implements DmFileProvider.SafCatalog {
        private final DmFileProvider.SafRoot root;
        private String uploadParentDocumentId;
        private String uploadDisplayName;
        private String uploadTransferId;
        private ByteArrayOutputStream uploadedBytes;

        private TestSafCatalog(DmFileProvider.SafRoot root) {
            this.root = root;
        }

        @Override
        public java.util.List<DmFileProvider.SafRoot> roots() {
            return Collections.singletonList(root);
        }

        @Override
        public DmFileProvider.SafPage listChildren(
                DmFileProvider.SafRoot root,
                String documentId,
                DmFileProvider.ProviderQuery query
        ) {
            return new DmFileProvider.SafPage(Collections.emptyList(), false);
        }

        @Override
        public DmFileProvider.DownloadChunk readDocument(
                DmFileProvider.SafRoot root,
                String documentId,
                long offsetBytes,
                int chunkSizeBytes
        ) throws DmFileProvider.ProviderCatalogException {
            throw new DmFileProvider.ProviderCatalogException(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "SAF document is not available"
            );
        }

        @Override
        public DmFileProvider.UploadWriter openUploadDocument(
                DmFileProvider.SafRoot root,
                String parentDocumentId,
                String displayName,
                String transferId,
                long offsetBytes,
                long expectedSizeBytes
        ) {
            this.uploadParentDocumentId = parentDocumentId;
            this.uploadDisplayName = displayName;
            this.uploadTransferId = transferId;
            this.uploadedBytes = new ByteArrayOutputStream();
            return new DmFileProvider.UploadWriter() {
                private long nextOffsetBytes = offsetBytes;
                private boolean closed;

                @Override
                public long nextOffsetBytes() {
                    return nextOffsetBytes;
                }

                @Override
                public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
                        throws DmFileProvider.ProviderCatalogException {
                    if (closed) {
                        throw new DmFileProvider.ProviderCatalogException(
                                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                                "upload writer is closed"
                        );
                    }
                    if (offsetBytes != nextOffsetBytes) {
                        throw new DmFileProvider.ProviderCatalogException(
                                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                                "transfer chunk offset does not match the expected write boundary"
                        );
                    }
                    uploadedBytes.write(data, 0, data.length);
                    nextOffsetBytes += data.length;
                    if (finalChunk) {
                        close();
                    }
                }

                @Override
                public void close() {
                    closed = true;
                }
            };
        }

        private String uploadedText() {
            return new String(uploadedBytes.toByteArray(), StandardCharsets.UTF_8);
        }
    }
}
