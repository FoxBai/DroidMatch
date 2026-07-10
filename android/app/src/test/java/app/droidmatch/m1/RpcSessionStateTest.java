package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotSame;
import static org.junit.Assert.assertNull;

import app.droidmatch.proto.v1.Capability;

import java.util.Arrays;

import org.junit.Test;

public final class RpcSessionStateTest {
    @Test
    public void readyTransitionCopiesAndZeroesReconnectSecrets() {
        byte[] pairingId = filled(16, 0x11);
        byte[] proofKey = filled(32, 0x22);
        byte[] transcriptHash = filled(32, 0x33);
        RpcSessionState state = new RpcSessionState();

        state.beginAuthentication(
                pairingId,
                proofKey,
                transcriptHash,
                true,
                Arrays.asList(Capability.CAPABILITY_FILE_READ)
        );

        assertNotSame(proofKey, state.proofKey);
        assertNotSame(transcriptHash, state.transcriptHash);
        byte[] ownedProofKey = state.proofKey;
        byte[] ownedTranscriptHash = state.transcriptHash;
        proofKey[0] = 0x44;
        transcriptHash[0] = 0x55;
        assertEquals(0x22, ownedProofKey[0]);
        assertEquals(0x33, ownedTranscriptHash[0]);

        state.markReadyAndClear(Arrays.asList(Capability.CAPABILITY_FILE_READ));

        assertZeroed(ownedProofKey);
        assertZeroed(ownedTranscriptHash);
        assertNull(state.proofKey);
        assertNull(state.transcriptHash);
        assertEquals(RpcSessionState.Phase.READY, state.phase);
        assertEquals(Arrays.asList(Capability.CAPABILITY_FILE_READ), state.grantedCapabilities);
    }

    @Test
    public void closedTransitionZeroesEveryFirstPairingSecret() {
        RpcSessionState state = new RpcSessionState();
        state.beginFirstPairing(
                filled(16, 0x10),
                filled(32, 0x20),
                filled(32, 0x30),
                filled(32, 0x40),
                filled(32, 0x50),
                "DroidMatch Mac"
        );
        state.markFirstPairingConfirmed(filled(32, 0x60));

        byte[] pairingId = state.firstPairingId;
        byte[] transcriptHash = state.firstPairingTranscriptHash;
        byte[] confirmationKey = state.firstPairingConfirmationKey;
        byte[] pairingKey = state.firstPairingKey;
        byte[] fingerprint = state.firstPairingDeviceFingerprint;
        byte[] serverConfirmation = state.firstPairingServerConfirmation;

        state.closeAndClear();

        assertZeroed(pairingId);
        assertZeroed(transcriptHash);
        assertZeroed(confirmationKey);
        assertZeroed(pairingKey);
        assertZeroed(fingerprint);
        assertZeroed(serverConfirmation);
        assertNull(state.firstPairingKey);
        assertNull(state.firstPairingServerConfirmation);
        assertNull(state.firstPairingClientName);
        assertEquals(RpcSessionState.Phase.CLOSED, state.phase);
    }

    private static byte[] filled(int count, int value) {
        byte[] bytes = new byte[count];
        Arrays.fill(bytes, (byte) value);
        return bytes;
    }

    private static void assertZeroed(byte[] bytes) {
        for (byte value : bytes) {
            assertEquals(0, value);
        }
    }
}
