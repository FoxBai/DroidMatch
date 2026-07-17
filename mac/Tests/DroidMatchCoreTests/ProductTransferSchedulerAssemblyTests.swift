@_spi(DroidMatchAppSupport) @testable import DroidMatchCore
import Foundation
import Testing

@Test func transferAssemblyRejectsInvalidSelectedIdentityBeforeCreatingLocalAuthority() throws {
    let selectedFingerprint = Data(
        repeating: 0x41,
        count: PairingAuthenticator.digestLength - 1
    )
    let record = try sessionCredentialRecord(
        fingerprint: Data(repeating: 0x42, count: PairingAuthenticator.digestLength)
    )
    let accessProviders = LocalFileAccessProviderFactoryProbe()

    #expect(throws: ProductDeviceSessionError.noPreparedDevice) {
        _ = try transferAssembly(
            selectedFingerprint: selectedFingerprint,
            record: record,
            accessProviders: accessProviders
        )
    }
    #expect(accessProviders.ownerIDs().isEmpty)
}

@Test func transferAssemblyRejectsAuthenticatedCredentialFingerprintMismatch() throws {
    let selectedFingerprint = Data(
        repeating: 0x51,
        count: PairingAuthenticator.digestLength
    )
    let changedRecord = try sessionCredentialRecord(
        fingerprint: Data(repeating: 0x52, count: PairingAuthenticator.digestLength)
    )
    let accessProviders = LocalFileAccessProviderFactoryProbe()

    #expect(throws: ProductDeviceSessionError.credentialsUnavailable) {
        _ = try transferAssembly(
            selectedFingerprint: selectedFingerprint,
            record: changedRecord,
            accessProviders: accessProviders
        )
    }
    #expect(accessProviders.ownerIDs().isEmpty)
}

@Test func transferAssemblyValidatesPersistenceBeforeCreatingLocalAuthority() throws {
    let fingerprint = Data(repeating: 0x61, count: PairingAuthenticator.digestLength)
    let record = try sessionCredentialRecord(fingerprint: fingerprint)
    let accessProviders = LocalFileAccessProviderFactoryProbe()
    let invalidPersistenceDirectoryURL = try #require(URL(string: "https://invalid/state"))

    #expect(throws: TransferQueuePersistenceStoreError.invalidLocation) {
        _ = try transferAssembly(
            selectedFingerprint: fingerprint,
            record: record,
            persistenceDirectoryURL: invalidPersistenceDirectoryURL,
            accessProviders: accessProviders
        )
    }
    #expect(accessProviders.ownerIDs().isEmpty)
}

@Test func transferAssemblyBuildsBothModesForTheAuthenticatedOwner() async throws {
    let fingerprint = LocalFrameTestServer.pairedDeviceIdentityFingerprint
    let record = try sessionCredentialRecord(
        fingerprint: fingerprint,
        pairingID: Data(repeating: 0x73, count: PairingAuthenticator.pairingIDLength),
        pairingKey: Data(repeating: 0x74, count: PairingAuthenticator.keyLength)
    )
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.pairedAuthenticationHandler(
        pairingID: record.pairingID,
        pairingKey: record.pairingKey
    ))
    defer { server.cancel() }
    let expectedOwnerID = try #require(LocalFileAccessOwnerID(
        authenticatedDeviceFingerprint: fingerprint
    ))

    let transientProviders = LocalFileAccessProviderFactoryProbe()
    let transient = try transferAssembly(
        selectedFingerprint: fingerprint,
        record: record,
        port: server.port,
        accessProviders: transientProviders
    )
    #expect(transient.persistenceStore == nil)
    #expect(transient.localFileAccessOwnerID == expectedOwnerID)
    #expect(transientProviders.ownerIDs() == [expectedOwnerID])
    #expect(transient.makeTransientScheduler().localFileAccessOwnerID == expectedOwnerID)
    let client = try await transient.gate.makeClient(attemptIndex: 0)
    let handshake = try await client.handshake()
    #expect(handshake.authenticationState == .authenticated)
    await client.close()
    await transient.gate.invalidate()

    let persistentProviders = LocalFileAccessProviderFactoryProbe()
    let persistent = try transferAssembly(
        selectedFingerprint: fingerprint,
        record: record,
        persistenceDirectoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true),
        accessProviders: persistentProviders
    )
    #expect(persistent.persistenceStore != nil)
    #expect(persistent.localFileAccessOwnerID == expectedOwnerID)
    #expect(persistentProviders.ownerIDs() == [expectedOwnerID])
}

@Test func transferAssemblyRestoresFromTheMigratedLegacyQueueLocation() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fingerprint = Data(repeating: 0x72, count: PairingAuthenticator.digestLength)
    let record = try sessionCredentialRecord(fingerprint: fingerprint)
    let legacyURL = try #require(ProductTransferPersistenceLocation.legacyURL(
        directory: directory,
        fingerprint: fingerprint
    ))
    let currentURL = try #require(ProductTransferPersistenceLocation.currentURL(
        directory: directory,
        fingerprint: fingerprint
    ))
    let manifest = PersistedTransferQueue(jobs: [persistedDownloadJob(
        id: UUID(),
        sequence: 0,
        label: "legacy-product-queue",
        state: .paused
    )])
    try TransferQueuePersistenceStore(fileURL: legacyURL).save(manifest)
    let accessProviders = LocalFileAccessProviderFactoryProbe()

    let assembly = try transferAssembly(
        selectedFingerprint: fingerprint,
        record: record,
        persistenceDirectoryURL: directory,
        accessProviders: accessProviders
    )

    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    #expect(FileManager.default.fileExists(atPath: currentURL.path))
    #expect(try assembly.persistenceStore?.load() == manifest)
    #expect(accessProviders.ownerIDs().count == 1)
}

private func transferAssembly(
    selectedFingerprint: Data,
    record: PairingCredentialRecord,
    port: Int = 45_602,
    persistenceDirectoryURL: URL? = nil,
    accessProviders: LocalFileAccessProviderFactoryProbe
) throws -> ProductTransferSchedulerAssembly {
    try ProductTransferSchedulerAssembly(
        lease: DeviceConnectionLease(
            deviceID: UUID(),
            host: "127.0.0.1",
            port: port
        ),
        selectedFingerprint: selectedFingerprint,
        credentials: try PairingCredentials(
            pairingID: record.pairingID,
            pairingKey: record.pairingKey,
            deviceIdentityFingerprint: record.deviceIdentityFingerprint
        ),
        persistenceDirectoryURL: persistenceDirectoryURL,
        localFileAccessProviderFactory: { ownerID in
            accessProviders.make(ownerID: ownerID)
        }
    )
}
