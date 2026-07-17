import Foundation
import LocalAuthentication
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

    try store.insertNew(record)
    let collision = try PairingCredentialRecord(
        pairingID: pairingID,
        deviceIdentityFingerprint: fingerprint,
        pairingKey: Data(repeating: 0x99, count: 32),
        displayName: "Collision Pixel",
        createdAt: createdAt,
        lastUsedAt: Date(timeIntervalSince1970: 250)
    )
    backend.resetSecretReads()
    var rejectedDuplicateInsert = false
    do {
        try store.insertNew(collision)
    } catch PairingCredentialStoreError.duplicatePairingID {
        rejectedDuplicateInsert = true
    }
    #expect(rejectedDuplicateInsert)
    #expect(backend.updateCount == 0)
    #expect(backend.dataQueryCount == 0)
    #expect(backend.dataReadCount == 0)
    let loaded = try store.load(pairingID: pairingID)
    #expect(loaded.pairingID == pairingID)
    #expect(loaded.deviceIdentityFingerprint == fingerprint)
    #expect(loaded.pairingKey == Data(repeating: 0x44, count: 32))
    #expect(loaded.displayName == "Pixel Test")
    #expect(backend.lastAddedAttributes?[kSecAttrSynchronizable as String] as? Bool == false)

    let rejectedRecord = try PairingCredentialRecord(
        pairingID: Data(repeating: 0x55, count: 16),
        deviceIdentityFingerprint: fingerprint,
        pairingKey: Data(repeating: 0x56, count: 32),
        displayName: "Rejected Pixel"
    )
    backend.nextAddStatus = errSecAuthFailed
    var rejectedUnexpectedStatus = false
    do {
        try store.insertNew(rejectedRecord)
    } catch let PairingCredentialStoreError.keychain(operation, status) {
        rejectedUnexpectedStatus = operation == "insert provisional pairing"
            && status == errSecAuthFailed
    }
    #expect(rejectedUnexpectedStatus)
    #expect(throws: PairingCredentialStoreError.self) {
        _ = try store.load(pairingID: rejectedRecord.pairingID)
    }

    var renamed = loaded
    renamed.displayName = "Renamed Pixel"
    renamed.lastUsedAt = Date(timeIntervalSince1970: 300)
    backend.resetSecretReads()
    try store.save(renamed)
    #expect(backend.dataQueryCount == 0)
    #expect(backend.dataReadCount == 0)
    let metadata = try store.list()
    #expect(metadata.count == 1)
    #expect(metadata[0].displayName == "Renamed Pixel")
    #expect(metadata[0].lastUsedAt == Date(timeIntervalSince1970: 300))
    #expect(backend.dataReadCount == 0)
    #expect(backend.lastCopyMatchingQuery?[kSecUseAuthenticationContext as String] == nil)
    #expect(try store.listForDisplay() == [PairingCredentialDisplayMetadata(
        pairingID: pairingID,
        displayName: "Renamed Pixel",
        createdAt: createdAt,
        lastUsedAt: Date(timeIntervalSince1970: 300)
    )])
    #expect(backend.dataReadCount == 0)
    let displayContext = try #require(
        backend.lastCopyMatchingQuery?[kSecUseAuthenticationContext as String] as? LAContext
    )
    _ = displayContext

    try store.revoke(pairingID: pairingID)
    #expect(try store.list().isEmpty)
    #expect(throws: PairingCredentialStoreError.self) {
        _ = try store.load(pairingID: pairingID)
    }
}

@Test func keychainPairingStoreMigratesLegacyListingMetadataOnlyOnce() throws {
    let backend = FakeKeychainAccess()
    let store = KeychainPairingCredentialStore(service: "test.droidmatch.legacy", keychain: backend)
    let record = try PairingCredentialRecord(
        pairingID: Data(repeating: 0x61, count: 16),
        deviceIdentityFingerprint: Data(repeating: 0x62, count: 32),
        pairingKey: Data(repeating: 0x63, count: 32),
        displayName: "Legacy Pixel",
        createdAt: Date(timeIntervalSince1970: 400),
        lastUsedAt: Date(timeIntervalSince1970: 500)
    )

    try store.save(record)
    backend.removeGenericMetadataFromAllItems()
    backend.dataReadCount = 0

    let displayMetadata = try store.listForDisplay()
    #expect(displayMetadata.count == 1)
    #expect(displayMetadata[0].pairingID == record.pairingID)
    #expect(displayMetadata[0].displayName == record.displayName)
    #expect(backend.dataReadCount == 0)
    #expect(backend.genericMetadataItemCount == 0)

    #expect(try store.list() == [record.metadata])
    #expect(backend.dataReadCount == 1)
    #expect(backend.genericMetadataItemCount == 1)
    #expect(try store.list() == [record.metadata])
    #expect(backend.dataReadCount == 1)
}

