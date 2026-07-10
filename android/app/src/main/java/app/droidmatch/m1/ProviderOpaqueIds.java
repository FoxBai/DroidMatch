package app.droidmatch.m1;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/** Creates deterministic, non-reversible identifiers for logical provider state. */
final class ProviderOpaqueIds {
    private ProviderOpaqueIds() {
    }

    static String stable(String value, int byteCount) {
        byte[] hash = sha256(value);
        StringBuilder builder = new StringBuilder();
        for (int index = 0; index < byteCount; index++) {
            int unsignedByte = hash[index] & 0xff;
            builder.append(Character.forDigit((unsignedByte >> 4) & 0xf, 16));
            builder.append(Character.forDigit(unsignedByte & 0xf, 16));
        }
        return builder.toString();
    }

    private static byte[] sha256(String value) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return digest.digest(value.getBytes(StandardCharsets.UTF_8));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 unavailable", exception);
        }
    }
}
