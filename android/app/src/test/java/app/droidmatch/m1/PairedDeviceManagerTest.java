package app.droidmatch.m1;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.HashMap;
import java.util.Map;

public final class PairedDeviceManagerTest {
    @Test
    public void listsSecretFreeMetadataAndRevocationClosesTrustBoundary() {
        byte[] pairingId = bytes(PairingAuthenticator.PAIRING_ID_LENGTH, (byte) 0x11);
        String storedDisplayName = " \u202eCafe\u0301\n\u200bMac\u2069 ";
        RepositoryProbe repository = new RepositoryProbe(new PairingCredentialRecord(
                pairingId,
                bytes(PairingAuthenticator.DIGEST_LENGTH, (byte) 0x22),
                bytes(PairingAuthenticator.KEY_LENGTH, (byte) 0x33),
                storedDisplayName,
                100,
                200
        ));
        ArrayList<String> events = repository.events;
        PairedDeviceManager manager = new PairedDeviceManager(
                repository,
                () -> events.add("close")
        );

        List<PairedDeviceManager.Device> devices = manager.devices();
        assertEquals(1, devices.size());
        assertEquals("Caf\u00e9 Mac", devices.get(0).displayName);
        assertEquals(200, devices.get(0).lastUsedAtUnixMillis);
        assertEquals(storedDisplayName, repository.records.get(0).displayName());
        byte[] exposedCopy = devices.get(0).pairingId();
        exposedCopy[0] = 0x7f;

        manager.revoke(devices.get(0));
        assertArrayEquals(pairingId, repository.revokedPairingId);
        assertEquals(Arrays.asList("catalog", "close", "revoke"), events);
    }

    @Test
    public void credentialDeletionFailureStillClosesActiveTrustBoundary() {
        RepositoryProbe repository = new RepositoryProbe(new PairingCredentialRecord(
                bytes(PairingAuthenticator.PAIRING_ID_LENGTH, (byte) 0x11),
                bytes(PairingAuthenticator.DIGEST_LENGTH, (byte) 0x22),
                bytes(PairingAuthenticator.KEY_LENGTH, (byte) 0x33),
                " \u202e\n\u200b\u2069 ",
                100,
                200
        ));
        repository.failRevocation = true;
        PairedDeviceManager manager = new PairedDeviceManager(
                repository,
                () -> repository.events.add("close")
        );
        assertEquals("Mac", manager.devices().get(0).displayName);

        try {
            manager.revoke(manager.devices().get(0));
            throw new AssertionError("expected credential deletion failure");
        } catch (IllegalStateException expected) {
            assertEquals("could not revoke pairing record", expected.getMessage());
        }

        assertEquals(Arrays.asList("catalog", "catalog", "close", "revoke"), repository.events);
        assertEquals(1, repository.records.size());
    }

    @Test
    public void shutdownFailurePreventsOrdinaryAndDamagedDeletion() {
        RepositoryProbe ordinaryRepository = new RepositoryProbe(new PairingCredentialRecord(
                bytes(PairingAuthenticator.PAIRING_ID_LENGTH, (byte) 0x11),
                bytes(PairingAuthenticator.DIGEST_LENGTH, (byte) 0x22),
                bytes(PairingAuthenticator.KEY_LENGTH, (byte) 0x33),
                "Mac",
                100,
                200
        ));
        PairedDeviceManager ordinary = new PairedDeviceManager(
                ordinaryRepository,
                () -> { throw new IllegalStateException("shutdown failed"); }
        );
        try {
            ordinary.revoke(ordinary.devices().get(0));
            fail("expected shutdown failure");
        } catch (IllegalStateException expected) {
            assertEquals("shutdown failed", expected.getMessage());
        }
        assertEquals(1, ordinaryRepository.records.size());
        assertEquals(Arrays.asList("catalog"), ordinaryRepository.events);

        RepositoryProbe damagedRepository = new RepositoryProbe(null);
        damagedRepository.catalogOverride = damagedCatalog();
        boolean[] drainAvailable = {false};
        PairedDeviceManager damaged = new PairedDeviceManager(
                damagedRepository,
                () -> {
                    if (!drainAvailable[0]) {
                        throw new IllegalStateException("shutdown failed");
                    }
                    damagedRepository.events.add("close");
                }
        );
        PairedDeviceManager.DamagedDevice device = damaged.catalog().damagedDevices.get(0);
        try {
            damaged.removeDamaged(device);
            fail("expected shutdown failure");
        } catch (IllegalStateException expected) {
            assertEquals("shutdown failed", expected.getMessage());
        }
        assertEquals(Arrays.asList("catalog"), damagedRepository.events);

        drainAvailable[0] = true;
        PairedDeviceManager.Catalog refreshed = damaged.removeDamaged(device);
        assertEquals(Arrays.asList("catalog", "close", "remove", "catalog"),
                damagedRepository.events);
        assertTrue(refreshed.complete);
    }

