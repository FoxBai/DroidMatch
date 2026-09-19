package app.droidmatch.m1;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;

/** Private operation selector derived only after paired authentication succeeds. */
final class InstallOwner {
    private final byte[] value;

    private InstallOwner(byte[] value) {
        this.value = Arrays.copyOf(value, value.length);
    }

    static InstallOwner authenticated(byte[] pairingId) {
        if (pairingId == null || pairingId.length != SessionAuthenticator.PAIRING_ID_LENGTH) {
            throw new IllegalArgumentException("authenticated installation owner is invalid");
        }
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            digest.update("DroidMatch APK operation owner v1\0".getBytes(StandardCharsets.UTF_8));
            return new InstallOwner(digest.digest(pairingId));
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("required installation digest is unavailable");
        }
    }

    // Journal-only identity. Knowledge of this value never authenticates a peer.
    // 中文：仅用于私有日志归属；知道此值不构成对等端认证。
    String storageKey() {
        StringBuilder result = new StringBuilder(64);
        for (byte item : value) {
            result.append(Character.forDigit((item & 0xff) >>> 4, 16));
            result.append(Character.forDigit(item & 0x0f, 16));
        }
        return result.toString();
    }

    static InstallOwner restore(String value) {
        if (value == null || !value.matches("[0-9a-f]{64}")) {
            throw new IllegalArgumentException("stored installation owner is invalid");
        }
        byte[] bytes = new byte[32];
        for (int i = 0; i < bytes.length; i++) {
            bytes[i] = (byte) ((Character.digit(value.charAt(i * 2), 16) << 4)
                    | Character.digit(value.charAt(i * 2 + 1), 16));
        }
        return new InstallOwner(bytes);
    }

    @Override public boolean equals(Object other) {
        return other instanceof InstallOwner
                && MessageDigest.isEqual(value, ((InstallOwner) other).value);
    }

    @Override public int hashCode() { return Arrays.hashCode(value); }

    @Override public String toString() { return "InstallOwner[redacted]"; }
}
