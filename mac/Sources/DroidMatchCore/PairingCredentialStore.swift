import Foundation
import LocalAuthentication
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

    public init(
        pairingID: Data,
        deviceIdentityFingerprint: Data,
        displayName: String,
        createdAt: Date,
        lastUsedAt: Date
    ) {
        self.pairingID = pairingID
        self.deviceIdentityFingerprint = deviceIdentityFingerprint
        self.displayName = displayName
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public struct PairingCredentialDisplayMetadata: Equatable, Sendable {
    public let pairingID: Data
    public let displayName: String
    public let createdAt: Date
    public let lastUsedAt: Date

    public init(
        pairingID: Data,
        displayName: String,
        createdAt: Date,
        lastUsedAt: Date
    ) {
        self.pairingID = pairingID
        self.displayName = displayName
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

private struct KeychainPairingMetadataEnvelope: Codable {
    static let currentVersion = 1

    let version: Int
    let pairingID: Data
    let deviceIdentityFingerprint: Data
    let displayName: String
    let createdAt: Date
    let lastUsedAt: Date

    init(record: PairingCredentialRecord) {
        version = Self.currentVersion
        pairingID = record.pairingID
        deviceIdentityFingerprint = record.deviceIdentityFingerprint
        displayName = record.displayName
        createdAt = record.createdAt
        lastUsedAt = record.lastUsedAt
    }

    var metadata: PairingCredentialMetadata {
        PairingCredentialMetadata(
            pairingID: pairingID,
            deviceIdentityFingerprint: deviceIdentityFingerprint,
            displayName: displayName,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt
        )
    }
}

public protocol PairingCredentialStoring: AnyObject, Sendable {
    func insertNew(_ record: PairingCredentialRecord) throws
    func save(_ record: PairingCredentialRecord) throws
    func load(pairingID: Data) throws -> PairingCredentialRecord
    func load(deviceIdentityFingerprint: Data) throws -> PairingCredentialRecord?
    func list() throws -> [PairingCredentialMetadata]
    func revoke(pairingID: Data) throws
}

public extension PairingCredentialStoring {
    /// Selects the most recently used credential for one stable device identity.
    /// Concrete secure stores may override this to avoid reading unrelated
    /// secrets while resolving their key-free selector metadata.
    func load(deviceIdentityFingerprint: Data) throws -> PairingCredentialRecord? {
        guard deviceIdentityFingerprint.count == PairingAuthenticator.digestLength else {
            throw PairingCredentialStoreError.invalidLength(
                field: "device identity fingerprint",
                expected: PairingAuthenticator.digestLength,
                actual: deviceIdentityFingerprint.count
            )
        }
        guard let metadata = try list().first(where: {
            $0.deviceIdentityFingerprint == deviceIdentityFingerprint
        }) else {
            return nil
        }
        let record = try load(pairingID: metadata.pairingID)
        guard record.deviceIdentityFingerprint == deviceIdentityFingerprint else {
            throw PairingCredentialStoreError.invalidStoredRecord
        }
        return record
    }
}

public protocol PairingCredentialDisplayMetadataListing: AnyObject, Sendable {
    func listForDisplay() throws -> [PairingCredentialDisplayMetadata]
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
public final class KeychainPairingCredentialStore:
    PairingCredentialStoring,
    PairingCredentialDisplayMetadataListing,
    @unchecked Sendable
{
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
        let metadata = try encoder.encode(KeychainPairingMetadataEnvelope(record: record))
        let account = Self.account(pairingID: record.pairingID)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecAttrLabel as String: record.displayName,
            kSecAttrGeneric as String: metadata,
            kSecValueData as String: encoded,
        ]
        let status = keychain.add(attributes)
        if status == errSecDuplicateItem {
            let updateStatus = keychain.update(
                identityQuery(account: account),
                attributes: [
                    kSecAttrLabel as String: record.displayName,
                    kSecAttrGeneric as String: metadata,
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

    /// Atomically publishes a provisional first-pairing credential. A duplicate
    /// pairing ID is always a collision, even when its fingerprint matches; this
    /// path never reads or updates an existing secret-bearing item.
    public func insertNew(_ record: PairingCredentialRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        let record = try record.validated()
        let encoded = try encoder.encode(record)
        let metadata = try encoder.encode(KeychainPairingMetadataEnvelope(record: record))
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(pairingID: record.pairingID),
            kSecAttrSynchronizable as String: false,
            kSecAttrLabel as String: record.displayName,
            kSecAttrGeneric as String: metadata,
            kSecValueData as String: encoded,
        ]
        let status = keychain.add(attributes)
        if status == errSecDuplicateItem {
            throw PairingCredentialStoreError.duplicatePairingID
        }
        guard status == errSecSuccess else {
            throw PairingCredentialStoreError.keychain(
                operation: "insert provisional pairing",
                status: status
            )
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
        return try loadRecord(account: Self.account(pairingID: pairingID))
    }

    public func load(
        deviceIdentityFingerprint: Data
    ) throws -> PairingCredentialRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard deviceIdentityFingerprint.count == PairingAuthenticator.digestLength else {
            throw PairingCredentialStoreError.invalidLength(
                field: "device identity fingerprint",
                expected: PairingAuthenticator.digestLength,
                actual: deviceIdentityFingerprint.count
            )
        }

        var currentMetadata: [PairingCredentialMetadata] = []
        var legacyAccounts: [String] = []
        for attributes in try listAttributes(operation: "select credential") {
            guard let account = attributes[kSecAttrAccount as String] as? String else {
                throw PairingCredentialStoreError.invalidStoredRecord
            }
            if let data = attributes[kSecAttrGeneric as String] as? Data {
                currentMetadata.append(try decodeAndValidateMetadata(data, account: account))
            } else {
                guard attributes[kSecAttrGeneric as String] == nil else {
                    throw PairingCredentialStoreError.invalidStoredRecord
                }
                // Validate the key-free legacy projection before any secret
                // query. It cannot identify the phone, but malformed attributes
                // must not weaken selection into a best-effort scan.
                _ = try displayMetadata(from: attributes)
                legacyAccounts.append(account)
            }
        }

        if let selected = currentMetadata
            .filter({ $0.deviceIdentityFingerprint == deviceIdentityFingerprint })
            .max(by: { $0.lastUsedAt < $1.lastUsedAt }) {
            let record = try loadRecord(account: Self.account(pairingID: selected.pairingID))
            guard record.deviceIdentityFingerprint == deviceIdentityFingerprint else {
                throw PairingCredentialStoreError.invalidStoredRecord
            }
            return record
        }

        guard !legacyAccounts.isEmpty else { return nil }
        // macOS rejects MatchLimitAll + ReturnData for generic-password items.
        // Resolve legacy accounts with bounded MatchLimitOne queries under one
        // shared LAContext, then backfill every successfully decoded selector so
        // later connections use the current single-record path above.
        let records = try loadLegacyRecords(accounts: legacyAccounts)
        for record in records {
            try persistMetadata(for: record)
        }
        return records
            .filter({ $0.deviceIdentityFingerprint == deviceIdentityFingerprint })
            .max(by: { $0.lastUsedAt < $1.lastUsedAt })
    }

    public func list() throws -> [PairingCredentialMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return try listAttributes(operation: "list")
            .map(metadata(from:))
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    public func listForDisplay() throws -> [PairingCredentialDisplayMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return try listAttributes(
            operation: "list display metadata",
            allowsAuthenticationUI: false
        )
            .map(displayMetadata(from:))
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
        let account = Self.account(pairingID: candidate.pairingID)
        var query = identityQuery(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound {
            return
        }
        guard status == errSecSuccess else {
            throw PairingCredentialStoreError.keychain(
                operation: "check pairing ID collision",
                status: status
            )
        }
        guard let attributes = result as? [String: Any] else {
            throw PairingCredentialStoreError.invalidStoredRecord
        }

        let existingFingerprint: Data
        if let data = attributes[kSecAttrGeneric as String] as? Data {
            existingFingerprint = try decodeAndValidateMetadata(data, account: account)
                .deviceIdentityFingerprint
        } else {
            guard attributes[kSecAttrGeneric as String] == nil else {
                throw PairingCredentialStoreError.invalidStoredRecord
            }
            // Legacy items have no key-free identity selector. Preserve the
            // collision check for them with one exact secret read; once saved,
            // the item receives current metadata and future updates stay
            // key-free.
            existingFingerprint = try loadRecord(account: account).deviceIdentityFingerprint
        }
        guard existingFingerprint == candidate.deviceIdentityFingerprint else {
            throw PairingCredentialStoreError.duplicatePairingID
        }
    }

    private func loadRecord(
        account: String,
        authenticationContext: LAContext? = nil
    ) throws -> PairingCredentialRecord {
        var query = identityQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let authenticationContext {
            query[kSecUseAuthenticationContext as String] = authenticationContext
        }
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound {
            throw PairingCredentialStoreError.notFound
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PairingCredentialStoreError.keychain(operation: "load", status: status)
        }
        return try decodeAndValidate(data)
    }

    private func loadLegacyRecords(accounts: [String]) throws -> [PairingCredentialRecord] {
        let context = LAContext()
        var records: [PairingCredentialRecord] = []
        records.reserveCapacity(accounts.count)
        for account in accounts {
            records.append(try loadRecord(account: account, authenticationContext: context))
        }
        return records
    }

    private func listAttributes(
        operation: String,
        allowsAuthenticationUI: Bool = true
    ) throws -> [[String: Any]] {
        var query = serviceQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        if !allowsAuthenticationUI {
            // Dashboard refresh is passive and display-only. If an old item's
            // access control would require interaction, fail the snapshot
            // instead of summoning a Keychain prompt without user intent.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        let (status, result) = keychain.copyMatching(query)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw PairingCredentialStoreError.keychain(operation: operation, status: status)
        }
        if let value = result as? [String: Any] {
            return [value]
        }
        if let values = result as? [[String: Any]] {
            return values
        }
        throw PairingCredentialStoreError.invalidStoredRecord
    }

    private func metadata(from attributes: [String: Any]) throws -> PairingCredentialMetadata {
        guard let account = attributes[kSecAttrAccount as String] as? String else {
            throw PairingCredentialStoreError.invalidStoredRecord
        }
        if let data = attributes[kSecAttrGeneric as String] as? Data {
            return try decodeAndValidateMetadata(data, account: account)
        }
        guard attributes[kSecAttrGeneric as String] == nil else {
            throw PairingCredentialStoreError.invalidStoredRecord
        }

        // Credential selection happens only after an explicit connection has
        // identified the phone. Backfill a legacy selector at that boundary;
        // the dashboard's display-only listing never enters this path.
        let record = try loadRecord(account: account)
        try persistMetadata(for: record)
        return record.metadata
    }

    private func persistMetadata(for record: PairingCredentialRecord) throws {
        let data = try encoder.encode(KeychainPairingMetadataEnvelope(record: record))
        let status = keychain.update(
            identityQuery(account: Self.account(pairingID: record.pairingID)),
            attributes: [kSecAttrGeneric as String: data]
        )
        guard status == errSecSuccess else {
            throw PairingCredentialStoreError.keychain(
                operation: "migrate metadata",
                status: status
            )
        }
    }

    private func displayMetadata(
        from attributes: [String: Any]
    ) throws -> PairingCredentialDisplayMetadata {
        guard let account = attributes[kSecAttrAccount as String] as? String else {
            throw PairingCredentialStoreError.invalidStoredRecord
        }
        if let data = attributes[kSecAttrGeneric as String] as? Data {
            let metadata = try decodeAndValidateMetadata(data, account: account)
            return PairingCredentialDisplayMetadata(
                pairingID: metadata.pairingID,
                displayName: metadata.displayName,
                createdAt: metadata.createdAt,
                lastUsedAt: metadata.lastUsedAt
            )
        }
        guard attributes[kSecAttrGeneric as String] == nil,
              let pairingID = Self.pairingID(account: account),
              let displayName = attributes[kSecAttrLabel as String] as? String,
              let createdAt = attributes[kSecAttrCreationDate as String] as? Date,
              let lastUsedAt = attributes[kSecAttrModificationDate as String] as? Date else {
            throw PairingCredentialStoreError.invalidStoredRecord
        }
        let displayNameBytes = Data(displayName.utf8).count
        guard displayNameBytes > 0,
              displayNameBytes <= PairingAuthenticator.maximumDisplayNameBytes else {
            throw PairingCredentialStoreError.invalidStoredRecord
        }
        return PairingCredentialDisplayMetadata(
            pairingID: pairingID,
            displayName: displayName,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt
        )
    }

    private func decodeAndValidateMetadata(
        _ data: Data,
        account: String
    ) throws -> PairingCredentialMetadata {
        let envelope: KeychainPairingMetadataEnvelope
        do {
            envelope = try decoder.decode(KeychainPairingMetadataEnvelope.self, from: data)
        } catch {
            throw PairingCredentialStoreError.invalidStoredRecord
        }
        let displayNameBytes = Data(envelope.displayName.utf8).count
        guard envelope.version == KeychainPairingMetadataEnvelope.currentVersion,
              envelope.pairingID.count == PairingAuthenticator.pairingIDLength,
              envelope.deviceIdentityFingerprint.count == PairingAuthenticator.digestLength,
              displayNameBytes > 0,
              displayNameBytes <= PairingAuthenticator.maximumDisplayNameBytes,
              Self.account(pairingID: envelope.pairingID) == account else {
            throw PairingCredentialStoreError.invalidStoredRecord
        }
        return envelope.metadata
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
            kSecAttrSynchronizable as String: false,
        ]
    }

    private static func account(pairingID: Data) -> String {
        pairingID.map { String(format: "%02x", $0) }.joined()
    }

    private static func pairingID(account: String) -> Data? {
        let bytes = Array(account.utf8)
        guard bytes.count == PairingAuthenticator.pairingIDLength * 2 else { return nil }
        var pairingID = Data(capacity: PairingAuthenticator.pairingIDLength)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = hexNibble(bytes[index]),
                  let low = hexNibble(bytes[index + 1]) else { return nil }
            pairingID.append((high << 4) | low)
        }
        return pairingID
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48 ... 57: byte - 48
        case 65 ... 70: byte - 55
        case 97 ... 102: byte - 87
        default: nil
        }
    }
}
