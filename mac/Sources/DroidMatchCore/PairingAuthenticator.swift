import CryptoKit
import Foundation

public enum PairingAuthenticationError: Error, CustomStringConvertible, Sendable {
    case invalidLength(field: String, expected: Int, actual: Int)
    case invalidDisplayName(field: String, byteCount: Int)
    case unsupportedVersion(UInt32)
    case invalidPublicKey
    case sasDerivationExhausted

    public var description: String {
        switch self {
        case let .invalidLength(field, expected, actual):
            return "invalid \(field) length: expected \(expected) bytes, got \(actual)"
        case let .invalidDisplayName(field, byteCount):
            return "invalid \(field): UTF-8 length must be 1...128 bytes, got \(byteCount)"
        case let .unsupportedVersion(version):
            return "unsupported pairing version: \(version)"
        case .invalidPublicKey:
            return "invalid P-256 public key"
        case .sasDerivationExhausted:
            return "could not derive an unbiased short authentication string"
        }
    }
}

/// One ephemeral P-256 key pair for a single first-pairing attempt.
///
/// The private key is intentionally neither Codable nor printable. A pairing
/// attempt must discard this value on rejection, timeout, or transport loss.
public struct PairingEphemeralKeyPair {
    private let privateKey: P256.KeyAgreement.PrivateKey

    public init() {
        privateKey = P256.KeyAgreement.PrivateKey()
    }

    /// Deterministic construction is internal so checked-in vectors can cover
    /// cross-platform ECDH without exposing a product API for importing secrets.
    init(privateKeyRawRepresentation: Data) throws {
        guard privateKeyRawRepresentation.count == PairingAuthenticator.privateKeyLength else {
            throw PairingAuthenticationError.invalidLength(
                field: "P-256 private key",
                expected: PairingAuthenticator.privateKeyLength,
                actual: privateKeyRawRepresentation.count
            )
        }
        privateKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: privateKeyRawRepresentation
        )
    }

    public var publicKeyX963Representation: Data {
        privateKey.publicKey.x963Representation
    }

    public func sharedSecret(peerPublicKeyX963Representation: Data) throws -> Data {
        guard peerPublicKeyX963Representation.count == PairingAuthenticator.publicKeyLength,
              peerPublicKeyX963Representation.first == 0x04 else {
            throw PairingAuthenticationError.invalidPublicKey
        }
        let peer: P256.KeyAgreement.PublicKey
        do {
            peer = try P256.KeyAgreement.PublicKey(
                x963Representation: peerPublicKeyX963Representation
            )
        } catch {
            throw PairingAuthenticationError.invalidPublicKey
        }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { Data($0) }
    }
}

public struct PairingDerivedSecrets: Sendable {
    public let confirmationKey: Data
    public let pairingKey: Data
    public let shortAuthenticationString: String
}

/// Canonical first-pairing transcript and confirmation primitives shared with Android.
public enum PairingAuthenticator {
    public static let version: UInt32 = 1
    public static let privateKeyLength = 32
    public static let publicKeyLength = 65
    public static let nonceLength = 32
    public static let pairingIDLength = 16
    public static let keyLength = 32
    public static let digestLength = 32
    public static let maximumDisplayNameBytes = 128

    private static let transcriptContext = Data("DroidMatch pairing transcript v1\0".utf8)
    private static let confirmationKeyContext = Data("DroidMatch pairing confirmation key v1\0".utf8)
    private static let pairingKeyContext = Data("DroidMatch pairing key v1\0".utf8)
    private static let sasContext = Data("DroidMatch pairing SAS v1\0".utf8)
    private static let clientConfirmationContext = Data("DroidMatch pairing client confirmation v1\0".utf8)
    private static let serverConfirmationContext = Data("DroidMatch pairing server confirmation v1\0".utf8)
    private static let finalConfirmationContext = Data("DroidMatch pairing final confirmation v1\0".utf8)
    private static let sasModulus: UInt32 = 1_000_000
    private static let unbiasedUInt32Limit: UInt32 = 4_294_000_000