@Test func keychainFingerprintSelectionReadsOnlyMatchAndSharesLegacyAuthentication() throws {
    let backend = FakeKeychainAccess()
    let store = KeychainPairingCredentialStore(
        service: "test.droidmatch.fingerprint-selection",
        keychain: backend
    )
    let first = try PairingCredentialRecord(
        pairingID: Data(repeating: 0x21, count: 16),
        deviceIdentityFingerprint: Data(repeating: 0x31, count: 32),
        pairingKey: Data(repeating: 0x41, count: 32),
        displayName: "First Pixel",
        lastUsedAt: Date(timeIntervalSince1970: 100)
    )
    let selected = try PairingCredentialRecord(
        pairingID: Data(repeating: 0x22, count: 16),
        deviceIdentityFingerprint: Data(repeating: 0x32, count: 32),
        pairingKey: Data(repeating: 0x42, count: 32),
        displayName: "Selected Pixel",
        lastUsedAt: Date(timeIntervalSince1970: 200)
    )
    try store.save(first)
    try store.save(selected)

    backend.resetSecretReads()
    #expect(
        try store.load(deviceIdentityFingerprint: selected.deviceIdentityFingerprint)?.pairingID
            == selected.pairingID
    )
    #expect(backend.dataQueryCount == 1)
    #expect(backend.dataReadCount == 1)

    backend.removeGenericMetadataFromAllItems()
    backend.resetSecretReads()
    #expect(
        try store.load(deviceIdentityFingerprint: selected.deviceIdentityFingerprint)?.pairingID
            == selected.pairingID
    )
    #expect(backend.dataQueryCount == 2)
    #expect(backend.dataReadCount == 2)
    #expect(backend.genericMetadataItemCount == 2)
    #expect(backend.dataAuthenticationContexts.count == 2)
    let firstContext = try #require(backend.dataAuthenticationContexts.first)
    #expect(backend.dataAuthenticationContexts.allSatisfy { $0 === firstContext })

    backend.resetSecretReads()
    #expect(
        try store.load(deviceIdentityFingerprint: selected.deviceIdentityFingerprint)?.pairingID
            == selected.pairingID
    )
    #expect(backend.dataQueryCount == 1)
    #expect(backend.dataReadCount == 1)
    #expect(backend.genericMetadataItemCount == 2)

    #expect(try store.load(deviceIdentityFingerprint: Data(repeating: 0xff, count: 32)) == nil)
    #expect(throws: PairingCredentialStoreError.self) {
        _ = try store.load(deviceIdentityFingerprint: Data(repeating: 0xff, count: 31))
    }
}

