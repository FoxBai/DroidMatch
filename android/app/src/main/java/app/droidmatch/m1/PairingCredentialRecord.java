package app.droidmatch.m1;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** In-memory pairing credential. Deliberately has no secret-bearing toString(). */
public final class PairingCredentialRecord {
    private final byte[] pairingId;
    private final byte[] deviceIdentityFingerprint;
    private final byte[] pairingKey;
    private final String displayName;
    private final long createdAtUnixMillis;
    private final long lastUsedAtUnixMillis;

    public PairingCredentialRecord(
            byte[] pairingId,
            byte[] deviceIdentityFingerprint,
            byte[] pairingKey,
            String displayName,
            long createdAtUnixMillis,
            long lastUsedAtUnixMillis
    ) {
        requireLength(pairingId, "pairing ID", PairingAuthenticator.PAIRING_ID_LENGTH);
        requireLength(
                deviceIdentityFingerprint,
                "device identity fingerprint",
                PairingAuthenticator.DIGEST_LENGTH
        );
        requireLength(pairingKey, "pairing key", PairingAuthenticator.KEY_LENGTH);
        int displayNameBytes = displayName.getBytes(StandardCharsets.UTF_8).length;
        if (displayNameBytes == 0 || displayNameBytes > PairingAuthenticator.MAXIMUM_DISPLAY_NAME_BYTES) {
            throw new IllegalArgumentException("invalid device display name UTF-8 length: " + displayNameBytes);
        }
        if (createdAtUnixMillis < 0 || lastUsedAtUnixMillis < 0) {
            throw new IllegalArgumentException("pairing timestamps must be non-negative");
        }
        this.pairingId = Arrays.copyOf(pairingId, pairingId.length);
        this.deviceIdentityFingerprint = Arrays.copyOf(
                deviceIdentityFingerprint,
                deviceIdentityFingerprint.length
        );
        this.pairingKey = Arrays.copyOf(pairingKey, pairingKey.length);
        this.displayName = displayName;
        this.createdAtUnixMillis = createdAtUnixMillis;
        this.lastUsedAtUnixMillis = lastUsedAtUnixMillis;
    }

    public byte[] pairingId() {
        return Arrays.copyOf(pairingId, pairingId.length);
    }

    public byte[] deviceIdentityFingerprint() {
        return Arrays.copyOf(deviceIdentityFingerprint, deviceIdentityFingerprint.length);
    }

    public byte[] pairingKey() {
        return Arrays.copyOf(pairingKey, pairingKey.length);
    }

    public String displayName() {
        return displayName;
    }

    public long createdAtUnixMillis() {
        return createdAtUnixMillis;
    }

    public long lastUsedAtUnixMillis() {
        return lastUsedAtUnixMillis;
    }

    public Metadata metadata() {
        return new Metadata(
                pairingId,
                deviceIdentityFingerprint,
                displayName,
                createdAtUnixMillis,
                lastUsedAtUnixMillis
        );
    }

    private static void requireLength(byte[] value, String field, int expected) {
        if (value.length != expected) {
            throw new IllegalArgumentException(
                    "invalid " + field + " length: expected " + expected + " bytes, got " + value.length
            );
        }
    }

    public static final class Metadata {
        private final byte[] pairingId;
        private final byte[] deviceIdentityFingerprint;
        private final String displayName;
        private final long createdAtUnixMillis;
        private final long lastUsedAtUnixMillis;

        Metadata(
                byte[] pairingId,
                byte[] deviceIdentityFingerprint,
                String displayName,
                long createdAtUnixMillis,
                long lastUsedAtUnixMillis
        ) {
            this.pairingId = Arrays.copyOf(pairingId, pairingId.length);
            this.deviceIdentityFingerprint = Arrays.copyOf(
                    deviceIdentityFingerprint,
                    deviceIdentityFingerprint.length
            );
            this.displayName = displayName;
            this.createdAtUnixMillis = createdAtUnixMillis;
            this.lastUsedAtUnixMillis = lastUsedAtUnixMillis;
        }

        public byte[] pairingId() {
            return Arrays.copyOf(pairingId, pairingId.length);
        }

        public byte[] deviceIdentityFingerprint() {
            return Arrays.copyOf(deviceIdentityFingerprint, deviceIdentityFingerprint.length);
        }

        public String displayName() {
            return displayName;
        }

        public long createdAtUnixMillis() {
            return createdAtUnixMillis;
        }

        public long lastUsedAtUnixMillis() {
            return lastUsedAtUnixMillis;
        }
    }
}
