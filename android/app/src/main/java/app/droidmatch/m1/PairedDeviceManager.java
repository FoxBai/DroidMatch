package app.droidmatch.m1;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/** Secret-free product boundary for listing and revoking paired Macs. */
final class PairedDeviceManager {
    interface TrustRevocationListener {
        void closeActiveTrustBoundary();
    }

    static final class Device {
        final byte[] pairingId;
        final String displayName;
        final long lastUsedAtUnixMillis;

        Device(byte[] pairingId, String displayName, long lastUsedAtUnixMillis) {
            this.pairingId = Arrays.copyOf(pairingId, pairingId.length);
            // Revocation stays bound to pairingId; peer text is display-only.
            this.displayName = ProductDisplayName.deviceName(displayName);
            this.lastUsedAtUnixMillis = lastUsedAtUnixMillis;
        }

        byte[] pairingId() {
            return Arrays.copyOf(pairingId, pairingId.length);
        }
    }

    static final class DamagedDevice {
        private final PairingCredentialVault.DamagedRecord identity;

        private DamagedDevice(PairingCredentialVault.DamagedRecord identity) {
            this.identity = identity;
        }
    }

    static final class Catalog {
        final List<Device> devices;
        final List<DamagedDevice> damagedDevices;
        final boolean complete;

        private Catalog(List<Device> devices, List<DamagedDevice> damagedDevices, boolean complete) {
            this.devices = Collections.unmodifiableList(devices);
            this.damagedDevices = Collections.unmodifiableList(damagedDevices);
            this.complete = complete;
        }
    }

    private final PairingCredentialRepository repository;
    private final TrustRevocationListener listener;

    PairedDeviceManager(
            PairingCredentialRepository repository,
            TrustRevocationListener listener
    ) {
        this.repository = repository;
        this.listener = listener;
    }

    List<Device> devices() {
        Catalog catalog = catalog();
        if (!catalog.complete) {
            throw new IllegalStateException("paired-device catalog is incomplete");
        }
        return catalog.devices;
    }

    Catalog catalog() {
        ArrayList<Device> devices = new ArrayList<>();
        ArrayList<DamagedDevice> damagedDevices = new ArrayList<>();
        PairingCredentialVault.Catalog catalog = repository.catalog();
        for (PairingCredentialRecord.Metadata metadata : catalog.metadata()) {
            devices.add(new Device(
                    metadata.pairingId(),
                    metadata.displayName(),
                    metadata.lastUsedAtUnixMillis()
            ));
        }
        for (PairingCredentialVault.DamagedRecord record : catalog.damagedRecords()) {
            damagedDevices.add(new DamagedDevice(record));
        }
        return new Catalog(devices, damagedDevices, catalog.isComplete());
    }

    void revoke(Device device) {
        listener.closeActiveTrustBoundary();
        repository.revoke(device.pairingId());
    }

    Catalog removeDamaged(DamagedDevice device) {
        // Cleanup is exceptional recovery, not ordinary revocation. Close the
        // active endpoint before touching an identity that has no trusted payload.
        listener.closeActiveTrustBoundary();
        repository.removeDamaged(device.identity);
        return catalog();
    }
}
