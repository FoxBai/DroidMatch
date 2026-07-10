package app.droidmatch.m1;

import app.droidmatch.proto.v1.Capability;

import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Authentication state and provisional secrets for one RPC connection.
 *
 * <p>All transition methods copy caller-owned key material. Every terminal or
 * ready transition clears provisional key/transcript buffers before releasing
 * references.</p>
 */
class RpcSessionState {
    enum Phase {
        AWAITING_HELLO,
        AWAITING_AUTH,
        PAIRING_AWAITING_CONFIRM,
        PAIRING_AWAITING_FINALIZE,
        READY,
        CLOSED
    }

    Phase phase = Phase.AWAITING_HELLO;
    byte[] pairingId;
    byte[] proofKey;
    byte[] transcriptHash;
    boolean pairingRecognized;
    List<Capability> requestedCapabilities = Arrays.asList();
    List<Capability> grantedCapabilities = Arrays.asList();
    byte[] firstPairingId;
    byte[] firstPairingTranscriptHash;
    byte[] firstPairingConfirmationKey;
    byte[] firstPairingKey;
    byte[] firstPairingDeviceFingerprint;
    byte[] firstPairingServerConfirmation;
    String firstPairingClientName;

    void beginAuthentication(
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
        phase = Phase.AWAITING_AUTH;
    }

    void markReadyAndClear(List<Capability> grantedCapabilities) {
        clearProvisionalSecrets();
        this.grantedCapabilities = new ArrayList<>(grantedCapabilities);
        phase = Phase.READY;
    }

    void beginFirstPairing(
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
        phase = Phase.PAIRING_AWAITING_CONFIRM;
    }

    boolean matchesFirstPairingId(byte[] candidate) {
        return firstPairingId != null && MessageDigest.isEqual(firstPairingId, candidate);
    }

    void markFirstPairingConfirmed(byte[] serverConfirmation) {
        firstPairingServerConfirmation = Arrays.copyOf(
                serverConfirmation,
                serverConfirmation.length
        );
        phase = Phase.PAIRING_AWAITING_FINALIZE;
    }

    void closeAndClear() {
        clearProvisionalSecrets();
        grantedCapabilities = Arrays.asList();
        phase = Phase.CLOSED;
    }

    private void clearProvisionalSecrets() {
        clear(proofKey);
        clear(transcriptHash);
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

    private static void clear(byte[] bytes) {
        if (bytes != null) {
            Arrays.fill(bytes, (byte) 0);
        }
    }
}
