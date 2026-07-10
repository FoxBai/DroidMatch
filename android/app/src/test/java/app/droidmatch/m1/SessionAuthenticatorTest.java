package app.droidmatch.m1;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.io.IOException;
import java.io.InputStream;
import java.util.Properties;

import org.junit.Test;

public final class SessionAuthenticatorTest {
    @Test
    public void matchesCrossPlatformFixture() throws Exception {
        Properties fixture = loadFixture();
        byte[] pairingKey = hex(fixture, "pairing_key");
        byte[] transcript = SessionAuthenticator.transcript(
                hex(fixture, "pairing_id"),
                hex(fixture, "client_nonce"),
                hex(fixture, "server_nonce"),
                integer(fixture, "protocol_major"),
                integer(fixture, "protocol_minor"),
                integer(fixture, "transport_kind")
        );
        byte[] transcriptHash = SessionAuthenticator.transcriptHash(transcript);
        byte[] clientProof = SessionAuthenticator.clientProof(pairingKey, transcriptHash);
        byte[] serverProof = SessionAuthenticator.serverProof(pairingKey, transcriptHash);

        assertArrayEquals(hex(fixture, "transcript"), transcript);
        assertArrayEquals(hex(fixture, "transcript_hash"), transcriptHash);
        assertArrayEquals(hex(fixture, "client_proof"), clientProof);
        assertArrayEquals(hex(fixture, "server_proof"), serverProof);
        assertArrayEquals(
                hex(fixture, "session_key"),
                SessionAuthenticator.sessionKey(pairingKey, transcriptHash)
        );
        assertTrue(SessionAuthenticator.verifyClientProof(clientProof, pairingKey, transcriptHash));
        assertTrue(SessionAuthenticator.verifyServerProof(serverProof, pairingKey, transcriptHash));
    }

    @Test
    public void separatesRolesAndRejectsFreshServerNonceReplay() throws Exception {
        Properties fixture = loadFixture();
        byte[] pairingKey = hex(fixture, "pairing_key");
        byte[] clientProof = hex(fixture, "client_proof");
        byte[] serverProof = hex(fixture, "server_proof");
        byte[] originalHash = hex(fixture, "transcript_hash");

        assertFalse(SessionAuthenticator.verifyClientProof(serverProof, pairingKey, originalHash));
        assertFalse(SessionAuthenticator.verifyServerProof(clientProof, pairingKey, originalHash));

        byte[] changedServerNonce = hex(fixture, "server_nonce");
        changedServerNonce[0] ^= (byte) 0xff;
        byte[] changedTranscript = SessionAuthenticator.transcript(
                hex(fixture, "pairing_id"),
                hex(fixture, "client_nonce"),
                changedServerNonce,
                1,
                0,
                1
        );
        byte[] changedHash = SessionAuthenticator.transcriptHash(changedTranscript);
        assertFalse(SessionAuthenticator.verifyClientProof(clientProof, pairingKey, changedHash));
    }

    @Test
    public void rejectsInvalidFixedLengths() throws Exception {
        Properties fixture = loadFixture();
        try {
            SessionAuthenticator.transcript(
                    new byte[15],
                    hex(fixture, "client_nonce"),
                    hex(fixture, "server_nonce"),
                    1,
                    0,
                    1
            );
            fail("expected invalid pairing ID length");
        } catch (IllegalArgumentException expected) {
            // Expected: malformed public transcript input fails before any HMAC work.
        }

        try {
            SessionAuthenticator.clientProof(new byte[31], new byte[32]);
            fail("expected invalid pairing key length");
        } catch (IllegalArgumentException expected) {
            // Expected: pairing keys are always exactly 256 bits.
        }
    }

    private static Properties loadFixture() throws IOException {
        try (InputStream stream = SessionAuthenticatorTest.class.getResourceAsStream(
                "/session-auth-v1.properties"
        )) {
            if (stream == null) {
                throw new IOException("session auth fixture is missing from test resources");
            }
            Properties properties = new Properties();
            properties.load(stream);
            return properties;
        }
    }

    private static int integer(Properties fixture, String key) {
        String value = fixture.getProperty(key);
        if (value == null) {
            throw new IllegalArgumentException("missing fixture value: " + key);
        }
        return Integer.parseInt(value);
    }

    private static byte[] hex(Properties fixture, String key) {
        String value = fixture.getProperty(key);
        if (value == null || (value.length() & 1) != 0) {
            throw new IllegalArgumentException("invalid fixture hex: " + key);
        }
        byte[] result = new byte[value.length() / 2];
        for (int index = 0; index < result.length; index++) {
            int high = Character.digit(value.charAt(index * 2), 16);
            int low = Character.digit(value.charAt(index * 2 + 1), 16);
            if (high < 0 || low < 0) {
                throw new IllegalArgumentException("invalid fixture hex: " + key);
            }
            result[index] = (byte) ((high << 4) | low);
        }
        return result;
    }
}
