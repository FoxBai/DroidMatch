package app.droidmatch.m1;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/** Secret-free product boundary for listing and revoking paired Macs. */
final class PairedDeviceManager {
    interface TrustRevocationListener {
        void onTrustRevoked();
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
        ArrayList<Device> devices = new ArrayList<>();
        for (PairingCredentialRecord.Metadata metadata : repository.list()) {
            devices.add(new Device(
                    metadata.pairingId(),
                    metadata.displayName(),
                    metadata.lastUsedAtUnixMillis()
            ));
        }
        return Collections.unmodifiableList(devices);
    }

    void revoke(Device device) {
        try {
            repository.revoke(device.pairingId());
        } finally {
            // A failed SharedPreferences commit must not leave an already-authenticated
            // session running after the user has attempted to revoke its trust.
            listener.onTrustRevoked();
        }
    }
}
