package app.droidmatch.m1;

import static org.junit.Assert.*;
import static app.droidmatch.m1.RpcDispatcherTestFixtures.*;
import app.droidmatch.proto.v1.AuthenticateSessionResponse;
import app.droidmatch.proto.v1.AuthenticationState;
import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.ListApplicationsResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.ServerHello;
import app.droidmatch.proto.v1.TransportKind;
import java.util.Arrays;
import org.junit.Test;

public final class ApplicationRpcAuthorizationTest {
    @Test public void onlyPairedProofAndLiveSharingAdmitApplicationQueries() throws Exception {
        byte[] id = sequentialBytes(0x10, 16), key = sequentialBytes(0x20, 32);
        byte[] nonce = sequentialBytes(0x30, 32);
        ApplicationListProviderTest.Catalog catalog = new ApplicationListProviderTest.Catalog();
        PairingKeyProvider keys = candidate -> Arrays.equals(candidate, id) ? key.clone() : null;
        RpcDispatcher correlated = dispatcher(SessionAuthenticationMode.NONCE_ONLY, keys, catalog);
        RpcDispatcher.SessionState correlatedState = new RpcDispatcher.SessionState();
        ServerHello plainHello = ServerHello.parseFrom(correlated.dispatchForTest(
                clientHelloEnvelope(1, nonce, new byte[0], Capability.CAPABILITY_APPLICATION_LIST)
                        .toByteArray(), correlatedState, 1)[0].getPayload());
        assertEquals(AuthenticationState.AUTHENTICATION_STATE_CORRELATED, plainHello.getAuthenticationState());
        assertFalse(plainHello.getGrantedCapabilitiesList().contains(Capability.CAPABILITY_APPLICATION_LIST));

        RpcDispatcher paired = dispatcher(SessionAuthenticationMode.PAIRED_REQUIRED, keys, catalog);
        RpcDispatcher.SessionState state = new RpcDispatcher.SessionState();
        ServerHello challenge = ServerHello.parseFrom(paired.dispatchForTest(
                clientHelloEnvelope(1, nonce, id, Capability.CAPABILITY_APPLICATION_LIST).toByteArray(),
                state, 2)[0].getPayload());
        assertEquals(0, challenge.getGrantedCapabilitiesCount());
        byte[] hash = SessionAuthenticator.transcriptHash(SessionAuthenticator.transcript(
                id, nonce, challenge.getServerNonce().toByteArray(), 1, 0,
                TransportKind.TRANSPORT_KIND_ADB.getNumber()));
        AuthenticateSessionResponse proof = AuthenticateSessionResponse.parseFrom(paired.dispatchForTest(
                authenticationEnvelope(2, id, SessionAuthenticator.clientProof(key, hash)).toByteArray(),
                state, 2)[0].getPayload());
        assertTrue(proof.getAuthenticated());
        assertTrue(proof.getGrantedCapabilitiesList().contains(Capability.CAPABILITY_APPLICATION_LIST));
        ListApplicationsResponse denied = ListApplicationsResponse.parseFrom(
                paired.dispatchForTest(list(3).toByteArray(), state, 2)[0].getPayload());
        assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, denied.getError().getCode());
        assertEquals(0, catalog.queries);
        catalog.access.setEnabled(true);
        RpcEnvelope response = paired.dispatchForTest(list(4).toByteArray(), state, 2)[0];
        assertEquals(4, response.getRequestId());
        assertEquals(PayloadType.PAYLOAD_TYPE_LIST_APPLICATIONS_RESPONSE, response.getPayloadType());
        assertEquals(2, ListApplicationsResponse.parseFrom(response.getPayload()).getEntriesCount());
        RpcEnvelope nonceDenied = correlated.dispatchForTest(list(5).toByteArray(), correlatedState, 1)[0];
        assertEquals(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, nonceDenied.getError().getCode());
        assertEquals(1, catalog.queries);
        catalog.access.setEnabled(false);
        assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, ListApplicationsResponse.parseFrom(
                paired.dispatchForTest(list(6).toByteArray(), state, 2)[0].getPayload()).getError().getCode());
        assertEquals(1, catalog.queries);
    }

    private static RpcDispatcher dispatcher(SessionAuthenticationMode mode, PairingKeyProvider keys,
            ApplicationCatalog catalog) {
        return new RpcDispatcher(new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null, null, null, mode, keys, null, null, testDeviceIdentity(), catalog);
    }

    private static RpcEnvelope list(long id) {
        return RpcEnvelope.newBuilder().setFrameVersion(1).setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(id).setPayloadType(PayloadType.PAYLOAD_TYPE_LIST_APPLICATIONS_REQUEST)
                .setPayload(ApplicationListProviderTest.request().toByteString()).build();
    }
}
