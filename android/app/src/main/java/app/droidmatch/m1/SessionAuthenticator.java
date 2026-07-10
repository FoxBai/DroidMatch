package app.droidmatch.m1;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * Cross-platform canonical transcript and HMAC/HKDF core for paired sessions.
 *
 * <p>This class deliberately contains no protobuf, storage, or UI state. Swift and
 * Java must match the same checked-in fixture before the authentication messages are
 * connected to {@link RpcDispatcher}.</p>
 */
public final class SessionAuthenticator {
    public static final int PAIRING_ID_LENGTH = 16;
    public static final int NONCE_LENGTH = 32;
    public static final int PAIRING_KEY_LENGTH = 32;
    public static final int DIGEST_LENGTH = 32;

    private static final byte[] TRANSCRIPT_CONTEXT = ascii("DroidMatch session auth v1\0");
    private static final byte[] CLIENT_PROOF_CONTEXT = ascii("DroidMatch client proof v1\0");
    private static final byte[] SERVER_PROOF_CONTEXT = ascii("DroidMatch server proof v1\0");
    private static final byte[] SESSION_KEY_CONTEXT = ascii("DroidMatch session key v1\0");

    private SessionAuthenticator() {
    }

    public static byte[] transcript(
            byte[] pairingId,
            byte[] clientNonce,
            byte[] serverNonce,
            int protocolMajor,
            int protocolMinor,
            int transportKind
    ) {
        requireLength(pairingId, "pairing ID", PAIRING_ID_LENGTH);
        requireLength(clientNonce, "client nonce", NONCE_LENGTH);
        requireLength(serverNonce, "server nonce", NONCE_LENGTH);

        ByteArrayOutputStream output = new ByteArrayOutputStream();
        append(output, TRANSCRIPT_CONTEXT);
        appendLengthPrefixed(output, pairingId);
        appendLengthPrefixed(output, clientNonce);
        appendLengthPrefixed(output, serverNonce);
        appendUInt32(output, protocolMajor);
        appendUInt32(output, protocolMinor);
        appendUInt32(output, transportKind);
        return output.toByteArray();
    }

    public static byte[] transcriptHash(byte[] transcript) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(transcript);
        } catch (GeneralSecurityException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    public static byte[] clientProof(byte[] pairingKey, byte[] transcriptHash) {
        return proof(pairingKey, transcriptHash, CLIENT_PROOF_CONTEXT);
    }

    public static byte[] serverProof(byte[] pairingKey, byte[] transcriptHash) {
        return proof(pairingKey, transcriptHash, SERVER_PROOF_CONTEXT);
    }

    public static boolean verifyClientProof(
            byte[] candidate,
            byte[] pairingKey,
            byte[] transcriptHash
    ) {
        return verifyProof(candidate, pairingKey, transcriptHash, CLIENT_PROOF_CONTEXT);
    }

    public static boolean verifyServerProof(
            byte[] candidate,
            byte[] pairingKey,
            byte[] transcriptHash
    ) {
        return verifyProof(candidate, pairingKey, transcriptHash, SERVER_PROOF_CONTEXT);
    }

    public static byte[] sessionKey(byte[] pairingKey, byte[] transcriptHash) {
        requireLength(pairingKey, "pairing key", PAIRING_KEY_LENGTH);
        requireLength(transcriptHash, "transcript hash", DIGEST_LENGTH);
        byte[] pseudoRandomKey = hmac(transcriptHash, pairingKey);
        byte[] expandInput = new byte[SESSION_KEY_CONTEXT.length + 1];
        System.arraycopy(SESSION_KEY_CONTEXT, 0, expandInput, 0, SESSION_KEY_CONTEXT.length);
        expandInput[expandInput.length - 1] = 1;
        try {
            return hmac(pseudoRandomKey, expandInput);
        } finally {
            java.util.Arrays.fill(pseudoRandomKey, (byte) 0);
            java.util.Arrays.fill(expandInput, (byte) 0);
        }
    }

    private static byte[] proof(byte[] pairingKey, byte[] transcriptHash, byte[] roleContext) {
        requireLength(pairingKey, "pairing key", PAIRING_KEY_LENGTH);
        requireLength(transcriptHash, "transcript hash", DIGEST_LENGTH);
        return hmac(pairingKey, concatenate(roleContext, transcriptHash));
    }

    private static boolean verifyProof(
            byte[] candidate,
            byte[] pairingKey,
            byte[] transcriptHash,
            byte[] roleContext
    ) {
        requireLength(pairingKey, "pairing key", PAIRING_KEY_LENGTH);
        requireLength(transcriptHash, "transcript hash", DIGEST_LENGTH);
        if (candidate.length != DIGEST_LENGTH) {
            return false;
        }
        return MessageDigest.isEqual(proof(pairingKey, transcriptHash, roleContext), candidate);
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

    private static byte[] concatenate(byte[] first, byte[] second) {
        byte[] result = new byte[first.length + second.length];
        System.arraycopy(first, 0, result, 0, first.length);
        System.arraycopy(second, 0, result, first.length, second.length);
        return result;
    }

    private static void requireLength(byte[] value, String field, int expected) {
        if (value.length != expected) {
            throw new IllegalArgumentException(
                    "invalid " + field + " length: expected " + expected + " bytes, got " + value.length
            );
        }
    }

    private static void appendLengthPrefixed(ByteArrayOutputStream output, byte[] value) {
        int length = value.length;
        output.write((length >>> 8) & 0xff);
        output.write(length & 0xff);
        append(output, value);
    }

    private static void appendUInt32(ByteArrayOutputStream output, int value) {
        output.write((value >>> 24) & 0xff);
        output.write((value >>> 16) & 0xff);
        output.write((value >>> 8) & 0xff);
        output.write(value & 0xff);
    }

    private static void append(ByteArrayOutputStream output, byte[] value) {
        output.write(value, 0, value.length);
    }

    private static byte[] ascii(String value) {
        return value.getBytes(StandardCharsets.US_ASCII);
    }
}
