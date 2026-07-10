package app.droidmatch.m1;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.io.IOException;
import java.io.InputStream;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;
import java.util.Properties;

import org.junit.Test;

public final class PairingAuthenticatorTest {
    @Test
    public void matchesCrossPlatformFixtureIncludingP256Ecdh() throws Exception {
        Properties fixture = loadFixture();
        PairingKeyAgreement client = PairingKeyAgreement.fromRawForTest(
                hex(fixture, "client_private_key"),
                hex(fixture, "client_public_key")
        );
        PairingKeyAgreement server = PairingKeyAgreement.fromRawForTest(
                hex(fixture, "server_private_key"),
                hex(fixture, "server_public_key")
        );
        assertArrayEquals(hex(fixture, "client_public_key"), client.publicKeyX963Representation());
        assertArrayEquals(hex(fixture, "server_public_key"), server.publicKeyX963Representation());

        byte[] clientSharedSecret = client.sharedSecret(server.publicKeyX963Representation());
        byte[] serverSharedSecret = server.sharedSecret(client.publicKeyX963Representation());
        assertArrayEquals(clientSharedSecret, serverSharedSecret);
        assertArrayEquals(hex(fixture, "shared_secret"), clientSharedSecret);
        assertArrayEquals(
                hex(fixture, "device_identity_fingerprint"),
                PairingAuthenticator.transcriptHash(hex(fixture, "device_identity_public_key"))
        );

        byte[] transcript = transcript(fixture);
        byte[] transcriptHash = PairingAuthenticator.transcriptHash(transcript);
        PairingAuthenticator.DerivedSecrets secrets = PairingAuthenticator.deriveSecrets(
                clientSharedSecret,
                transcriptHash
        );
        byte[] clientConfirmation = PairingAuthenticator.clientConfirmation(
                secrets.confirmationKey(),
                transcriptHash
        );
        byte[] serverConfirmation = PairingAuthenticator.serverConfirmation(
                secrets.confirmationKey(),
                transcriptHash
        );
        byte[] finalConfirmation = PairingAuthenticator.finalConfirmation(
                secrets.confirmationKey(),
                transcriptHash,
                serverConfirmation
        );

        assertArrayEquals(hex(fixture, "transcript"), transcript);
        assertArrayEquals(hex(fixture, "transcript_hash"), transcriptHash);
        assertArrayEquals(hex(fixture, "confirmation_key"), secrets.confirmationKey());
        assertArrayEquals(hex(fixture, "pairing_key"), secrets.pairingKey());
        assertEquals(fixture.getProperty("sas"), secrets.shortAuthenticationString());
        assertArrayEquals(hex(fixture, "client_confirmation"), clientConfirmation);
        assertArrayEquals(hex(fixture, "server_confirmation"), serverConfirmation);
        assertArrayEquals(hex(fixture, "final_confirmation"), finalConfirmation);
        assertTrue(PairingAuthenticator.verifyClientConfirmation(
                clientConfirmation,
                secrets.confirmationKey(),
                transcriptHash
        ));
        assertTrue(PairingAuthenticator.verifyServerConfirmation(
                serverConfirmation,
                secrets.confirmationKey(),
                transcriptHash
        ));
        assertTrue(PairingAuthenticator.verifyFinalConfirmation(
                finalConfirmation,
                secrets.confirmationKey(),
                transcriptHash,
                serverConfirmation
        ));
    }

    @Test
    public void separatesRolesAndBindsFreshTranscript() throws Exception {
        Properties fixture = loadFixture();
        byte[] confirmationKey = hex(fixture, "confirmation_key");
        byte[] originalHash = hex(fixture, "transcript_hash");
        byte[] clientConfirmation = hex(fixture, "client_confirmation");
        byte[] serverConfirmation = hex(fixture, "server_confirmation");

        assertFalse(PairingAuthenticator.verifyClientConfirmation(
                serverConfirmation,
                confirmationKey,
                originalHash
        ));
        assertFalse(PairingAuthenticator.verifyServerConfirmation(
                clientConfirmation,
                confirmationKey,
                originalHash
        ));

        byte[] changedServerNonce = hex(fixture, "server_nonce");
        changedServerNonce[0] ^= (byte) 0xff;
        byte[] changedTranscript = PairingAuthenticator.transcript(
                1,
                hex(fixture, "pairing_id"),
                hex(fixture, "client_public_key"),
                hex(fixture, "server_public_key"),
                hex(fixture, "device_identity_public_key"),
                hex(fixture, "client_nonce"),
                changedServerNonce,
                fixture.getProperty("client_name"),
                fixture.getProperty("server_name")
        );
        assertFalse(PairingAuthenticator.verifyClientConfirmation(
                clientConfirmation,
                confirmationKey,
                PairingAuthenticator.transcriptHash(changedTranscript)
        ));
    }

    @Test
    public void generatedKeyAgreementIsMutualAndRejectsOffCurvePoint() {
        PairingKeyAgreement client = PairingKeyAgreement.generate();
        PairingKeyAgreement server = PairingKeyAgreement.generate();
        assertArrayEquals(
                client.sharedSecret(server.publicKeyX963Representation()),
                server.sharedSecret(client.publicKeyX963Representation())
        );

        byte[] offCurve = new byte[PairingAuthenticator.PUBLIC_KEY_LENGTH];
        offCurve[0] = 0x04;
        try {
            client.sharedSecret(offCurve);
            fail("expected off-curve public key rejection");
        } catch (IllegalArgumentException expected) {
            // Expected: malformed public points never reach ECDH.
        }
    }

    @Test
    public void deviceIdentitySignatureProvesStablePrivateKeyPossession() throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("EC");
        generator.initialize(new ECGenParameterSpec("secp256r1"));
        KeyPair identity = generator.generateKeyPair();
        byte[] transcript = "pairing-transcript".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        Signature signer = Signature.getInstance("SHA256withECDSA");
        signer.initSign(identity.getPrivate());
        signer.update(transcript);
        byte[] signature = signer.sign();
        byte[] publicKey = PairingKeyAgreement.publicKeyX963Representation(
                (ECPublicKey) identity.getPublic()
        );

        assertTrue(AndroidDeviceIdentity.verifyPairingTranscriptSignature(
                publicKey,
                transcript,
                signature
        ));
        transcript[0] ^= 0x01;
        assertFalse(AndroidDeviceIdentity.verifyPairingTranscriptSignature(
                publicKey,
                transcript,
                signature
        ));
    }

    private static byte[] transcript(Properties fixture) {
        return PairingAuthenticator.transcript(
                Integer.parseInt(fixture.getProperty("version")),
                hex(fixture, "pairing_id"),
                hex(fixture, "client_public_key"),
                hex(fixture, "server_public_key"),
                hex(fixture, "device_identity_public_key"),
                hex(fixture, "client_nonce"),
                hex(fixture, "server_nonce"),
                fixture.getProperty("client_name"),
                fixture.getProperty("server_name")
        );
    }

    private static Properties loadFixture() throws IOException {
        try (InputStream stream = PairingAuthenticatorTest.class.getResourceAsStream(
                "/pairing-v1.properties"
        )) {
            if (stream == null) {
                throw new IOException("pairing fixture is missing from test resources");
            }
            Properties properties = new Properties();
            properties.load(stream);
            return properties;
        }
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
