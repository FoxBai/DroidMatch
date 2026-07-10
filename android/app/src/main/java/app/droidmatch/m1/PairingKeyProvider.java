package app.droidmatch.m1;

/** Looks up the 32-byte secret for a 16-byte, non-secret pairing identifier. */
public interface PairingKeyProvider {
    /**
     * Returns a defensive copy of the pairing key, or {@code null} when the
     * identifier is unknown. Implementations must never log either value.
     */
    byte[] pairingKey(byte[] pairingId);
}
