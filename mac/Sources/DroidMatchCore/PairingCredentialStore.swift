import Foundation
import Security

public enum PairingCredentialStoreError: Error, CustomStringConvertible, Sendable {
    case invalidLength(field: String, expected: Int, actual: Int)
    case invalidDisplayName(byteCount: Int)
    case duplicatePairingID
    case notFound
    case keychain(operation: String, status: OSStatus)
    case invalidStoredRecord

    public var description: String {
        switch self {
        case let .invalidLength(field, expected, actual):
            return "invalid \(field) length: expected \(expected) bytes, got \(actual)"
        case let .invalidDisplayName(byteCount):
            return "invalid device display name UTF-8 length: \(byteCount)"
        case .duplicatePairingID:
            return "pairing ID is already associated with another device identity"
        case .notFound:
            return "pairing credential was not found"
        case let .keychain(operation, status):
            return "Keychain \(operation) failed with OSStatus \(status)"
        case .invalidStoredRecord:
            return "Keychain pairing record is malformed"
        }
    }
}

/// One non-synchronizing per-device pairing credential.
///
/// This type intentionally has no textual description so accidental logging does
/// not reveal the key. Callers should expose only `metadata` to UI and diagnostics.
public struct PairingCredentialRecord: Codable, Sendable {
    public let pairingID: Data
    public let deviceIdentityFingerprint: Data
    public let pairingKey: Data
    public var displayName: String
    public let createdAt: Date
    public var lastUsedAt: Date

    public init(
        pairingID: Data,
        deviceIdentityFingerprint: Data,
        pairingKey: Data,
        displayName: String,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) throws {
        try Self.requireLength(
            pairingID,
            field: "pairing ID",
            expected: PairingAuthenticator.pairingIDLength
        )
        try Self.requireLength(
            deviceIdentityFingerprint,
            field: "device identity fingerprint",
            expected: PairingAuthenticator.digestLength
        )
        try Self.requireLength(
            pairingKey,
            field: "pairing key",
            expected: PairingAuthenticator.keyLength
        )
        let displayNameBytes = Data(displayName.utf8).count
        guard displayNameBytes > 0,
              displayNameBytes <= PairingAuthenticator.maximumDisplayNameBytes else {
            throw PairingCredentialStoreError.invalidDisplayName(byteCount: displayNameBytes)
        }
        self.pairingID = pairingID
        self.deviceIdentityFingerprint = deviceIdentityFingerprint
        self.pairingKey = pairingKey
        self.displayName = displayName
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    public var metadata: PairingCredentialMetadata {
        PairingCredentialMetadata(
            pairingID: pairingID,
            deviceIdentityFingerprint: deviceIdentityFingerprint,
            displayName: displayName,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt
        )
    }

    fileprivate func validated() throws -> PairingCredentialRecord {
        try PairingCredentialRecord(
            pairingID: pairingID,
            deviceIdentityFingerprint: deviceIdentityFingerprint,
            pairingKey: pairingKey,
            displayName: displayName,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt
        )
    }

    private static func requireLength(_ data: Data, field: String, expected: Int) throws {
        guard data.count == expected else {
            throw PairingCredentialStoreError.invalidLength(
                field: field,
                expected: expected,
                actual: data.count
            )
        }
    }
}

public struct PairingCredentialMetadata: Equatable, Sendable {
    public let pairingID: Data
    public let deviceIdentityFingerprint: Data
    public let displayName: String
    public let createdAt: Date
    public let lastUsedAt: Date
}

public protocol PairingCredentialStoring: AnyObject, Sendable {
    func save(_ record: PairingCredentialRecord) throws
    func load(pairingID: Data) throws -> PairingCredentialRecord
    func list() throws -> [PairingCredentialMetadata]
    func revoke(pairingID: Data) throws
}

protocol KeychainAccess: AnyObject {
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?)
    func delete(_ query: [String: Any]) -> OSStatus
}

