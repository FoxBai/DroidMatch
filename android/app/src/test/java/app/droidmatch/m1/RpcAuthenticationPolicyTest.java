package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.PayloadType;

import java.util.Arrays;
import java.util.Collections;

import org.junit.Test;

public final class RpcAuthenticationPolicyTest {
    @Test
    public void capabilityGrantUsesServerOrderAndIgnoresUnsupportedValues() {
        assertEquals(
                Arrays.asList(
                        Capability.CAPABILITY_FILE_READ,
                        Capability.CAPABILITY_DIAGNOSTICS
                ),
                RpcAuthenticationPolicy.grantCapabilities(Arrays.asList(
                        Capability.CAPABILITY_DIAGNOSTICS,
                        Capability.UNRECOGNIZED,
                        Capability.CAPABILITY_FILE_READ,
                        Capability.CAPABILITY_FILE_READ
                ))
        );
        assertEquals(Collections.emptyList(), RpcAuthenticationPolicy.grantCapabilities(
                Collections.singletonList(Capability.CAPABILITY_UNSPECIFIED)
        ));
    }

    @Test
    public void nonceAndPairingPayloadBoundsAreExplicit() {
        assertFalse(RpcAuthenticationPolicy.isSessionNonceLengthAllowed(15));
        assertTrue(RpcAuthenticationPolicy.isSessionNonceLengthAllowed(16));
        assertTrue(RpcAuthenticationPolicy.isSessionNonceLengthAllowed(32));
        assertFalse(RpcAuthenticationPolicy.isSessionNonceLengthAllowed(33));

        assertTrue(RpcAuthenticationPolicy.isPairingPayload(
                PayloadType.PAYLOAD_TYPE_PAIRING_START_REQUEST
        ));
        assertTrue(RpcAuthenticationPolicy.isPairingPayload(
                PayloadType.PAYLOAD_TYPE_PAIRING_FINALIZE_RESPONSE
        ));
        assertFalse(RpcAuthenticationPolicy.isPairingPayload(PayloadType.PAYLOAD_TYPE_CLIENT_HELLO));
    }
}