    public static func transcript(
        pairingVersion: UInt32,
        pairingID: Data,
        clientPublicKey: Data,
        serverPublicKey: Data,
        deviceIdentityPublicKey: Data,
        clientNonce: Data,
        serverNonce: Data,
        clientName: String,
        serverName: String
    ) throws -> Data {
        guard pairingVersion == version else {
            throw PairingAuthenticationError.unsupportedVersion(pairingVersion)
        }
        try requireLength(pairingID, field: "pairing ID", expected: pairingIDLength)
        try validatePublicKeyShape(clientPublicKey, field: "client public key")
        try validatePublicKeyShape(serverPublicKey, field: "server public key")
        try validatePublicKeyShape(deviceIdentityPublicKey, field: "device identity public key")
        try requireLength(clientNonce, field: "client nonce", expected: nonceLength)
        try requireLength(serverNonce, field: "server nonce", expected: nonceLength)
        let clientNameBytes = try displayNameBytes(clientName, field: "client name")
        let serverNameBytes = try displayNameBytes(serverName, field: "server name")

        var result = transcriptContext
        appendUInt32(pairingVersion, to: &result)
        appendLengthPrefixed(pairingID, to: &result)
        appendLengthPrefixed(clientPublicKey, to: &result)
        appendLengthPrefixed(serverPublicKey, to: &result)
        appendLengthPrefixed(deviceIdentityPublicKey, to: &result)
        appendLengthPrefixed(clientNonce, to: &result)
        appendLengthPrefixed(serverNonce, to: &result)
        appendLengthPrefixed(clientNameBytes, to: &result)
        appendLengthPrefixed(serverNameBytes, to: &result)
        return result
    }

    public static func transcriptHash(_ transcript: Data) -> Data {
        Data(SHA256.hash(data: transcript))
    }

