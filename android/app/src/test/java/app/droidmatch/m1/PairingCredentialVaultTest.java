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
import javax.crypto.AEADBadTagException;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

import org.junit.Test;

public final class PairingCredentialVaultTest {
    @Test
    public void encryptsLoadsListsUpdatesAndRevokesRecord() {
        InMemoryBackend backend = new InMemoryBackend();
        TestAesGcmProtector protector = new TestAesGcmProtector();
        PairingCredentialVault vault = new PairingCredentialVault(backend, protector);
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
        assertTrue(protector.lastAllowKeyCreation);
        assertEquals(1, backend.revision(pairingId));
        assertArrayEquals(pairingKey, vault.load(pairingId).pairingKey());
        assertArrayEquals(pairingKey, vault.pairingKey(pairingId));
        assertFalse(containsSequence(backend.firstDecodedValue(), pairingKey));

        // Records written before revision binding read as revision zero and migrate
        // atomically on their first subsequent mutation.
        backend.clearRevision(pairingId);
        assertEquals(0, backend.revision(pairingId));

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
        assertFalse(protector.lastAllowKeyCreation);
        assertEquals(1, backend.revision(pairingId));
        assertEquals("Renamed Pixel", vault.list().get(0).displayName());
        assertEquals(300, vault.list().get(0).lastUsedAtUnixMillis());

        vault.markUsed(pairingId, 400);
        assertEquals(400, vault.list().get(0).lastUsedAtUnixMillis());
        vault.markUsed(pairingId, 350);
        assertEquals(400, vault.list().get(0).lastUsedAtUnixMillis());

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

    @Test
    public void listsVerifiedRecordBesideMalformedRecordAndConfirmsCleanup() {
        InMemoryBackend backend = new InMemoryBackend();
        PairingCredentialVault vault = new PairingCredentialVault(backend, new TestAesGcmProtector());
        byte[] healthyId = sequentialBytes(0x10, 16);
        byte[] damagedId = sequentialBytes(0x70, 16);
        vault.save(record(healthyId, "Healthy Mac"));
        backend.put(recordKey(damagedId), "not-base64");

        PairingCredentialVault.Catalog catalog = vault.catalog();
        assertFalse(catalog.isComplete());
        assertEquals(1, catalog.metadata().size());
        assertEquals("Healthy Mac", catalog.metadata().get(0).displayName());
        assertEquals(1, catalog.damagedRecords().size());
        try {
            vault.list();
            fail("expected legacy list to fail closed on an incomplete catalog");
        } catch (IllegalStateException expected) {
            assertTrue(expected.getMessage().contains("catalog is incomplete"));
        }

        backend.retainOnRemove = true;
        try {
            vault.removeDamaged(catalog.damagedRecords().get(0));
            fail("expected cleanup confirmation failure");
        } catch (IllegalStateException expected) {
            assertTrue(expected.getMessage().contains("changed before removal"));
        }
        backend.retainOnRemove = false;
        vault.removeDamaged(catalog.damagedRecords().get(0));
        assertTrue(vault.catalog().isComplete());

        StringBuilder oversized = new StringBuilder();
        for (int index = 0; index < 1_024; index += 1) {
            oversized.append('A');
        }
        backend.put(recordKey(damagedId), oversized.toString());
        try {
            vault.load(damagedId);
            fail("expected pre-decode encoded-size rejection");
        } catch (PairingCredentialVault.MalformedRecordException expected) {
            assertTrue(expected.getCause().getMessage().contains("encoded size limit"));
        }
        PairingCredentialVault.Catalog oversizedCatalog = vault.catalog();
        assertFalse(oversizedCatalog.isComplete());
        assertEquals(1, oversizedCatalog.damagedRecords().size());
        vault.removeDamaged(oversizedCatalog.damagedRecords().get(0));
        assertTrue(vault.catalog().isComplete());
    }

    @Test
    public void damagedTokenRejectsChangedHealthyAndRecreatedAbaRecord() {
        InMemoryBackend backend = new InMemoryBackend();
        PairingCredentialVault vault = new PairingCredentialVault(backend, new TestAesGcmProtector());
        byte[] damagedId = sequentialBytes(0x70, 16);
        String originalDamagedValue = "not-base64";
        backend.put(recordKey(damagedId), originalDamagedValue);
        PairingCredentialVault.DamagedRecord stale = vault.catalog().damagedRecords().get(0);

        backend.put(recordKey(damagedId), "different-malformed-value");
        backend.put(recordKey(damagedId), originalDamagedValue);
        try {
            vault.removeDamaged(stale);
            fail("expected exact-value ABA rejection");
        } catch (IllegalStateException expected) {
            assertTrue(expected.getMessage().contains("changed before removal"));
        }
        assertEquals(originalDamagedValue, backend.get(recordKey(damagedId)));

        PairingCredentialVault.DamagedRecord beforeHealthyRebuild =
                vault.catalog().damagedRecords().get(0);
        vault.revoke(damagedId);
        vault.save(record(damagedId, "Healthy replacement"));
        try {
            vault.removeDamaged(beforeHealthyRebuild);
            fail("expected stale damaged token rejection");
        } catch (IllegalStateException expected) {
            assertTrue(expected.getMessage().contains("changed before removal"));
        }
        assertEquals("Healthy replacement", vault.load(damagedId).displayName());
    }

    @Test
    public void classifiesTagFailureOnlyAfterAnotherRecordAuthenticates() {
        InMemoryBackend backend = new InMemoryBackend();
        PairingCredentialVault vault = new PairingCredentialVault(backend, new TestAesGcmProtector());
        byte[] healthyId = sequentialBytes(0x10, 16);
        byte[] damagedId = sequentialBytes(0x70, 16);
        vault.save(record(healthyId, "Healthy Mac"));
        vault.save(record(damagedId, "Untrusted payload name"));
        backend.tamperValue(damagedId);

        PairingCredentialVault.Catalog catalog = vault.catalog();
        assertFalse(catalog.isComplete());
        assertEquals(1, catalog.metadata().size());
        assertEquals("Healthy Mac", catalog.metadata().get(0).displayName());
        assertEquals(1, catalog.damagedRecords().size());

        InMemoryBackend ambiguousBackend = new InMemoryBackend();
        PairingCredentialVault ambiguous = new PairingCredentialVault(
                ambiguousBackend,
                new TestAesGcmProtector()
        );
        ambiguous.save(record(damagedId, "Must stay hidden"));
        ambiguousBackend.tamperValue(damagedId);
        try {
            ambiguous.catalog();
            fail("expected vault-wide authentication uncertainty");
        } catch (IllegalStateException expected) {
            assertTrue(expected.getMessage().contains("vault authentication is unavailable"));
        }
        assertNull(ambiguous.pairingKey(damagedId));
    }

    @Test
    public void tagFailureTokenExpiresWhenItsHealthyWitnessIsRemoved() {
        InMemoryBackend backend = new InMemoryBackend();
        PairingCredentialVault vault = new PairingCredentialVault(backend, new TestAesGcmProtector());
        byte[] healthyId = sequentialBytes(0x10, 16);
        byte[] damagedId = sequentialBytes(0x70, 16);
        vault.save(record(healthyId, "Healthy witness"));
        vault.save(record(damagedId, "Authenticated only before tamper"));
        backend.tamperValue(damagedId);
        PairingCredentialVault.DamagedRecord token = vault.catalog().damagedRecords().get(0);

        vault.revoke(healthyId);
        try {
            vault.removeDamaged(token);
            fail("expected vault-wide ambiguity after healthy witness removal");
        } catch (IllegalStateException expected) {
            assertTrue(expected.getMessage().contains("vault authentication is unavailable"));
        }
        assertTrue(backend.get(recordKey(damagedId)) != null);
    }

    @Test
    public void invalidBackendIdentityOrRevisionHasNoCleanupCapability() {
        InMemoryBackend backend = new InMemoryBackend();
        PairingCredentialVault vault = new PairingCredentialVault(backend, new TestAesGcmProtector());
        byte[] healthyId = sequentialBytes(0x10, 16);
        vault.save(record(healthyId, "Healthy Mac"));
        backend.put("record.not-an-exact-pairing-id", "not-base64");

        PairingCredentialVault.Catalog catalog = vault.catalog();
        assertFalse(catalog.isComplete());
        assertEquals(1, catalog.metadata().size());
        assertTrue(catalog.damagedRecords().isEmpty());

        backend.setRevision(healthyId, "not-a-long");
        PairingCredentialVault.Catalog malformedRevision = vault.catalog();
        assertFalse(malformedRevision.isComplete());
        assertTrue(malformedRevision.metadata().isEmpty());
        assertTrue(malformedRevision.damagedRecords().isEmpty());
        try {
            vault.load(healthyId);
            fail("expected malformed revision to fail closed");
        } catch (PairingCredentialVault.MalformedRecordException expected) {
            // An untrusted revision never produces metadata or a cleanup token.
        }

        backend.setRevision(healthyId, Long.MAX_VALUE - 1);
        PairingCredentialVault.Catalog exhaustedRevision = vault.catalog();
        assertFalse(exhaustedRevision.isComplete());
        assertTrue(exhaustedRevision.metadata().isEmpty());
        assertTrue(exhaustedRevision.damagedRecords().isEmpty());
    }

    private static PairingCredentialRecord record(byte[] pairingId, String displayName) {
        return new PairingCredentialRecord(
                pairingId,
                sequentialBytes(0x20, 32),
                sequentialBytes(0x40, 32),
                displayName,
                100,
                200
        );
    }

    private static String recordKey(byte[] pairingId) {
        StringBuilder result = new StringBuilder("record.");
        for (byte value : pairingId) {
            result.append(String.format(java.util.Locale.ROOT, "%02x", value & 0xff));
        }
        return result.toString();
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
        private final Map<String, Object> revisions = new HashMap<>();
        private boolean retainOnRemove;

        @Override
        public synchronized PairingCredentialVault.RecordSnapshot snapshot(String key) {
            Object revisionValue = revisions.get(key);
            long revision = 0;
            if (revisionValue != null) {
                if (!(revisionValue instanceof Long)
                        || (Long) revisionValue <= 0
                        || (Long) revisionValue >= Long.MAX_VALUE - 1) {
                    throw new PairingCredentialVault.MalformedRecordException(
                            new IllegalStateException("pairing record revision is invalid")
                    );
                }
                revision = (Long) revisionValue;
            }
            return new PairingCredentialVault.RecordSnapshot(values.get(key), revision);
        }

        @Override
        public synchronized void put(String key, String value) {
            long nextRevision = nextRevision(snapshot(key).revision());
            values.put(key, value);
            revisions.put(key, nextRevision);
        }

        @Override
        public synchronized void remove(String key) {
            if (!retainOnRemove) {
                long nextRevision = nextRevision(snapshot(key).revision());
                values.remove(key);
                revisions.put(key, nextRevision);
            }
        }

        @Override
        public synchronized List<String> keys() {
            return new ArrayList<>(values.keySet());
        }

        @Override
        public synchronized boolean removeIfUnchanged(
                String key,
                String expectedValue,
                long expectedRevision
        ) {
            PairingCredentialVault.RecordSnapshot current = snapshot(key);
            if (!expectedValue.equals(current.value())
                    || expectedRevision != current.revision()
                    || retainOnRemove) {
                return false;
            }
            long nextRevision = nextRevision(current.revision());
            values.remove(key);
            revisions.put(key, nextRevision);
            return true;
        }

        private static long nextRevision(long revision) {
            if (revision >= Long.MAX_VALUE - 1) {
                throw new PairingCredentialVault.MalformedRecordException(
                        new IllegalStateException("pairing record revision is exhausted")
                );
            }
            return revision + 1;
        }

        private synchronized long revision(byte[] pairingId) {
            return snapshot(recordKey(pairingId)).revision();
        }

        private synchronized void clearRevision(byte[] pairingId) {
            revisions.remove(recordKey(pairingId));
        }

        private synchronized void setRevision(byte[] pairingId, Object revision) {
            revisions.put(recordKey(pairingId), revision);
        }

        private byte[] firstDecodedValue() {
            return Base64.getDecoder().decode(values.values().iterator().next());
        }

        private synchronized void tamperFirstValue() {
            String key = values.keySet().iterator().next();
            byte[] bytes = Base64.getDecoder().decode(values.get(key));
            bytes[bytes.length - 1] ^= 0x01;
            values.put(key, Base64.getEncoder().encodeToString(bytes));
        }

        private synchronized void tamperValue(byte[] pairingId) {
            String key = recordKey(pairingId);
            byte[] bytes = Base64.getDecoder().decode(values.get(key));
            bytes[bytes.length - 1] ^= 0x01;
            values.put(key, Base64.getEncoder().encodeToString(bytes));
        }
    }

    private static final class TestAesGcmProtector implements PairingCredentialVault.KeyProtector {
        private final SecretKey key = new SecretKeySpec(new byte[32], "AES");
        private int nonce;
        private boolean lastAllowKeyCreation;

        @Override
        public PairingCredentialVault.EncryptedKey encrypt(
                byte[] plaintext,
                byte[] aad,
                boolean allowKeyCreation
        ) {
            lastAllowKeyCreation = allowKeyCreation;
            return encrypt(plaintext, aad);
        }

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
            } catch (AEADBadTagException exception) {
                throw new PairingCredentialVault.RecordAuthenticationException(exception);
            } catch (GeneralSecurityException exception) {
                throw new IllegalStateException(exception);
            }
        }
    }
}
