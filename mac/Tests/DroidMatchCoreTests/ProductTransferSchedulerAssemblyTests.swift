@_spi(DroidMatchAppSupport) @testable import DroidMatchCore
import Foundation
import Testing

@Test func transferAssemblyRejectsMissingCredentialBeforeCreatingLocalAuthority() throws {
    let selectedFingerprint = Data(
        repeating: 0x41,
        count: PairingAuthenticator.digestLength
    )
    let unrelatedRecord = try sessionCredentialRecord(
        fingerprint: Data(repeating: 0x42, count: PairingAuthenticator.digestLength)
    )
    let accessProviders = LocalFileAccessProviderFactoryProbe()

    #expect(throws: ProductDeviceSessionError.credentialsUnavailable) {
        _ = try transferAssembly(
            selectedFingerprint: selectedFingerprint,
            credentialStore: SessionCredentialStoreProbe(records: [unrelatedRecord]),
            accessProviders: accessProviders
        )
    }
    #expect(accessProviders.ownerIDs().isEmpty)
}

@Test func transferAssemblyRejectsLoadedCredentialFingerprintDrift() throws {
    let selectedFingerprint = Data(
        repeating: 0x51,
        count: PairingAuthenticator.digestLength
    )
    let selectedRecord = try sessionCredentialRecord(fingerprint: selectedFingerprint)
    let changedRecord = try sessionCredentialRecord(
        fingerprint: Data(repeating: 0x52, count: PairingAuthenticator.digestLength)
    )
    let accessProviders = LocalFileAccessProviderFactoryProbe()

    #expect(throws: ProductDeviceSessionError.credentialsUnavailable) {
        _ = try transferAssembly(
            selectedFingerprint: selectedFingerprint,
            credentialStore: SessionCredentialStoreProbe(
                records: [changedRecord],
                listedMetadata: [selectedRecord.metadata]
            ),
            accessProviders: accessProviders
        )
    }
    #expect(accessProviders.ownerIDs().isEmpty)
}

@Test func transferAssemblyValidatesPersistenceBeforeCreatingLocalAuthority() throws {
    let fingerprint = Data(repeating: 0x61, count: PairingAuthenticator.digestLength)
    let record = try sessionCredentialRecord(fingerprint: fingerprint)
    let accessProviders = LocalFileAccessProviderFactoryProbe()
    let invalidPersistenceURL = try #require(URL(string: "https://invalid/queue.json"))

    #expect(throws: TransferQueuePersistenceStoreError.invalidLocation) {
        _ = try transferAssembly(
            selectedFingerprint: fingerprint,
            credentialStore: SessionCredentialStoreProbe(records: [record]),
            persistenceURL: invalidPersistenceURL,
            accessProviders: accessProviders
        )
    }
    #expect(accessProviders.ownerIDs().isEmpty)
}

@Test func transferAssemblyBuildsBothModesForTheAuthenticatedOwner() throws {
    let fingerprint = Data(repeating: 0x71, count: PairingAuthenticator.digestLength)
    let record = try sessionCredentialRecord(fingerprint: fingerprint)
    let store = SessionCredentialStoreProbe(records: [record])
    let expectedOwnerID = try #require(LocalFileAccessOwnerID(
        authenticatedDeviceFingerprint: fingerprint
    ))

    let transientProviders = LocalFileAccessProviderFactoryProbe()
    let transient = try transferAssembly(
        selectedFingerprint: fingerprint,
        credentialStore: store,
        accessProviders: transientProviders
    )
    #expect(transient.persistenceStore == nil)
    #expect(transient.localFileAccessOwnerID == expectedOwnerID)
    #expect(transientProviders.ownerIDs() == [expectedOwnerID])
    #expect(transient.makeTransientScheduler().localFileAccessOwnerID == expectedOwnerID)

    let persistentProviders = LocalFileAccessProviderFactoryProbe()
    let persistent = try transferAssembly(
        selectedFingerprint: fingerprint,
        credentialStore: store,
        persistenceURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false),
        accessProviders: persistentProviders
    )
    #expect(persistent.persistenceStore != nil)
    #expect(persistent.localFileAccessOwnerID == expectedOwnerID)
    #expect(persistentProviders.ownerIDs() == [expectedOwnerID])
}

private func transferAssembly(
    selectedFingerprint: Data,
    credentialStore: any PairingCredentialStoring,
    persistenceURL: URL? = nil,
    accessProviders: LocalFileAccessProviderFactoryProbe
) throws -> ProductTransferSchedulerAssembly {
    try ProductTransferSchedulerAssembly(
        lease: DeviceConnectionLease(
            deviceID: UUID(),
            host: "127.0.0.1",
            port: 45_602
        ),
        selectedFingerprint: selectedFingerprint,
        credentialStore: credentialStore,
        persistenceURL: persistenceURL,
        localFileAccessProviderFactory: { ownerID in
            accessProviders.make(ownerID: ownerID)
        }
    )
}
