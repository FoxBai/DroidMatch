package app.droidmatch.m1;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.security.GeneralSecurityException;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import javax.crypto.Cipher;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

import org.junit.Test;

public final class PairingCredentialVaultTest {
    @Test
    public void encryptsLoadsListsUpdatesAndRevokesRecord() {
        InMemoryBackend backend = new InMemoryBackend();
        PairingCredentialVault vault = new PairingCredentialVault(backend, new TestAesGcmProtector());
        byte[] pairingId = sequentialBytes(0xa0, 16);
        byte[] fingerprint = sequentialBytes(0x20, 32);
        byte[] pairingKey = sequentialBytes(0x40, 32);
        PairingCredentialRecord record = new PairingCredentialRecord(
                pairingId,
                fingerprint,
                pairingKey,
                "Pixel Test",
                100,
                200
        );

        vault.save(record);
        assertArrayEquals(pairingKey, vault.load(pairingId).pairingKey());
        assertArrayEquals(pairingKey, vault.pairingKey(pairingId));
        assertFalse(containsSequence(backend.firstDecodedValue(), pairingKey));

        List<PairingCredentialRecord.Metadata> metadata = vault.list();
        assertEquals(1, metadata.size());
        assertEquals("Pixel Test", metadata.get(0).displayName());
        assertEquals(200, metadata.get(0).lastUsedAtUnixMillis());

        vault.save(new PairingCredentialRecord(
                pairingId,
                fingerprint,
                sequentialBytes(0x60, 32),
                "Renamed Pixel",
                100,
                300
        ));
        assertEquals("Renamed Pixel", vault.list().get(0).displayName());
        assertEquals(300, vault.list().get(0).lastUsedAtUnixMillis());

        vault.revoke(pairingId);
        assertNull(vault.load(pairingId));
        assertTrue(vault.list().isEmpty());
    }

    @Test
    public void rejectsIdentityCollisionAndTreatsTamperAsUnknownPairing() {
        InMemoryBackend backend = new InMemoryBackend();
        PairingCredentialVault vault = new PairingCredentialVault(backend, new TestAesGcmProtector());
        byte[] pairingId = sequentialBytes(0xa0, 16);
        vault.save(new PairingCredentialRecord(
                pairingId,
                sequentialBytes(0x20, 32),
                sequentialBytes(0x40, 32),
                "First",
                100,
                200
        ));

        try {
            vault.save(new PairingCredentialRecord(
                    pairingId,
                    sequentialBytes(0x30, 32),
                    sequentialBytes(0x50, 32),
                    "Collision",
                    100,
                    200
            ));
            fail("expected pairing ID/device identity collision");
        } catch (IllegalArgumentException expected) {
            // Expected: a pairing ID can never be silently rebound to another device identity.
        }

        backend.tamperFirstValue();
        assertNull(vault.pairingKey(pairingId));
        try {
            vault.load(pairingId);
            fail("expected authenticated ciphertext failure");
        } catch (IllegalStateException expected) {
            // Expected: AES-GCM tag or record decoding detects storage tampering.
        }
    }

    private static boolean containsSequence(byte[] haystack, byte[] needle) {
        for (int start = 0; start <= haystack.length - needle.length; start += 1) {
            boolean matches = true;
            for (int index = 0; index < needle.length; index += 1) {
                if (haystack[start + index] != needle[index]) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                return true;
            }
        }
        return false;
    }

    private static byte[] sequentialBytes(int start, int count) {
        byte[] result = new byte[count];
        for (int index = 0; index < count; index += 1) {
            result[index] = (byte) (start + index);
        }
        return result;
    }

    private static final class InMemoryBackend implements PairingCredentialVault.RecordBackend {
        private final Map<String, String> values = new HashMap<>();

        @Override
        public String get(String key) {
            return values.get(key);
        }

        @Override
        public void put(String key, String value) {
            values.put(key, value);
        }

        @Override
        public void remove(String key) {
            values.remove(key);
        }

        @Override
        public List<String> keys() {
            return new ArrayList<>(values.keySet());
        }

        private byte[] firstDecodedValue() {
            return Base64.getDecoder().decode(values.values().iterator().next());
        }

        private void tamperFirstValue() {
            String key = values.keySet().iterator().next();
            byte[] bytes = Base64.getDecoder().decode(values.get(key));
            bytes[bytes.length - 1] ^= 0x01;
            values.put(key, Base64.getEncoder().encodeToString(bytes));
        }
    }

    private static final class TestAesGcmProtector implements PairingCredentialVault.KeyProtector {
        private final SecretKey key = new SecretKeySpec(new byte[32], "AES");
        private int nonce;

        @Override
        public PairingCredentialVault.EncryptedKey encrypt(byte[] plaintext, byte[] aad) {
            try {
                byte[] iv = new byte[12];
                iv[iv.length - 1] = (byte) (++nonce);
                Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
                cipher.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(128, iv));
                cipher.updateAAD(aad);
                return new PairingCredentialVault.EncryptedKey(iv, cipher.doFinal(plaintext));
            } catch (GeneralSecurityException exception) {
                throw new IllegalStateException(exception);
            }
        }

        @Override
        public byte[] decrypt(PairingCredentialVault.EncryptedKey encrypted, byte[] aad) {
            try {
                Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
                cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, encrypted.iv()));
                cipher.updateAAD(aad);
                return cipher.doFinal(encrypted.ciphertext());
            } catch (GeneralSecurityException exception) {
                throw new IllegalStateException(exception);
            }
        }
    }
}