    @Test
    public void damagedCleanupClosesSessionBeforeDeleteAndRequiresFreshCatalog() {
        RepositoryProbe repository = new RepositoryProbe(null);
        repository.catalogOverride = damagedCatalog();
        ArrayList<String> events = repository.events;
        PairedDeviceManager manager = new PairedDeviceManager(
                repository,
                () -> events.add("close")
        );
        PairedDeviceManager.Catalog catalog = manager.catalog();
        assertFalse(catalog.complete);
        assertEquals(0, catalog.devices.size());
        assertEquals(1, catalog.damagedDevices.size());

        PairedDeviceManager.Catalog refreshed = manager.removeDamaged(catalog.damagedDevices.get(0));
        assertEquals(Arrays.asList("catalog", "close", "remove", "catalog"), events);
        assertEquals(0, refreshed.devices.size());
        assertEquals(0, refreshed.damagedDevices.size());
    }

    @Test
    public void damagedCleanupRereadFailureDoesNotReturnSuccess() {
        RepositoryProbe repository = new RepositoryProbe(null);
        repository.catalogOverride = damagedCatalog();
        PairedDeviceManager manager = new PairedDeviceManager(
                repository,
                () -> repository.events.add("close")
        );
        PairedDeviceManager.DamagedDevice damaged = manager.catalog().damagedDevices.get(0);
        repository.failCatalogAfterRemoval = true;

        try {
            manager.removeDamaged(damaged);
            fail("expected authoritative reread failure");
        } catch (IllegalStateException expected) {
            assertEquals("pairing catalog unavailable", expected.getMessage());
        }
        assertEquals(Arrays.asList("catalog", "close", "remove", "catalog"), repository.events);
    }

    private static PairingCredentialVault.Catalog damagedCatalog() {
        Map<String, String> values = new HashMap<>();
        values.put("record.00112233445566778899aabbccddeeff", "not-base64");
        PairingCredentialVault vault = new PairingCredentialVault(
                new PairingCredentialVault.RecordBackend() {
                    @Override public PairingCredentialVault.RecordSnapshot snapshot(String key) {
                        return new PairingCredentialVault.RecordSnapshot(values.get(key), 0);
                    }
                    @Override public void put(String key, String value) { values.put(key, value); }
                    @Override public void remove(String key) { values.remove(key); }
                    @Override public List<String> keys() { return new ArrayList<>(values.keySet()); }
                    @Override public boolean removeIfUnchanged(
                            String key,
                            String expectedValue,
                            long expectedRevision
                    ) {
                        if (expectedRevision != 0) { return false; }
                        if (!expectedValue.equals(values.get(key))) { return false; }
                        values.remove(key);
                        return true;
                    }
                },
                new PairingCredentialVault.KeyProtector() {
                    @Override
                    public PairingCredentialVault.EncryptedKey encrypt(byte[] plaintext, byte[] aad) {
                        throw new UnsupportedOperationException();
                    }

                    @Override
                    public byte[] decrypt(PairingCredentialVault.EncryptedKey encrypted, byte[] aad) {
                        throw new UnsupportedOperationException();
                    }
                }
        );
        return vault.catalog();
    }

    private static byte[] bytes(int count, byte value) {
        byte[] result = new byte[count];
        Arrays.fill(result, value);
        return result;
    }

    private static final class RepositoryProbe implements PairingCredentialRepository {
        private final ArrayList<PairingCredentialRecord> records = new ArrayList<>();
        byte[] revokedPairingId;
        boolean failRevocation;
        boolean failCatalogAfterRemoval;
        PairingCredentialVault.Catalog catalogOverride;
        final ArrayList<String> events = new ArrayList<>();

        RepositoryProbe(PairingCredentialRecord record) {
            if (record != null) {
                records.add(record);
            }
        }

        @Override
        public void save(PairingCredentialRecord record) {
            records.add(record);
        }

        @Override
        public PairingCredentialRecord load(byte[] pairingId) {
            return records.isEmpty() ? null : records.get(0);
        }

        @Override
        public List<PairingCredentialRecord.Metadata> list() {
            ArrayList<PairingCredentialRecord.Metadata> metadata = new ArrayList<>();
            for (PairingCredentialRecord record : records) {
                metadata.add(record.metadata());
            }
            return metadata;
        }

        @Override
        public PairingCredentialVault.Catalog catalog() {
            events.add("catalog");
            if (failCatalogAfterRemoval && events.contains("remove")) {
                throw new IllegalStateException("pairing catalog unavailable");
            }
            if (catalogOverride != null) {
                return catalogOverride;
            }
            return PairingCredentialRepository.super.catalog();
        }

        @Override
        public void removeDamaged(PairingCredentialVault.DamagedRecord record) {
            events.add("remove");
            catalogOverride = PairingCredentialVault.Catalog.complete(new ArrayList<>());
        }

        @Override
        public void revoke(byte[] pairingId) {
            events.add("revoke");
            if (failRevocation) {
                throw new IllegalStateException("could not revoke pairing record");
            }
            revokedPairingId = Arrays.copyOf(pairingId, pairingId.length);
            records.clear();
        }

        @Override
        public byte[] pairingKey(byte[] pairingId) {
            return null;
        }
    }
}
