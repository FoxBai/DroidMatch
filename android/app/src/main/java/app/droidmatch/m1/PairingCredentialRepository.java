package app.droidmatch.m1;

import java.util.List;

/** Storage contract used by first pairing and reconnect authentication. */
public interface PairingCredentialRepository extends PairingKeyProvider {
    void save(PairingCredentialRecord record);
    PairingCredentialRecord load(byte[] pairingId);
    List<PairingCredentialRecord.Metadata> list();
    void revoke(byte[] pairingId);

    /** Records a successful reconnect; repositories may keep older timestamps on clock rollback. */
    default void markUsed(byte[] pairingId, long lastUsedAtUnixMillis) {
        // Optional for non-persistent harness repositories.
    }
}
