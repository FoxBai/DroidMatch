package app.droidmatch.m1;

import java.math.BigInteger;
import java.security.AlgorithmParameters;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECFieldFp;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPoint;
import java.security.spec.ECPrivateKeySpec;
import java.security.spec.ECPublicKeySpec;
import java.util.Arrays;

import javax.crypto.KeyAgreement;

/** Platform P-256 ECDH wrapper for one ephemeral first-pairing attempt. */
public final class PairingKeyAgreement {
    private final PrivateKey privateKey;
    private final ECPublicKey publicKey;

    private PairingKeyAgreement(PrivateKey privateKey, ECPublicKey publicKey) {
        this.privateKey = privateKey;
        this.publicKey = publicKey;
    }

    public static PairingKeyAgreement generate() {
        try {
            KeyPairGenerator generator = KeyPairGenerator.getInstance("EC");
            generator.initialize(new ECGenParameterSpec("secp256r1"));
            KeyPair keyPair = generator.generateKeyPair();
            return new PairingKeyAgreement(keyPair.getPrivate(), (ECPublicKey) keyPair.getPublic());
        } catch (GeneralSecurityException exception) {
            throw new IllegalStateException("P-256 key generation is unavailable", exception);
        }
    }

    static PairingKeyAgreement fromRawForTest(byte[] privateScalar, byte[] publicKeyX963) {
        requireLength(privateScalar, "P-256 private key", PairingAuthenticator.PRIVATE_KEY_LENGTH);
        try {
            ECParameterSpec parameters = parameters();
            BigInteger scalar = new BigInteger(1, privateScalar);
            if (scalar.signum() <= 0 || scalar.compareTo(parameters.getOrder()) >= 0) {
                throw new IllegalArgumentException("invalid P-256 private scalar");
            }
            KeyFactory factory = KeyFactory.getInstance("EC");
            PrivateKey privateKey = factory.generatePrivate(new ECPrivateKeySpec(scalar, parameters));
            ECPublicKey publicKey = (ECPublicKey) parsePublicKey(publicKeyX963, parameters, factory);
            return new PairingKeyAgreement(privateKey, publicKey);
        } catch (GeneralSecurityException exception) {
            throw new IllegalArgumentException("invalid P-256 test key", exception);
        }
    }

    public byte[] publicKeyX963Representation() {
        return publicKeyX963Representation(publicKey);
    }

    static byte[] publicKeyX963Representation(ECPublicKey publicKey) {
        byte[] result = new byte[PairingAuthenticator.PUBLIC_KEY_LENGTH];
        result[0] = 0x04;
        copyCoordinate(publicKey.getW().getAffineX(), result, 1);
        copyCoordinate(publicKey.getW().getAffineY(), result, 33);
        return result;
    }

    static PublicKey publicKeyFromX963(byte[] x963) {
        try {
            return parsePublicKey(x963, parameters(), KeyFactory.getInstance("EC"));
        } catch (GeneralSecurityException exception) {
            throw new IllegalArgumentException("invalid P-256 public key", exception);
        }
    }

    public byte[] sharedSecret(byte[] peerPublicKeyX963) {
        try {
            PublicKey peer = parsePublicKey(peerPublicKeyX963, parameters(), KeyFactory.getInstance("EC"));
            KeyAgreement agreement = KeyAgreement.getInstance("ECDH");
            agreement.init(privateKey);
            agreement.doPhase(peer, true);
            byte[] secret = agreement.generateSecret();
            requireLength(secret, "P-256 shared secret", PairingAuthenticator.KEY_LENGTH);
            return secret;
        } catch (GeneralSecurityException exception) {
            throw new IllegalArgumentException("invalid P-256 peer public key", exception);
        }
    }

    private static PublicKey parsePublicKey(
            byte[] x963,
            ECParameterSpec parameters,
            KeyFactory factory
    ) throws GeneralSecurityException {
        requireLength(x963, "P-256 public key", PairingAuthenticator.PUBLIC_KEY_LENGTH);
        if (x963[0] != 0x04) {
            throw new IllegalArgumentException("P-256 public key must use uncompressed X9.63 form");
        }
        BigInteger x = new BigInteger(1, Arrays.copyOfRange(x963, 1, 33));
        BigInteger y = new BigInteger(1, Arrays.copyOfRange(x963, 33, 65));
        validatePoint(x, y, parameters);
        return factory.generatePublic(new ECPublicKeySpec(new ECPoint(x, y), parameters));
    }

    private static void validatePoint(BigInteger x, BigInteger y, ECParameterSpec parameters) {
        BigInteger prime = ((ECFieldFp) parameters.getCurve().getField()).getP();
        if (x.signum() < 0 || y.signum() < 0 || x.compareTo(prime) >= 0 || y.compareTo(prime) >= 0) {
            throw new IllegalArgumentException("P-256 point coordinate is out of range");
        }
        BigInteger left = y.multiply(y).mod(prime);
        BigInteger right = x.multiply(x).multiply(x)
                .add(parameters.getCurve().getA().multiply(x))
                .add(parameters.getCurve().getB())
                .mod(prime);
        if (!left.equals(right)) {
            throw new IllegalArgumentException("P-256 point is not on the curve");
        }
    }

    private static ECParameterSpec parameters() throws GeneralSecurityException {
        AlgorithmParameters parameters = AlgorithmParameters.getInstance("EC");
        parameters.init(new ECGenParameterSpec("secp256r1"));
        return parameters.getParameterSpec(ECParameterSpec.class);
    }

    private static void copyCoordinate(BigInteger coordinate, byte[] destination, int offset) {
        byte[] raw = coordinate.toByteArray();
        int sourceOffset = raw.length > 32 ? raw.length - 32 : 0;
        int length = raw.length - sourceOffset;
        if (length > 32) {
            throw new IllegalStateException("P-256 coordinate exceeds 32 bytes");
        }
        System.arraycopy(raw, sourceOffset, destination, offset + 32 - length, length);
    }

    private static void requireLength(byte[] value, String field, int expected) {
        if (value.length != expected) {
            throw new IllegalArgumentException(
                    "invalid " + field + " length: expected " + expected + " bytes, got " + value.length
            );
        }
    }
}
