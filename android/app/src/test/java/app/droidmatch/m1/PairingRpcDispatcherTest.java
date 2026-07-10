package app.droidmatch.m1;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.AuthenticateSessionRequest;
import app.droidmatch.proto.v1.AuthenticateSessionResponse;
import app.droidmatch.proto.v1.AuthenticationState;
import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.ClientHello;
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

import java.security.GeneralSecurityException;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import org.junit.Test;

public final class PairingRpcDispatcherTest {
    @Test
    public void firstPairingCompletesThenAuthenticatesFreshSession() throws Exception {
        PairingApprovalController approvals = new PairingApprovalController();
        assertTrue(approvals.openWindow(60_000));
        InMemoryPairingRepository repository = new InMemoryPairingRepository();
        TestDeviceIdentity identity = new TestDeviceIdentity();
        RpcDispatcher dispatcher = dispatcher(repository, approvals, identity);
        RpcDispatcher.SessionState pairingState = dispatcher.newSessionStateForTest();
        PairingKeyAgreement clientKeyAgreement = PairingKeyAgreement.generate();
        byte[] clientNonce = sequentialBytes(0x10, 32);

        PairingStartRequest start = PairingStartRequest.newBuilder()
                .setPairingVersion(PairingAuthenticator.VERSION)
                .setClientName("DroidMatch Mac Test")
                .setClientPublicKey(ByteString.copyFrom(clientKeyAgreement.publicKeyX963Representation()))
                .setClientNonce(ByteString.copyFrom(clientNonce))
                .build();
        PairingStartResponse startResponse = PairingStartResponse.parseFrom(dispatcher.dispatchForTest(
                request(1, PayloadType.PAYLOAD_TYPE_PAIRING_START_REQUEST, start.toByteString()).toByteArray(),
                pairingState,
                1
        )[0].getPayload());
        assertFalse(startResponse.hasError());
        assertEquals(PairingAuthenticator.VERSION, startResponse.getPairingVersion());

        byte[] transcript = PairingAuthenticator.transcript(
                startResponse.getPairingVersion(),
                startResponse.getPairingId().toByteArray(),
                start.getClientPublicKey().toByteArray(),
                startResponse.getServerPublicKey().toByteArray(),
                startResponse.getDeviceIdentityPublicKey().toByteArray(),
                clientNonce,
                startResponse.getServerNonce().toByteArray(),
                start.getClientName(),
                startResponse.getServerName()
        );
        assertTrue(AndroidDeviceIdentity.verifyPairingTranscriptSignature(
                startResponse.getDeviceIdentityPublicKey().toByteArray(),
                transcript,
                startResponse.getDeviceIdentitySignature().toByteArray()
        ));
        assertArrayEquals(
                PairingAuthenticator.transcriptHash(startResponse.getDeviceIdentityPublicKey().toByteArray()),
                identity.fingerprint()
        );

        byte[] transcriptHash = PairingAuthenticator.transcriptHash(transcript);
        byte[] sharedSecret = clientKeyAgreement.sharedSecret(
                startResponse.getServerPublicKey().toByteArray()
        );
        byte[] persistedPairingKey;
        try (PairingAuthenticator.DerivedSecrets secrets = PairingAuthenticator.deriveSecrets(
                sharedSecret,
                transcriptHash
        )) {
            assertEquals(
                    secrets.shortAuthenticationString(),
                    approvals.snapshot().shortAuthenticationString()
            );
            assertTrue(approvals.approve(startResponse.getPairingId().toByteArray()));

            PairingConfirmRequest confirm = PairingConfirmRequest.newBuilder()
                    .setPairingId(startResponse.getPairingId())
                    .setClientApproved(true)
                    .setClientConfirmation(ByteString.copyFrom(PairingAuthenticator.clientConfirmation(
                            secrets.confirmationKey(),
                            transcriptHash
                    )))
                    .build();
            PairingConfirmResponse confirmResponse = PairingConfirmResponse.parseFrom(
                    dispatcher.dispatchForTest(
                            request(
                                    2,
                                    PayloadType.PAYLOAD_TYPE_PAIRING_CONFIRM_REQUEST,
                                    confirm.toByteString()
                            ).toByteArray(),
                            pairingState,
                            1
                    )[0].getPayload()
            );
            assertTrue(confirmResponse.getClientConfirmationAccepted());
            assertTrue(confirmResponse.getServerApproved());
            assertTrue(PairingAuthenticator.verifyServerConfirmation(
                    confirmResponse.getServerConfirmation().toByteArray(),
                    secrets.confirmationKey(),
                    transcriptHash
            ));

            PairingFinalizeRequest finalize = PairingFinalizeRequest.newBuilder()
                    .setPairingId(startResponse.getPairingId())
                    .setFinalConfirmation(ByteString.copyFrom(PairingAuthenticator.finalConfirmation(
                            secrets.confirmationKey(),
                            transcriptHash,
                            confirmResponse.getServerConfirmation().toByteArray()
                    )))
                    .build();
            PairingFinalizeResponse finalizeResponse = PairingFinalizeResponse.parseFrom(
                    dispatcher.dispatchForTest(
                            request(
                                    3,
                                    PayloadType.PAYLOAD_TYPE_PAIRING_FINALIZE_REQUEST,
                                    finalize.toByteString()
                            ).toByteArray(),
                            pairingState,
                            1
                    )[0].getPayload()
            );
            assertTrue(finalizeResponse.getPaired());
            assertFalse(finalizeResponse.hasError());
            persistedPairingKey = secrets.pairingKey();
        } finally {
            Arrays.fill(sharedSecret, (byte) 0);
        }

        PairingCredentialRecord stored = repository.load(startResponse.getPairingId().toByteArray());
        assertNotNull(stored);
        assertArrayEquals(persistedPairingKey, stored.pairingKey());
        assertArrayEquals(identity.fingerprint(), stored.deviceIdentityFingerprint());
        assertFalse(approvals.snapshot().windowOpen());

        RpcDispatcher.SessionState reconnectState = dispatcher.newSessionStateForTest();
        byte[] reconnectNonce = sequentialBytes(0x40, 32);
        ClientHello hello = ClientHello.newBuilder()
                .setClientName("DroidMatch Mac Test")
                .setClientVersion("test")
                .setProtocolMajor(1)
                .setProtocolMinor(0)
                .setTransport(TransportKind.TRANSPORT_KIND_ADB)
                .addRequestedCapabilities(Capability.CAPABILITY_DIAGNOSTICS)
                .setSessionNonce(ByteString.copyFrom(reconnectNonce))
                .setPairingId(startResponse.getPairingId())
                .build();
        ServerHello serverHello = ServerHello.parseFrom(dispatcher.dispatchForTest(
                request(4, PayloadType.PAYLOAD_TYPE_CLIENT_HELLO, hello.toByteString()).toByteArray(),
                reconnectState,
                2
        )[0].getPayload());
        assertEquals(AuthenticationState.AUTHENTICATION_STATE_REQUIRED, serverHello.getAuthenticationState());
        byte[] reconnectTranscriptHash = SessionAuthenticator.transcriptHash(SessionAuthenticator.transcript(
                startResponse.getPairingId().toByteArray(),
                reconnectNonce,
                serverHello.getServerNonce().toByteArray(),
                1,
                0,
                TransportKind.TRANSPORT_KIND_ADB.getNumber()
        ));
        AuthenticateSessionRequest authenticate = AuthenticateSessionRequest.newBuilder()
                .setPairingId(startResponse.getPairingId())
                .setClientProof(ByteString.copyFrom(SessionAuthenticator.clientProof(
                        persistedPairingKey,
                        reconnectTranscriptHash
                )))
                .build();
        AuthenticateSessionResponse authenticationResponse = AuthenticateSessionResponse.parseFrom(
                dispatcher.dispatchForTest(
                        request(
                                5,
                                PayloadType.PAYLOAD_TYPE_AUTHENTICATE_SESSION_REQUEST,
                                authenticate.toByteString()
                        ).toByteArray(),
                        reconnectState,
                        2
                )[0].getPayload()
        );
        assertTrue(authenticationResponse.getAuthenticated());
        assertTrue(SessionAuthenticator.verifyServerProof(
                authenticationResponse.getServerProof().toByteArray(),
                persistedPairingKey,
                reconnectTranscriptHash
        ));
        Arrays.fill(persistedPairingKey, (byte) 0);
    }