final class SystemKeychainAccess: KeychainAccess {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Keychain-backed, non-synchronizing pairing store for macOS.
public final class KeychainPairingCredentialStore: PairingCredentialStoring, @unchecked Sendable {
    public static let defaultService = "app.droidmatch.pairing.v1"

    private let service: String
    private let keychain: KeychainAccess
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSRecursiveLock()

    public convenience init(service: String = defaultService) {
        self.init(service: service, keychain: SystemKeychainAccess())
    }

    init(service: String, keychain: KeychainAccess) {
        self.service = service
        self.keychain = keychain
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public func save(_ record: PairingCredentialRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        let record = try record.validated()
        try rejectPairingIDCollision(record)
        let encoded = try encoder.encode(record)
        let account = Self.account(pairingID: record.pairingID)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrLabel as String: record.displayName,
            kSecValueData as String: encoded,
        ]
        let status = keychain.add(attributes)
        if status == errSecDuplicateItem {
            let updateStatus = keychain.update(
                identityQuery(account: account),
                attributes: [
                    kSecAttrLabel as String: record.displayName,
                    kSecValueData as String: encoded,
                ]
            )
            guard updateStatus == errSecSuccess else {
                throw PairingCredentialStoreError.keychain(operation: "update", status: updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw PairingCredentialStoreError.keychain(operation: "add", status: status)
        }
    }

    public func load(pairingID: Data) throws -> PairingCredentialRecord {
        lock.lock()
        defer { lock.unlock() }
        guard pairingID.count == PairingAuthenticator.pairingIDLength else {
            throw PairingCredentialStoreError.invalidLength(
                field: "pairing ID",
                expected: PairingAuthenticator.pairingIDLength,
                actual: pairingID.count
            )
        }
        var query = identityQuery(account: Self.account(pairingID: pairingID))
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound {
            throw PairingCredentialStoreError.notFound
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PairingCredentialStoreError.keychain(operation: "load", status: status)
        }
        return try decodeAndValidate(data)
    }

    public func list() throws -> [PairingCredentialMetadata] {
        lock.lock()
        defer { lock.unlock() }
        var query = serviceQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw PairingCredentialStoreError.keychain(operation: "list", status: status)
        }
        let records: [PairingCredentialRecord]
        if let data = result as? Data {
            records = [try decodeAndValidate(data)]
        } else if let values = result as? [Data] {
            records = try values.map(decodeAndValidate)
        } else {
            throw PairingCredentialStoreError.invalidStoredRecord
        }
        return records
            .map(\.metadata)
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    public func revoke(pairingID: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard pairingID.count == PairingAuthenticator.pairingIDLength else {
            throw PairingCredentialStoreError.invalidLength(
                field: "pairing ID",
                expected: PairingAuthenticator.pairingIDLength,
                actual: pairingID.count
            )
        }
        let status = keychain.delete(identityQuery(account: Self.account(pairingID: pairingID)))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PairingCredentialStoreError.keychain(operation: "revoke", status: status)
        }
    }

    private func rejectPairingIDCollision(_ candidate: PairingCredentialRecord) throws {
        do {
            let existing = try load(pairingID: candidate.pairingID)
            guard existing.deviceIdentityFingerprint == candidate.deviceIdentityFingerprint else {
                throw PairingCredentialStoreError.duplicatePairingID
            }
        } catch PairingCredentialStoreError.notFound {
            return
        }
    }

    private func decodeAndValidate(_ data: Data) throws -> PairingCredentialRecord {
        do {
            return try decoder.decode(PairingCredentialRecord.self, from: data).validated()
        } catch let error as PairingCredentialStoreError {
            throw error
        } catch {
            throw PairingCredentialStoreError.invalidStoredRecord
        }
    }

    private func identityQuery(account: String) -> [String: Any] {
        var query = serviceQuery()
        query[kSecAttrAccount as String] = account
        return query
    }

    private func serviceQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private static func account(pairingID: Data) -> String {
        pairingID.map { String(format: "%02x", $0) }.joined()
    }
}
