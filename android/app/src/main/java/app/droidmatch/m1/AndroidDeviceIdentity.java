package app.droidmatch.m1;

import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import java.security.GeneralSecurityException;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;

/** Stable, non-exportable Android device identity used only inside DroidMatch pairing. */
public final class AndroidDeviceIdentity implements DeviceIdentityProvider {
    private static final String KEY_ALIAS = "app.droidmatch.device.identity.p256.v1";
    private final String keyAlias;

    public AndroidDeviceIdentity() {
        this(KEY_ALIAS);
    }

    AndroidDeviceIdentity(String keyAlias) {
        if (keyAlias == null || keyAlias.isEmpty()) {
            throw new IllegalArgumentException("device identity key alias is required");
        }
        this.keyAlias = keyAlias;
    }

    @Override
    public byte[] publicKeyX963Representation() {
        return PairingKeyAgreement.publicKeyX963Representation(publicKey());
    }

    @Override
    public byte[] fingerprint() {
        return PairingAuthenticator.transcriptHash(publicKeyX963Representation());
    }

    @Override
    public byte[] signPairingTranscript(byte[] transcript) {
        try {
            Signature signer = Signature.getInstance("SHA256withECDSA");
            signer.initSign(privateKey());
            signer.update(transcript);
            return signer.sign();
        } catch (GeneralSecurityException exception) {
            throw new IllegalStateException("could not sign pairing transcript", exception);
        }
    }

    public static boolean verifyPairingTranscriptSignature(
            byte[] publicKeyX963,
            byte[] transcript,
            byte[] signatureDER
    ) {
        try {
            Signature verifier = Signature.getInstance("SHA256withECDSA");
            verifier.initVerify(PairingKeyAgreement.publicKeyFromX963(publicKeyX963));
            verifier.update(transcript);
            return verifier.verify(signatureDER);
        } catch (GeneralSecurityException | IllegalArgumentException exception) {
            return false;
        }
    }

    private ECPublicKey publicKey() {
        return (ECPublicKey) keyPair().getPublic();
    }

    private PrivateKey privateKey() {
        return keyPair().getPrivate();
    }

    private synchronized KeyPair keyPair() {
        try {
            KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
            keyStore.load(null);
            KeyStore.Entry existing = keyStore.getEntry(keyAlias, null);
            if (existing instanceof KeyStore.PrivateKeyEntry) {
                KeyStore.PrivateKeyEntry entry = (KeyStore.PrivateKeyEntry) existing;
                return new KeyPair(entry.getCertificate().getPublicKey(), entry.getPrivateKey());
            }

            KeyPairGenerator generator = KeyPairGenerator.getInstance(
                    KeyProperties.KEY_ALGORITHM_EC,
                    "AndroidKeyStore"
            );
            generator.initialize(new KeyGenParameterSpec.Builder(
                    keyAlias,
                    KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY
            )
                    .setAlgorithmParameterSpec(new ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .setUserAuthenticationRequired(false)
                    .build());
            return generator.generateKeyPair();
        } catch (Exception exception) {
            throw new IllegalStateException("Android device identity is unavailable", exception);
        }
    }
}
