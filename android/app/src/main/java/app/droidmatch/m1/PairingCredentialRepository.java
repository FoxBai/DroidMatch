package app.droidmatch.m1;

import java.util.List;

/** Storage contract used by first pairing and reconnect authentication. */
public interface PairingCredentialRepository extends PairingKeyProvider {
    void save(PairingCredentialRecord record);
    PairingCredentialRecord load(byte[] pairingId);
    List<PairingCredentialRecord.Metadata> list();
    void revoke(byte[] pairingId);
}
