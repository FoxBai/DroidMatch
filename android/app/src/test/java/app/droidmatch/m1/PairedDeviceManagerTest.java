package app.droidmatch.m1;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public final class PairedDeviceManagerTest {
    @Test
    public void listsSecretFreeMetadataAndRevocationClosesTrustBoundary() {
        byte[] pairingId = bytes(PairingAuthenticator.PAIRING_ID_LENGTH, (byte) 0x11);
        RepositoryProbe repository = new RepositoryProbe(new PairingCredentialRecord(
                pairingId,
                bytes(PairingAuthenticator.DIGEST_LENGTH, (byte) 0x22),
                bytes(PairingAuthenticator.KEY_LENGTH, (byte) 0x33),
                "Work Mac",
                100,
                200
        ));
        int[] revocationNotifications = {0};
        PairedDeviceManager manager = new PairedDeviceManager(
                repository,
                () -> revocationNotifications[0]++
        );

        List<PairedDeviceManager.Device> devices = manager.devices();
        assertEquals(1, devices.size());
        assertEquals("Work Mac", devices.get(0).displayName);
        assertEquals(200, devices.get(0).lastUsedAtUnixMillis);
        byte[] exposedCopy = devices.get(0).pairingId();
        exposedCopy[0] = 0x7f;

        manager.revoke(devices.get(0));
        assertArrayEquals(pairingId, repository.revokedPairingId);
        assertEquals(1, revocationNotifications[0]);
    }

    @Test
    public void credentialDeletionFailureStillClosesActiveTrustBoundary() {
        RepositoryProbe repository = new RepositoryProbe(new PairingCredentialRecord(
                bytes(PairingAuthenticator.PAIRING_ID_LENGTH, (byte) 0x11),
                bytes(PairingAuthenticator.DIGEST_LENGTH, (byte) 0x22),
                bytes(PairingAuthenticator.KEY_LENGTH, (byte) 0x33),
                "Work Mac",
                100,
                200
        ));
        repository.failRevocation = true;
        int[] revocationNotifications = {0};
        PairedDeviceManager manager = new PairedDeviceManager(
                repository,
                () -> revocationNotifications[0]++
        );

        try {
            manager.revoke(manager.devices().get(0));
            throw new AssertionError("expected credential deletion failure");
        } catch (IllegalStateException expected) {
            assertEquals("could not revoke pairing record", expected.getMessage());
        }

        assertEquals(1, revocationNotifications[0]);
        assertEquals(1, repository.records.size());
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

        RepositoryProbe(PairingCredentialRecord record) {
            records.add(record);
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
        public void revoke(byte[] pairingId) {
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
