import CryptoKit
import Foundation

public enum SessionAuthenticationError: Error, CustomStringConvertible, Sendable {
    case invalidLength(field: String, expected: Int, actual: Int)

    public var description: String {
        switch self {
        case let .invalidLength(field, expected, actual):
            return "invalid \(field) length: expected \(expected) bytes, got \(actual)"
        }
    }
}

/// Cross-platform session-authentication primitives.
///
/// This type intentionally owns only canonical bytes and standard SHA-256/HMAC/HKDF
/// operations. Pairing storage, protobuf messages, retries, and UI confirmation stay
/// outside so Swift and Java can verify this security-critical core with one fixture.
public enum SessionAuthenticator {
    public static let pairingIDLength = 16
    public static let nonceLength = 32
    public static let pairingKeyLength = 32
    public static let digestLength = 32

    private static let transcriptContext = Data("DroidMatch session auth v1\0".utf8)
    private static let clientProofContext = Data("DroidMatch client proof v1\0".utf8)
    private static let serverProofContext = Data("DroidMatch server proof v1\0".utf8)
    private static let sessionKeyContext = Data("DroidMatch session key v1\0".utf8)

    public static func transcript(
        pairingID: Data,
        clientNonce: Data,
        serverNonce: Data,
        protocolMajor: UInt32,
        protocolMinor: UInt32,
        transport: Droidmatch_V1_TransportKind
    ) throws -> Data {
        try requireLength(pairingID, field: "pairing ID", expected: pairingIDLength)
        try requireLength(clientNonce, field: "client nonce", expected: nonceLength)
        try requireLength(serverNonce, field: "server nonce", expected: nonceLength)

        var result = transcriptContext
        appendLengthPrefixed(pairingID, to: &result)
        appendLengthPrefixed(clientNonce, to: &result)
        appendLengthPrefixed(serverNonce, to: &result)
        appendUInt32(protocolMajor, to: &result)
        appendUInt32(protocolMinor, to: &result)
        appendUInt32(UInt32(transport.rawValue), to: &result)
        return result
    }

    public static func transcriptHash(_ transcript: Data) -> Data {
        Data(SHA256.hash(data: transcript))
    }

    public static func clientProof(pairingKey: Data, transcriptHash: Data) throws -> Data {
        try proof(
            pairingKey: pairingKey,
            transcriptHash: transcriptHash,
            roleContext: clientProofContext
        )
    }

    public static func serverProof(pairingKey: Data, transcriptHash: Data) throws -> Data {
        try proof(
            pairingKey: pairingKey,
            transcriptHash: transcriptHash,
            roleContext: serverProofContext
        )
    }

    public static func verifyClientProof(
        _ candidate: Data,
        pairingKey: Data,
        transcriptHash: Data
    ) throws -> Bool {
        try verifyProof(
            candidate,
            pairingKey: pairingKey,
            transcriptHash: transcriptHash,
            roleContext: clientProofContext
        )
    }

    public static func verifyServerProof(
        _ candidate: Data,
        pairingKey: Data,
        transcriptHash: Data
    ) throws -> Bool {
        try verifyProof(
            candidate,
            pairingKey: pairingKey,
            transcriptHash: transcriptHash,
            roleContext: serverProofContext
        )
    }

    public static func sessionKey(pairingKey: Data, transcriptHash: Data) throws -> Data {
        try requireLength(pairingKey, field: "pairing key", expected: pairingKeyLength)
        try requireLength(transcriptHash, field: "transcript hash", expected: digestLength)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pairingKey),
            salt: transcriptHash,
            info: sessionKeyContext,
            outputByteCount: pairingKeyLength
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    private static func proof(
        pairingKey: Data,
        transcriptHash: Data,
        roleContext: Data
    ) throws -> Data {
        try requireLength(pairingKey, field: "pairing key", expected: pairingKeyLength)
        try requireLength(transcriptHash, field: "transcript hash", expected: digestLength)
        var message = roleContext
        message.append(transcriptHash)
        let code = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: pairingKey)
        )
        return Data(code)
    }

    private static func verifyProof(
        _ candidate: Data,
        pairingKey: Data,
        transcriptHash: Data,
        roleContext: Data
    ) throws -> Bool {
        try requireLength(pairingKey, field: "pairing key", expected: pairingKeyLength)
        try requireLength(transcriptHash, field: "transcript hash", expected: digestLength)
        guard candidate.count == digestLength else {
            return false
        }
        var message = roleContext
        message.append(transcriptHash)
        return HMAC<SHA256>.isValidAuthenticationCode(
            candidate,
            authenticating: message,
            using: SymmetricKey(data: pairingKey)
        )
    }

    private static func requireLength(_ data: Data, field: String, expected: Int) throws {
        guard data.count == expected else {
            throw SessionAuthenticationError.invalidLength(
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
