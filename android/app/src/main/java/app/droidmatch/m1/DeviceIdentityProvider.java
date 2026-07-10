package app.droidmatch.m1;

/** Stable local device identity used to bind and sign first-pairing transcripts. */
public interface DeviceIdentityProvider {
    byte[] publicKeyX963Representation();
    byte[] fingerprint();
    byte[] signPairingTranscript(byte[] transcript);
}