    public static func verifyDeviceIdentitySignature(
        _ signatureDER: Data,
        deviceIdentityPublicKey: Data,
        transcript: Data
    ) throws -> Bool {
        try validatePublicKeyShape(deviceIdentityPublicKey, field: "device identity public key")
        do {
            let publicKey = try P256.Signing.PublicKey(
                x963Representation: deviceIdentityPublicKey
            )
            let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureDER)
            return publicKey.isValidSignature(signature, for: transcript)
        } catch {
            return false
        }
    }

    public static func deriveSecrets(
        sharedSecret: Data,
        transcriptHash: Data
    ) throws -> PairingDerivedSecrets {
        try requireLength(sharedSecret, field: "P-256 shared secret", expected: keyLength)
        try requireLength(transcriptHash, field: "transcript hash", expected: digestLength)
        let confirmationKey = hkdf(
            input: sharedSecret,
            salt: transcriptHash,
            info: confirmationKeyContext
        )
        let pairingKey = hkdf(
            input: sharedSecret,
            salt: transcriptHash,
            info: pairingKeyContext
        )
        return PairingDerivedSecrets(
            confirmationKey: confirmationKey,
            pairingKey: pairingKey,
            shortAuthenticationString: try shortAuthenticationString(
                confirmationKey: confirmationKey,
                transcriptHash: transcriptHash
            )
        )
    }

    public static func clientConfirmation(
        confirmationKey: Data,
        transcriptHash: Data
    ) throws -> Data {
        try confirmation(
            context: clientConfirmationContext,
            suffix: Data([1]),
            confirmationKey: confirmationKey,
            transcriptHash: transcriptHash
        )
    }

    public static func serverConfirmation(
        confirmationKey: Data,
        transcriptHash: Data
    ) throws -> Data {
        try confirmation(
            context: serverConfirmationContext,
            suffix: Data([1, 1]),
            confirmationKey: confirmationKey,
            transcriptHash: transcriptHash
        )
    }

    public static func finalConfirmation(
        confirmationKey: Data,
        transcriptHash: Data,
        serverConfirmation: Data
    ) throws -> Data {
        try requireLength(serverConfirmation, field: "server confirmation", expected: digestLength)
        return try confirmation(
            context: finalConfirmationContext,
            suffix: serverConfirmation,
            confirmationKey: confirmationKey,
            transcriptHash: transcriptHash
        )
    }

    public static func verifyClientConfirmation(
        _ candidate: Data,
        confirmationKey: Data,
        transcriptHash: Data
    ) throws -> Bool {
        try verifyConfirmation(
            candidate,
            context: clientConfirmationContext,
            suffix: Data([1]),
            confirmationKey: confirmationKey,
            transcriptHash: transcriptHash
        )
    }

    public static func verifyServerConfirmation(
        _ candidate: Data,
        confirmationKey: Data,
        transcriptHash: Data
    ) throws -> Bool {
        try verifyConfirmation(
            candidate,
            context: serverConfirmationContext,
            suffix: Data([1, 1]),
            confirmationKey: confirmationKey,
            transcriptHash: transcriptHash
        )
    }

    public static func verifyFinalConfirmation(
        _ candidate: Data,
        confirmationKey: Data,
        transcriptHash: Data,
        serverConfirmation: Data
    ) throws -> Bool {
        try requireLength(serverConfirmation, field: "server confirmation", expected: digestLength)
        return try verifyConfirmation(
            candidate,
            context: finalConfirmationContext,
            suffix: serverConfirmation,
            confirmationKey: confirmationKey,
            transcriptHash: transcriptHash
        )
    }

    private static func shortAuthenticationString(
        confirmationKey: Data,
        transcriptHash: Data
    ) throws -> String {
        var counter: UInt32 = 0
        while true {
            var message = sasContext
            message.append(transcriptHash)
            appendUInt32(counter, to: &message)
            let code = Data(HMAC<SHA256>.authenticationCode(
                for: message,
                using: SymmetricKey(data: confirmationKey)
            ))
            let value = (UInt32(code[0]) << 24)
                | (UInt32(code[1]) << 16)
                | (UInt32(code[2]) << 8)
                | UInt32(code[3])
            if value < unbiasedUInt32Limit {
                return String(format: "%06u", value % sasModulus)
            }
            guard counter != UInt32.max else {
                throw PairingAuthenticationError.sasDerivationExhausted
            }
            counter += 1
        }
    }

    private static func confirmation(
        context: Data,
        suffix: Data,
        confirmationKey: Data,
        transcriptHash: Data
    ) throws -> Data {
        try requireLength(confirmationKey, field: "confirmation key", expected: keyLength)
        try requireLength(transcriptHash, field: "transcript hash", expected: digestLength)
        var message = context
        message.append(transcriptHash)
        message.append(suffix)
        return Data(HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: confirmationKey)
        ))
    }

    private static func verifyConfirmation(
        _ candidate: Data,
        context: Data,
        suffix: Data,
        confirmationKey: Data,
        transcriptHash: Data
    ) throws -> Bool {
        try requireLength(confirmationKey, field: "confirmation key", expected: keyLength)
        try requireLength(transcriptHash, field: "transcript hash", expected: digestLength)
        guard candidate.count == digestLength else {
            return false
        }
        var message = context
        message.append(transcriptHash)
        message.append(suffix)
        return HMAC<SHA256>.isValidAuthenticationCode(
            candidate,
            authenticating: message,
            using: SymmetricKey(data: confirmationKey)
        )
    }

    private static func hkdf(input: Data, salt: Data, info: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: input),
            salt: salt,
            info: info,
            outputByteCount: keyLength
        )
        return key.withUnsafeBytes { Data($0) }
    }

    private static func validatePublicKeyShape(_ key: Data, field: String) throws {
        try requireLength(key, field: field, expected: publicKeyLength)
        guard key.first == 0x04 else {
            throw PairingAuthenticationError.invalidPublicKey
        }
    }

    private static func displayNameBytes(_ name: String, field: String) throws -> Data {
        let data = Data(name.utf8)
        guard !data.isEmpty, data.count <= maximumDisplayNameBytes else {
            throw PairingAuthenticationError.invalidDisplayName(field: field, byteCount: data.count)
        }
        return data
    }

    private static func requireLength(_ data: Data, field: String, expected: Int) throws {
        guard data.count == expected else {
            throw PairingAuthenticationError.invalidLength(
                field: field,
                expected: expected,
                actual: data.count
            )
        }
    }

    private static func appendLengthPrefixed(_ data: Data, to result: inout Data) {
        let length = UInt16(data.count)
        result.append(UInt8((length >> 8) & 0xff))
        result.append(UInt8(length & 0xff))
        result.append(data)
    }

    private static func appendUInt32(_ value: UInt32, to result: inout Data) {
        result.append(UInt8((value >> 24) & 0xff))
        result.append(UInt8((value >> 16) & 0xff))
        result.append(UInt8((value >> 8) & 0xff))
        result.append(UInt8(value & 0xff))
    }
}