@Test func keychainDisplayMetadataQueryDisablesAuthenticationUIWithoutReadingSecret() throws {
    let backend = FakeKeychainAccess()
    let store = KeychainPairingCredentialStore(
        service: "test.droidmatch.display-only",
        keychain: backend
    )
    let record = try PairingCredentialRecord(
        pairingID: Data(repeating: 0x71, count: 16),
        deviceIdentityFingerprint: Data(repeating: 0x72, count: 32),
        pairingKey: Data(repeating: 0x73, count: 32),
        displayName: "Display-only Pixel"
    )
    try store.save(record)
    backend.dataReadCount = 0

    #expect(try store.listForDisplay().map(\.pairingID) == [record.pairingID])
    #expect(backend.dataReadCount == 0)
    let query = try #require(backend.lastCopyMatchingQuery)
    #expect(query[kSecReturnAttributes as String] as? Bool == true)
    #expect(query[kSecReturnData as String] == nil)
    let context = try #require(
        query[kSecUseAuthenticationContext as String] as? LAContext
    )
    _ = context
}

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["DROIDMATCH_RUN_SYSTEM_KEYCHAIN_TEST"] == "1",
        "Set DROIDMATCH_RUN_SYSTEM_KEYCHAIN_TEST=1 to access the current login Keychain."
    )
)
func systemKeychainPairingStoreRoundTripsThroughSecurityFramework() throws {
    // The fake backend cannot detect platform query-compatibility errors. Use a
    // unique service in the current test login Keychain to cover the real
    // Security.framework query shape without inspecting unrelated records.
    let service = "test.droidmatch.pairing.\(UUID().uuidString)"
    let store = KeychainPairingCredentialStore(service: service)
    let pairingID = Data((0..<PairingAuthenticator.pairingIDLength).map { _ in
        UInt8.random(in: .min ... .max)
    })
    defer { try? store.revoke(pairingID: pairingID) }

    #expect(try store.list().isEmpty)
    let record = try PairingCredentialRecord(
        pairingID: pairingID,
        deviceIdentityFingerprint: Data(repeating: 0x51, count: PairingAuthenticator.digestLength),
        pairingKey: Data(repeating: 0x52, count: PairingAuthenticator.keyLength),
        displayName: "DroidMatch Keychain Integration"
    )
    try store.save(record)

    let loaded = try store.load(pairingID: pairingID)
    #expect(loaded.pairingID == pairingID)
    #expect(loaded.deviceIdentityFingerprint == record.deviceIdentityFingerprint)
    #expect(loaded.pairingKey == record.pairingKey)
    #expect(try store.list().map(\.pairingID) == [pairingID])
    #expect(try store.listForDisplay().map(\.pairingID) == [pairingID])

    try store.revoke(pairingID: pairingID)
    #expect(try store.list().isEmpty)
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
    backend.replaceGenericMetadataForAllItems(with: Data("not metadata".utf8))
    backend.dataReadCount = 0
    #expect(throws: PairingCredentialStoreError.self) {
        _ = try store.list()
    }
    #expect(throws: PairingCredentialStoreError.self) {
        _ = try store.listForDisplay()
    }
    #expect(backend.dataReadCount == 0)
    backend.removeGenericMetadataFromAllItems()
    backend.replaceOnlyAccount(with: "not-a-hex-pairing-id")
    #expect(throws: PairingCredentialStoreError.self) {
        _ = try store.listForDisplay()
    }
    #expect(backend.dataReadCount == 0)

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
    private var values: [String: [String: Any]] = [:]
    var lastAddedAttributes: [String: Any]?
    var lastCopyMatchingQuery: [String: Any]?
    var lastDataQuery: [String: Any]?
    var dataAuthenticationContexts: [LAContext] = []
    var nextAddStatus: OSStatus?
    var updateCount = 0
    var dataQueryCount = 0
    var dataReadCount = 0
    var genericMetadataItemCount: Int {
        values.values.filter { $0[kSecAttrGeneric as String] != nil }.count
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lastAddedAttributes = attributes
        if let status = nextAddStatus {
            nextAddStatus = nil
            return status
        }
        guard let account = attributes[kSecAttrAccount as String] as? String,
              attributes[kSecValueData as String] is Data else {
            return errSecParam
        }
        if values[account] != nil {
            return errSecDuplicateItem
        }
        var stored = attributes
        let now = Date()
        stored[kSecAttrCreationDate as String] = now
        stored[kSecAttrModificationDate as String] = now
        values[account] = stored
        return errSecSuccess
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updateCount += 1
        guard let account = query[kSecAttrAccount as String] as? String,
              var stored = values[account] else {
            return errSecItemNotFound
        }
        for (key, value) in attributes {
            stored[key] = value
        }
        stored[kSecAttrModificationDate as String] = Date()
        values[account] = stored
        return errSecSuccess
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        lastCopyMatchingQuery = query
        if let account = query[kSecAttrAccount as String] as? String {
            guard let stored = values[account] else {
                return (errSecItemNotFound, nil)
            }
            if query[kSecReturnData as String] as? Bool == true,
               let data = stored[kSecValueData as String] as? Data {
                lastDataQuery = query
                if let context = query[kSecUseAuthenticationContext as String] as? LAContext {
                    dataAuthenticationContexts.append(context)
                }
                dataQueryCount += 1
                dataReadCount += 1
                return (errSecSuccess, data as NSData)
            }
            return (errSecSuccess, stored as NSDictionary)
        }
        guard !values.isEmpty else {
            return (errSecItemNotFound, nil)
        }
        if query[kSecReturnAttributes as String] as? Bool == true {
            let attributes = values.values.map { stored in
                stored.filter { $0.key != kSecValueData as String }
            }
            return (errSecSuccess, attributes as NSArray)
        }
        let data = values.values.compactMap {
            $0[kSecValueData as String] as? Data
        }
        if query[kSecReturnData as String] as? Bool == true {
            lastDataQuery = query
            if let context = query[kSecUseAuthenticationContext as String] as? LAContext {
                dataAuthenticationContexts.append(context)
            }
            dataQueryCount += 1
            dataReadCount += data.count
        }
        return (errSecSuccess, data as NSArray)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        guard let account = query[kSecAttrAccount as String] as? String else {
            return errSecParam
        }
        return values.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
    }

    func removeGenericMetadataFromAllItems() {
        for account in values.keys {
            values[account]?.removeValue(forKey: kSecAttrGeneric as String)
        }
    }

    func resetSecretReads() {
        lastDataQuery = nil
        dataAuthenticationContexts = []
        dataQueryCount = 0
        dataReadCount = 0
    }

    func replaceGenericMetadataForAllItems(with data: Data) {
        for account in values.keys {
            values[account]?[kSecAttrGeneric as String] = data
        }
    }

    func replaceOnlyAccount(with account: String) {
        guard values.count == 1,
              let oldAccount = values.keys.first,
              var stored = values.removeValue(forKey: oldAccount) else { return }
        stored[kSecAttrAccount as String] = account
        values[account] = stored
    }
}
