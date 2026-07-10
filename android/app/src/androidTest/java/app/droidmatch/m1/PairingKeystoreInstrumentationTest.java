package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import android.content.Context;
import android.content.SharedPreferences;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import java.nio.charset.StandardCharsets;
import java.security.Key;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.util.Arrays;

import javax.crypto.SecretKey;

import org.junit.Test;
import org.junit.runner.RunWith;

/**
 * Physical/emulated-device evidence for the AndroidKeyStore adapters.
 *
 * <p>Every test uses unique aliases and preferences, then removes them in a
 * finally block. It never touches the product aliases or an existing pairing
 * record. CI compiles this class but does not claim device evidence until an
 * operator explicitly runs {@code connectedDebugAndroidTest}.</p>
 */
@RunWith(AndroidJUnit4.class)
public final class PairingKeystoreInstrumentationTest {
    @Test
    public void testDeviceIdentityIsStableNonExportableAndSignsTranscript() throws Exception {
        String alias = unique("app.droidmatch.test.identity.");
        try {
            AndroidDeviceIdentity first = new AndroidDeviceIdentity(alias);
            byte[] publicKey = first.publicKeyX963Representation();
            byte[] fingerprint = first.fingerprint();
            byte[] transcript = "DroidMatch instrumentation identity transcript"
                    .getBytes(StandardCharsets.UTF_8);
            byte[] signature = first.signPairingTranscript(transcript);

            assertEquals(PairingAuthenticator.PUBLIC_KEY_LENGTH, publicKey.length);
            assertTrue(AndroidDeviceIdentity.verifyPairingTranscriptSignature(
                    publicKey,
                    transcript,
                    signature
            ));
            byte[] tampered = Arrays.copyOf(transcript, transcript.length);
            tampered[0] ^= 0x01;
            assertFalse(AndroidDeviceIdentity.verifyPairingTranscriptSignature(
                    publicKey,
                    tampered,
                    signature
            ));
            assertTrue(Arrays.equals(
                    PairingAuthenticator.transcriptHash(publicKey),
                    fingerprint
            ));

            AndroidDeviceIdentity reopened = new AndroidDeviceIdentity(alias);
            assertTrue(Arrays.equals(publicKey, reopened.publicKeyX963Representation()));

            KeyStore keyStore = androidKeyStore();
            KeyStore.Entry entry = keyStore.getEntry(alias, null);
            assertTrue(entry instanceof KeyStore.PrivateKeyEntry);
            PrivateKey privateKey = ((KeyStore.PrivateKeyEntry) entry).getPrivateKey();
            assertNull(privateKey.getEncoded());
        } finally {
            deleteKey(alias);
        }
    }

    @Test
    public void testPairingCredentialRoundTripsThroughNonExportableWrappingKey() throws Exception {
        String suffix = Long.toUnsignedString(System.nanoTime());
        String preferencesName = "droidmatch_test_pairing_" + suffix;
        String alias = "app.droidmatch.test.wrap." + suffix;
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        SharedPreferences preferences = context.getSharedPreferences(
                preferencesName,
                Context.MODE_PRIVATE
        );
        byte[] pairingId = sequentialBytes(0x10, PairingAuthenticator.PAIRING_ID_LENGTH);
        byte[] fingerprint = sequentialBytes(0x40, PairingAuthenticator.DIGEST_LENGTH);
        byte[] pairingKey = sequentialBytes(0x70, PairingAuthenticator.KEY_LENGTH);

        try {
            AndroidPairingCredentialStore store = new AndroidPairingCredentialStore(
                    context,
                    preferencesName,
                    alias
            );
            store.save(new PairingCredentialRecord(
                    pairingId,
                    fingerprint,
                    pairingKey,
                    "Instrumentation Mac",
                    1L,
                    2L
            ));
            assertTrue(Arrays.equals(pairingKey, store.pairingKey(pairingId)));
            assertEquals(1, store.list().size());
            assertTrue(preferences.getAll().size() == 1);

            AndroidPairingCredentialStore reopened = new AndroidPairingCredentialStore(
                    context,
                    preferencesName,
                    alias
            );
            PairingCredentialRecord loaded = reopened.load(pairingId);
            assertNotNull(loaded);
            assertTrue(Arrays.equals(fingerprint, loaded.deviceIdentityFingerprint()));
            assertTrue(Arrays.equals(pairingKey, loaded.pairingKey()));

            Key key = androidKeyStore().getKey(alias, null);
            assertTrue(key instanceof SecretKey);
            assertNull(key.getEncoded());

            reopened.revoke(pairingId);
            assertNull(reopened.load(pairingId));
        } finally {
            preferences.edit().clear().commit();
            deleteKey(alias);
            Arrays.fill(pairingKey, (byte) 0);
        }
    }

    private static byte[] sequentialBytes(int start, int length) {
        byte[] result = new byte[length];
        for (int index = 0; index < length; index += 1) {
            result[index] = (byte) (start + index);
        }
        return result;
    }

    private static String unique(String prefix) {
        return prefix + Long.toUnsignedString(System.nanoTime());
    }

    private static KeyStore androidKeyStore() throws Exception {
        KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
        keyStore.load(null);
        return keyStore;
    }

    private static void deleteKey(String alias) throws Exception {
        KeyStore keyStore = androidKeyStore();
        if (keyStore.containsAlias(alias)) {
            keyStore.deleteEntry(alias);
        }
    }
}
