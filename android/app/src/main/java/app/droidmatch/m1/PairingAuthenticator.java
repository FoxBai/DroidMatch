package app.droidmatch.m1;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Locale;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** Canonical first-pairing transcript, KDF, SAS, and role confirmation primitives. */
public final class PairingAuthenticator {
    public static final int VERSION = 1;
    public static final int PRIVATE_KEY_LENGTH = 32;
    public static final int PUBLIC_KEY_LENGTH = 65;
    public static final int NONCE_LENGTH = 32;
    public static final int PAIRING_ID_LENGTH = 16;
    public static final int KEY_LENGTH = 32;
    public static final int DIGEST_LENGTH = 32;
    public static final int MAXIMUM_DISPLAY_NAME_BYTES = 128;

    private static final byte[] TRANSCRIPT_CONTEXT = ascii("DroidMatch pairing transcript v1\0");
    private static final byte[] CONFIRMATION_KEY_CONTEXT = ascii("DroidMatch pairing confirmation key v1\0");
    private static final byte[] PAIRING_KEY_CONTEXT = ascii("DroidMatch pairing key v1\0");
    private static final byte[] SAS_CONTEXT = ascii("DroidMatch pairing SAS v1\0");
    private static final byte[] CLIENT_CONFIRMATION_CONTEXT = ascii(
            "DroidMatch pairing client confirmation v1\0"
    );
    private static final byte[] SERVER_CONFIRMATION_CONTEXT = ascii(
            "DroidMatch pairing server confirmation v1\0"
    );
    private static final byte[] FINAL_CONFIRMATION_CONTEXT = ascii(
            "DroidMatch pairing final confirmation v1\0"
    );
    private static final long SAS_MODULUS = 1_000_000L;
    private static final long UNBIASED_UINT32_LIMIT = 4_294_000_000L;

    private PairingAuthenticator() {
    }

    public static byte[] transcript(
            int pairingVersion,
            byte[] pairingId,
            byte[] clientPublicKey,
            byte[] serverPublicKey,
            byte[] deviceIdentityPublicKey,
            byte[] clientNonce,
            byte[] serverNonce,
            String clientName,
            String serverName
    ) {
        if (pairingVersion != VERSION) {
            throw new IllegalArgumentException("unsupported pairing version: " + pairingVersion);
        }
        requireLength(pairingId, "pairing ID", PAIRING_ID_LENGTH);
        validatePublicKeyShape(clientPublicKey, "client public key");
        validatePublicKeyShape(serverPublicKey, "server public key");
        validatePublicKeyShape(deviceIdentityPublicKey, "device identity public key");
        requireLength(clientNonce, "client nonce", NONCE_LENGTH);
        requireLength(serverNonce, "server nonce", NONCE_LENGTH);
        byte[] clientNameBytes = displayNameBytes(clientName, "client name");
        byte[] serverNameBytes = displayNameBytes(serverName, "server name");

        ByteArrayOutputStream output = new ByteArrayOutputStream();
        append(output, TRANSCRIPT_CONTEXT);
        appendUInt32(output, pairingVersion);
        appendLengthPrefixed(output, pairingId);
        appendLengthPrefixed(output, clientPublicKey);
        appendLengthPrefixed(output, serverPublicKey);
        appendLengthPrefixed(output, deviceIdentityPublicKey);
        appendLengthPrefixed(output, clientNonce);
        appendLengthPrefixed(output, serverNonce);
        appendLengthPrefixed(output, clientNameBytes);
        appendLengthPrefixed(output, serverNameBytes);
        return output.toByteArray();
    }

