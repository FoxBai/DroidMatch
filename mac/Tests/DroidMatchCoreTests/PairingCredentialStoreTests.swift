import Foundation
import Security
import Testing
@testable import DroidMatchCore

@Test func keychainPairingStoreSavesUpdatesListsAndRevokesWithoutSync() throws {
    let backend = FakeKeychainAccess()
    let store = KeychainPairingCredentialStore(service: "test.droidmatch.pairing", keychain: backend)
    let pairingID = Data((0..<16).map(UInt8.init))
    let fingerprint = Data(repeating: 0x33, count: 32)
    let createdAt = Date(timeIntervalSince1970: 100)
    let record = try PairingCredentialRecord(
        pairingID: pairingID,
        deviceIdentityFingerprint: fingerprint,
        pairingKey: Data(repeating: 0x44, count: 32),
        displayName: "Pixel Test",
        createdAt: createdAt,
        lastUsedAt: Date(timeIntervalSince1970: 200)
    )

    try store.save(record)
    let loaded = try store.load(pairingID: pairingID)
    #expect(loaded.pairingID == pairingID)
    #expect(loaded.deviceIdentityFingerprint == fingerprint)
    #expect(loaded.pairingKey == Data(repeating: 0x44, count: 32))
    #expect(backend.lastAddedAttributes?[kSecAttrSynchronizable as String] as? Bool == false)

    var renamed = loaded
    renamed.displayName = "Renamed Pixel"
    renamed.lastUsedAt = Date(timeIntervalSince1970: 300)
    try store.save(renamed)
    let metadata = try store.list()
    #expect(metadata.count == 1)
    #expect(metadata[0].displayName == "Renamed Pixel")
    #expect(metadata[0].lastUsedAt == Date(timeIntervalSince1970: 300))

    try store.revoke(pairingID: pairingID)
    #expect(try store.list().isEmpty)
    #expect(throws: PairingCredentialStoreError.self) {
        _ = try store.load(pairingID: pairingID)
    }
}

@Test func keychainPairingStoreRejectsPairingIDCollisionAndMalformedRecords() throws {
    let backend = FakeKeychainAccess()
    let store = KeychainPairingCredentialStore(service: "test.droidmatch.pairing", keychain: backend)
    let pairingID = Data(repeating: 0xaa, count: 16)
    let first = try PairingCredentialRecord(
        pairingID: pairingID,
        deviceIdentityFingerprint: Data(repeating: 0x11, count: 32),
        pairingKey: Data(repeating: 0x22, count: 32),
        displayName: "First"
    )
    let collision = try PairingCredentialRecord(
        pairingID: pairingID,
        deviceIdentityFingerprint: Data(repeating: 0x33, count: 32),
        pairingKey: Data(repeating: 0x44, count: 32),
        displayName: "Collision"
    )
    try store.save(first)
    #expect(throws: PairingCredentialStoreError.self) {
        try store.save(collision)
    }

    #expect(throws: PairingCredentialStoreError.self) {
        _ = try PairingCredentialRecord(
            pairingID: Data(repeating: 0, count: 15),
            deviceIdentityFingerprint: Data(repeating: 0, count: 32),
            pairingKey: Data(repeating: 0, count: 32),
            displayName: "Invalid"
        )
    }
}

private final class FakeKeychainAccess: KeychainAccess {
    private var values: [String: Data] = [:]
    var lastAddedAttributes: [String: Any]?

    func add(_ attributes: [String: Any]) -> OSStatus {
        lastAddedAttributes = attributes
        guard let account = attributes[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data else {
            return errSecParam
        }
        if values[account] != nil {
            return errSecDuplicateItem
        }
        values[account] = data
        return errSecSuccess
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        guard let account = query[kSecAttrAccount as String] as? String,
              values[account] != nil,
              let data = attributes[kSecValueData as String] as? Data else {
            return errSecItemNotFound
        }
        values[account] = data
        return errSecSuccess
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        if let account = query[kSecAttrAccount as String] as? String {
            guard let data = values[account] else {
                return (errSecItemNotFound, nil)
            }
            return (errSecSuccess, data as NSData)
        }
        guard !values.isEmpty else {
            return (errSecItemNotFound, nil)
        }
        return (errSecSuccess, Array(values.values) as NSArray)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        guard let account = query[kSecAttrAccount as String] as? String else {
            return errSecParam
        }
        return values.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
    }
}