    @Test
    public void closedWindowAndExplicitRejectionNeverPersistCredential() throws Exception {
        PairingApprovalController approvals = new PairingApprovalController();
        InMemoryPairingRepository repository = new InMemoryPairingRepository();
        RpcDispatcher dispatcher = dispatcher(repository, approvals, new TestDeviceIdentity());
        PairingKeyAgreement client = PairingKeyAgreement.generate();
        PairingStartRequest start = PairingStartRequest.newBuilder()
                .setPairingVersion(1)
                .setClientName("Rejected Mac")
                .setClientPublicKey(ByteString.copyFrom(client.publicKeyX963Representation()))
                .setClientNonce(ByteString.copyFrom(new byte[32]))
                .build();

        PairingStartResponse closed = PairingStartResponse.parseFrom(dispatcher.dispatchForTest(
                request(1, PayloadType.PAYLOAD_TYPE_PAIRING_START_REQUEST, start.toByteString()).toByteArray(),
                dispatcher.newSessionStateForTest(),
                1
        )[0].getPayload());
        assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, closed.getError().getCode());
        assertTrue(repository.list().isEmpty());

        assertTrue(approvals.openWindow(60_000));
        RpcDispatcher.SessionState state = dispatcher.newSessionStateForTest();
        PairingStartResponse accepted = PairingStartResponse.parseFrom(dispatcher.dispatchForTest(
                request(2, PayloadType.PAYLOAD_TYPE_PAIRING_START_REQUEST, start.toByteString()).toByteArray(),
                state,
                2
        )[0].getPayload());
        byte[] transcript = PairingAuthenticator.transcript(
                1,
                accepted.getPairingId().toByteArray(),
                start.getClientPublicKey().toByteArray(),
                accepted.getServerPublicKey().toByteArray(),
                accepted.getDeviceIdentityPublicKey().toByteArray(),
                start.getClientNonce().toByteArray(),
                accepted.getServerNonce().toByteArray(),
                start.getClientName(),
                accepted.getServerName()
        );
        byte[] hash = PairingAuthenticator.transcriptHash(transcript);
        byte[] shared = client.sharedSecret(accepted.getServerPublicKey().toByteArray());
        try (PairingAuthenticator.DerivedSecrets secrets = PairingAuthenticator.deriveSecrets(shared, hash)) {
            assertTrue(approvals.reject(accepted.getPairingId().toByteArray()));
            PairingConfirmRequest confirm = PairingConfirmRequest.newBuilder()
                    .setPairingId(accepted.getPairingId())
                    .setClientApproved(true)
                    .setClientConfirmation(ByteString.copyFrom(PairingAuthenticator.clientConfirmation(
                            secrets.confirmationKey(),
                            hash
                    )))
                    .build();
            PairingConfirmResponse rejected = PairingConfirmResponse.parseFrom(dispatcher.dispatchForTest(
                    request(3, PayloadType.PAYLOAD_TYPE_PAIRING_CONFIRM_REQUEST, confirm.toByteString()).toByteArray(),
                    state,
                    2
            )[0].getPayload());
            assertEquals(ErrorCode.ERROR_CODE_CANCELLED, rejected.getError().getCode());
        } finally {
            Arrays.fill(shared, (byte) 0);
        }
        assertTrue(repository.list().isEmpty());
        assertFalse(approvals.snapshot().windowOpen());
    }

    @Test
    public void repeatedInvalidPairingStartsTriggerBackoffBeforeKeyAgreement() throws Exception {
        PairingApprovalController approvals = new PairingApprovalController();
        InMemoryPairingRepository repository = new InMemoryPairingRepository();
        FakeAuthenticationClock clock = new FakeAuthenticationClock();
        AuthenticationRateLimiter limiter = new AuthenticationRateLimiter(clock);
        RpcDispatcher dispatcher = dispatcher(
                repository,
                approvals,
                new TestDeviceIdentity(),
                limiter
        );
        PairingKeyAgreement client = PairingKeyAgreement.generate();
        assertTrue(approvals.openWindow(60_000));

        PairingStartRequest invalid = PairingStartRequest.newBuilder()
                .setPairingVersion(999)
                .setClientName("Rate Limit Test Mac")
                .setClientPublicKey(ByteString.copyFrom(client.publicKeyX963Representation()))
                .setClientNonce(ByteString.copyFrom(new byte[32]))
                .build();
        for (int attempt = 0;
             attempt < AuthenticationRateLimiter.FIRST_PAIRING_FAILURES_BEFORE_BACKOFF;
             attempt += 1) {
            PairingStartResponse response = PairingStartResponse.parseFrom(
                    dispatcher.dispatchForTest(
                            request(
                                    attempt + 1,
                                    PayloadType.PAYLOAD_TYPE_PAIRING_START_REQUEST,
                                    invalid.toByteString()
                            ).toByteArray(),
                            dispatcher.newSessionStateForTest(),
                            attempt + 1
                    )[0].getPayload()
            );
            assertEquals(ErrorCode.ERROR_CODE_UNSUPPORTED_VERSION, response.getError().getCode());
        }

        PairingStartRequest valid = invalid.toBuilder().setPairingVersion(1).build();
        PairingStartResponse blocked = PairingStartResponse.parseFrom(
                dispatcher.dispatchForTest(
                        request(10, PayloadType.PAYLOAD_TYPE_PAIRING_START_REQUEST, valid.toByteString())
                                .toByteArray(),
                        dispatcher.newSessionStateForTest(),
                        10
                )[0].getPayload()
        );
        assertEquals(ErrorCode.ERROR_CODE_TIMEOUT, blocked.getError().getCode());
        assertFalse(approvals.snapshot().hasPendingAttempt());

        clock.advance(AuthenticationRateLimiter.BASE_BACKOFF_MILLIS);
        PairingStartResponse recovered = PairingStartResponse.parseFrom(
                dispatcher.dispatchForTest(
                        request(11, PayloadType.PAYLOAD_TYPE_PAIRING_START_REQUEST, valid.toByteString())
                                .toByteArray(),
                        dispatcher.newSessionStateForTest(),
                        11
                )[0].getPayload()
        );
        assertEquals(PairingAuthenticator.VERSION, recovered.getPairingVersion());
        assertTrue(approvals.snapshot().hasPendingAttempt());
        approvals.finishAttempt(recovered.getPairingId().toByteArray());
    }

    private static RpcDispatcher dispatcher(
            InMemoryPairingRepository repository,
            PairingApprovalController approvals,
            DeviceIdentityProvider identity
    ) {
        return new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                null,
                null,
                SessionAuthenticationMode.PAIRED_REQUIRED,
                repository,
                repository,
                approvals,
                identity
        );
    }

    private static RpcDispatcher dispatcher(
            InMemoryPairingRepository repository,
            PairingApprovalController approvals,
            DeviceIdentityProvider identity,
            AuthenticationRateLimiter limiter
    ) {
        return new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                null,
                null,
                SessionAuthenticationMode.PAIRED_REQUIRED,
                repository,
                repository,
                approvals,
                identity,
                limiter
        );
    }

    private static RpcEnvelope request(long requestId, PayloadType type, ByteString payload) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(requestId)
                .setPayloadType(type)
                .setPayload(payload)
                .build();
    }

    private static byte[] sequentialBytes(int start, int count) {
        byte[] result = new byte[count];
        for (int index = 0; index < count; index += 1) {
            result[index] = (byte) (start + index);
        }
        return result;
    }

    private static String key(byte[] pairingId) {
        return java.util.Base64.getEncoder().encodeToString(pairingId);
    }

    private static final class InMemoryPairingRepository implements PairingCredentialRepository {
        private final Map<String, PairingCredentialRecord> records = new HashMap<>();

        @Override
        public synchronized void save(PairingCredentialRecord record) {
            records.put(key(record.pairingId()), record);
        }

        @Override
        public synchronized PairingCredentialRecord load(byte[] pairingId) {
            return records.get(key(pairingId));
        }

        @Override
        public synchronized List<PairingCredentialRecord.Metadata> list() {
            List<PairingCredentialRecord.Metadata> result = new ArrayList<>();
            for (PairingCredentialRecord record : records.values()) {
                result.add(record.metadata());
            }
            return result;
        }

        @Override
        public synchronized void revoke(byte[] pairingId) {
            records.remove(key(pairingId));
        }

        @Override
        public synchronized byte[] pairingKey(byte[] pairingId) {
            PairingCredentialRecord record = records.get(key(pairingId));
            return record == null ? null : record.pairingKey();
        }
    }

    private static final class TestDeviceIdentity implements DeviceIdentityProvider {
        private final KeyPair keyPair;

        private TestDeviceIdentity() throws GeneralSecurityException {
            KeyPairGenerator generator = KeyPairGenerator.getInstance("EC");
            generator.initialize(new ECGenParameterSpec("secp256r1"));
            keyPair = generator.generateKeyPair();
        }

        @Override
        public byte[] publicKeyX963Representation() {
            return PairingKeyAgreement.publicKeyX963Representation((ECPublicKey) keyPair.getPublic());
        }

        @Override
        public byte[] fingerprint() {
            return PairingAuthenticator.transcriptHash(publicKeyX963Representation());
        }

        @Override
        public byte[] signPairingTranscript(byte[] transcript) {
            try {
                Signature signer = Signature.getInstance("SHA256withECDSA");
                signer.initSign(keyPair.getPrivate());
                signer.update(transcript);
                return signer.sign();
            } catch (GeneralSecurityException exception) {
                throw new IllegalStateException(exception);
            }
        }
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
}