    public static byte[] transcriptHash(byte[] transcript) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(transcript);
        } catch (GeneralSecurityException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    public static DerivedSecrets deriveSecrets(byte[] sharedSecret, byte[] transcriptHash) {
        requireLength(sharedSecret, "P-256 shared secret", KEY_LENGTH);
        requireLength(transcriptHash, "transcript hash", DIGEST_LENGTH);
        byte[] confirmationKey = hkdf(sharedSecret, transcriptHash, CONFIRMATION_KEY_CONTEXT);
        byte[] pairingKey = hkdf(sharedSecret, transcriptHash, PAIRING_KEY_CONTEXT);
        return new DerivedSecrets(
                confirmationKey,
                pairingKey,
                shortAuthenticationString(confirmationKey, transcriptHash)
        );
    }

    public static byte[] clientConfirmation(byte[] confirmationKey, byte[] transcriptHash) {
        return confirmation(
                CLIENT_CONFIRMATION_CONTEXT,
                new byte[] {1},
                confirmationKey,
                transcriptHash
        );
    }

    public static byte[] serverConfirmation(byte[] confirmationKey, byte[] transcriptHash) {
        return confirmation(
                SERVER_CONFIRMATION_CONTEXT,
                new byte[] {1, 1},
                confirmationKey,
                transcriptHash
        );
    }

    public static byte[] finalConfirmation(
            byte[] confirmationKey,
            byte[] transcriptHash,
            byte[] serverConfirmation
    ) {
        requireLength(serverConfirmation, "server confirmation", DIGEST_LENGTH);
        return confirmation(
                FINAL_CONFIRMATION_CONTEXT,
                serverConfirmation,
                confirmationKey,
                transcriptHash
        );
    }

    public static boolean verifyClientConfirmation(
            byte[] candidate,
            byte[] confirmationKey,
            byte[] transcriptHash
    ) {
        return verifyConfirmation(
                candidate,
                CLIENT_CONFIRMATION_CONTEXT,
                new byte[] {1},
                confirmationKey,
                transcriptHash
        );
    }

    public static boolean verifyServerConfirmation(
            byte[] candidate,
            byte[] confirmationKey,
            byte[] transcriptHash
    ) {
        return verifyConfirmation(
                candidate,
                SERVER_CONFIRMATION_CONTEXT,
                new byte[] {1, 1},
                confirmationKey,
                transcriptHash
        );
    }

    public static boolean verifyFinalConfirmation(
            byte[] candidate,
            byte[] confirmationKey,
            byte[] transcriptHash,
            byte[] serverConfirmation
    ) {
        requireLength(serverConfirmation, "server confirmation", DIGEST_LENGTH);
        return verifyConfirmation(
                candidate,
                FINAL_CONFIRMATION_CONTEXT,
                serverConfirmation,
                confirmationKey,
                transcriptHash
        );
    }

    private static String shortAuthenticationString(byte[] confirmationKey, byte[] transcriptHash) {
        for (long counter = 0; counter <= 0xffff_ffffL; counter += 1) {
            ByteArrayOutputStream message = new ByteArrayOutputStream();
            append(message, SAS_CONTEXT);
            append(message, transcriptHash);
            appendUInt32(message, counter);
            byte[] code = hmac(confirmationKey, message.toByteArray());
            long value = ((long) (code[0] & 0xff) << 24)
                    | ((long) (code[1] & 0xff) << 16)
                    | ((long) (code[2] & 0xff) << 8)
                    | (long) (code[3] & 0xff);
            if (value < UNBIASED_UINT32_LIMIT) {
                return String.format(Locale.ROOT, "%06d", value % SAS_MODULUS);
            }
        }
        throw new IllegalStateException("could not derive an unbiased short authentication string");
    }

    private static byte[] confirmation(
            byte[] context,
            byte[] suffix,
            byte[] confirmationKey,
            byte[] transcriptHash
    ) {
        requireLength(confirmationKey, "confirmation key", KEY_LENGTH);
        requireLength(transcriptHash, "transcript hash", DIGEST_LENGTH);
        return hmac(confirmationKey, concatenate(context, transcriptHash, suffix));
    }

    private static boolean verifyConfirmation(
            byte[] candidate,
            byte[] context,
            byte[] suffix,
            byte[] confirmationKey,
            byte[] transcriptHash
    ) {
        requireLength(confirmationKey, "confirmation key", KEY_LENGTH);
        requireLength(transcriptHash, "transcript hash", DIGEST_LENGTH);
        if (candidate.length != DIGEST_LENGTH) {
            return false;
        }
        return MessageDigest.isEqual(
                confirmation(context, suffix, confirmationKey, transcriptHash),
                candidate
        );
    }

    private static byte[] hkdf(byte[] input, byte[] salt, byte[] info) {
        byte[] pseudoRandomKey = hmac(salt, input);
        byte[] expandInput = Arrays.copyOf(info, info.length + 1);
        expandInput[expandInput.length - 1] = 1;
        try {
            return hmac(pseudoRandomKey, expandInput);
        } finally {
            Arrays.fill(pseudoRandomKey, (byte) 0);
            Arrays.fill(expandInput, (byte) 0);
        }
    }

    private static byte[] hmac(byte[] key, byte[] message) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            return mac.doFinal(message);
        } catch (GeneralSecurityException exception) {
            throw new IllegalStateException("HmacSHA256 is unavailable", exception);
        }
    }

    private static byte[] concatenate(byte[] first, byte[] second, byte[] third) {
        byte[] result = new byte[first.length + second.length + third.length];
        System.arraycopy(first, 0, result, 0, first.length);
        System.arraycopy(second, 0, result, first.length, second.length);
        System.arraycopy(third, 0, result, first.length + second.length, third.length);
        return result;
    }

    private static void validatePublicKeyShape(byte[] key, String field) {
        requireLength(key, field, PUBLIC_KEY_LENGTH);
        if (key[0] != 0x04) {
            throw new IllegalArgumentException("invalid P-256 public key");
        }
    }

    private static byte[] displayNameBytes(String name, String field) {
        byte[] bytes = name.getBytes(StandardCharsets.UTF_8);
        if (bytes.length == 0 || bytes.length > MAXIMUM_DISPLAY_NAME_BYTES) {
            throw new IllegalArgumentException(
                    "invalid " + field + ": UTF-8 length must be 1 to "
                            + MAXIMUM_DISPLAY_NAME_BYTES + " bytes, got " + bytes.length
            );
        }
        return bytes;
    }

    private static void requireLength(byte[] value, String field, int expected) {
        if (value.length != expected) {
            throw new IllegalArgumentException(
                    "invalid " + field + " length: expected " + expected + " bytes, got " + value.length
            );
        }
    }

    private static void appendLengthPrefixed(ByteArrayOutputStream output, byte[] value) {
        output.write((value.length >>> 8) & 0xff);
        output.write(value.length & 0xff);
        append(output, value);
    }

    private static void appendUInt32(ByteArrayOutputStream output, long value) {
        output.write((int) ((value >>> 24) & 0xff));
        output.write((int) ((value >>> 16) & 0xff));
        output.write((int) ((value >>> 8) & 0xff));
        output.write((int) (value & 0xff));
    }

    private static void append(ByteArrayOutputStream output, byte[] value) {
        output.write(value, 0, value.length);
    }

    private static byte[] ascii(String value) {
        return value.getBytes(StandardCharsets.US_ASCII);
    }

    public static final class DerivedSecrets implements AutoCloseable {
        private final byte[] confirmationKey;
        private final byte[] pairingKey;
        private final String shortAuthenticationString;

        private DerivedSecrets(byte[] confirmationKey, byte[] pairingKey, String shortAuthenticationString) {
            this.confirmationKey = Arrays.copyOf(confirmationKey, confirmationKey.length);
            this.pairingKey = Arrays.copyOf(pairingKey, pairingKey.length);
            this.shortAuthenticationString = shortAuthenticationString;
        }

        public byte[] confirmationKey() {
            return Arrays.copyOf(confirmationKey, confirmationKey.length);
        }

        public byte[] pairingKey() {
            return Arrays.copyOf(pairingKey, pairingKey.length);
        }

        public String shortAuthenticationString() {
            return shortAuthenticationString;
        }

        @Override
        public void close() {
            Arrays.fill(confirmationKey, (byte) 0);
            Arrays.fill(pairingKey, (byte) 0);
        }
    }
}
