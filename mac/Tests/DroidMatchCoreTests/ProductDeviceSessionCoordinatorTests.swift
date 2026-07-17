@_spi(DroidMatchAppSupport) @testable import DroidMatchCore
import Foundation
import Testing

@Test func productTransferPersistenceIsIsolatedByAuthenticatedDeviceIdentity() {
    let directory = URL(fileURLWithPath: "/tmp/droidmatch-product-queues", isDirectory: true)
    let firstFingerprint = Data(repeating: 0x0a, count: PairingAuthenticator.digestLength)
    let secondFingerprint = Data(repeating: 0x0b, count: PairingAuthenticator.digestLength)

    let first = ProductDeviceSessionCoordinator.transferPersistenceURL(
        directory: directory,
        fingerprint: firstFingerprint
    )
    let second = ProductDeviceSessionCoordinator.transferPersistenceURL(
        directory: directory,
        fingerprint: secondFingerprint
    )

    #expect(first != second)
    #expect(first?.deletingLastPathComponent() == directory)
    let rawFingerprint = String(repeating: "0a", count: 32)
    #expect(first?.lastPathComponent.hasPrefix("queue-route-v2-") == true)
    #expect(first?.lastPathComponent.contains(rawFingerprint) == false)
    #expect(ProductDeviceSessionCoordinator.transferPersistenceURL(
        directory: nil,
        fingerprint: firstFingerprint
    ) == nil)
    #expect(ProductDeviceSessionCoordinator.transferPersistenceURL(
        directory: directory,
        fingerprint: Data()
    ) == nil)
}

@Test func productRestorationDefersQueuedWorkWhenLocalAuthorityDoesNotCoverTarget() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let deviceID = UUID()
    let fingerprint = Data(repeating: 0x19, count: PairingAuthenticator.digestLength)
    let record = try sessionCredentialRecord(fingerprint: fingerprint)
    let queueURL = try #require(ProductDeviceSessionCoordinator.transferPersistenceURL(
        directory: directory,
        fingerprint: fingerprint
    ))
    let destinationURL = directory.appendingPathComponent("restored.bin")
    let jobID = UUID()
    let persistenceStore = try TransferQueuePersistenceStore(fileURL: queueURL)
    try persistenceStore.save(PersistedTransferQueue(jobs: [PersistedTransferJob(
        id: jobID,
        sequence: 0,
        request: PersistedTransferRequest(.download(AsyncDownloadCoordinatorRequest(
            sourcePath: "dm://app-sandbox/restored.bin",
            destinationURL: destinationURL
        ))),
        state: .queued,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )]))
    let preparer = SessionConnectionPreparerProbe(deviceID: deviceID)
    let sessions = SessionClientFactoryProbe(fingerprint: fingerprint)
    let localAccess = SessionLocalAccessProbe(ready: true, coveredTargetURLs: [])
    #expect(await localAccess.isReadyForTransferExecution())
    #expect(!(await localAccess.isReadyForTransferExecution(targetURLs: [destinationURL])))
    let coordinator = ProductDeviceSessionCoordinator(
        connectionPreparer: preparer,
        credentialStore: SessionCredentialStoreProbe(records: [record]),
        identityProbe: { _ in fingerprint },
        sessionFactory: { lease, credentials in
            await sessions.make(lease: lease, credentials: credentials)
        },
        pairingFactory: { _, _ in throw ProductDeviceSessionError.pairingNotRequired },
        transferPersistenceDirectoryURL: directory,
        localFileAccessProviderFactory: { _ in localAccess }
    )

    guard case .ready = try await coordinator.connect(to: deviceID) else {
        Issue.record("expected authenticated session")
        return
    }
    let scheduler = try await coordinator.transferScheduler()
    #expect(try await scheduler.snapshot(for: jobID).state == .queued)
    #expect(await scheduler.persistenceStatus() == .writeFailed)
    #expect(await localAccess.acquisitionCount() == 0)
    await coordinator.disconnect()
}

@Test func productRestorationReloadsManifestBeforeConsultingLocalAuthority() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let deviceID = UUID()
    let fingerprint = Data(repeating: 0x29, count: PairingAuthenticator.digestLength)
    let record = try sessionCredentialRecord(fingerprint: fingerprint)
    let queueURL = try #require(ProductDeviceSessionCoordinator.transferPersistenceURL(
        directory: directory,
        fingerprint: fingerprint
    ))
    let persistenceStore = try TransferQueuePersistenceStore(fileURL: queueURL)
    let queuedID = UUID()
    try persistenceStore.save(PersistedTransferQueue(jobs: [PersistedTransferJob(
        id: queuedID,
        sequence: 0,
        request: PersistedTransferRequest(.download(AsyncDownloadCoordinatorRequest(
            sourcePath: "dm://app-sandbox/repaired.bin",
            destinationURL: directory.appendingPathComponent("repaired.bin")
        ))),
        state: .queued,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )]))
    let repairedManifest = try Data(contentsOf: queueURL)
    let corruptManifest = Data("corrupt-product-manifest".utf8)
    try corruptManifest.write(to: queueURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: queueURL.path
    )
    let preparer = SessionConnectionPreparerProbe(deviceID: deviceID)
    let sessions = SessionClientFactoryProbe(fingerprint: fingerprint)
    let localAccess = ManifestRepairingLocalAccessProbe(
        manifestURL: queueURL,
        repairedManifest: repairedManifest
    )
    let coordinator = ProductDeviceSessionCoordinator(
        connectionPreparer: preparer,
        credentialStore: SessionCredentialStoreProbe(records: [record]),
        identityProbe: { _ in fingerprint },
        sessionFactory: { lease, credentials in
            await sessions.make(lease: lease, credentials: credentials)
        },
        pairingFactory: { _, _ in throw ProductDeviceSessionError.pairingNotRequired },
        transferPersistenceDirectoryURL: directory,
        localFileAccessProviderFactory: { _ in localAccess }
    )

    guard case .ready = try await coordinator.connect(to: deviceID) else {
        Issue.record("expected authenticated session")
        return
    }
    let scheduler = try await coordinator.transferScheduler()
    #expect(await scheduler.snapshots().isEmpty)
    #expect(await scheduler.persistenceStatus() == .writeFailed)
    #expect(await localAccess.targetReadinessCount() == 0)
    #expect(await localAccess.acquisitionCount() == 0)
    #expect(try Data(contentsOf: queueURL) == corruptManifest)
    await coordinator.disconnect()
}

@Test func productRestorationValidatesDownloadCheckpointInsideLocalAccessLease() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let destinationDirectory = directory.appendingPathComponent(
        "scoped-destination",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: destinationDirectory,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: destinationDirectory.path
        )
        try? FileManager.default.removeItem(at: directory)
    }
    let deviceID = UUID()
    let fingerprint = Data(repeating: 0x2a, count: PairingAuthenticator.digestLength)
    let credential = try sessionCredentialRecord(fingerprint: fingerprint)
    let destination = destinationDirectory.appendingPathComponent("resume.bin")
    var sourceFingerprint = Droidmatch_V1_TransferFingerprint()
    sourceFingerprint.sizeBytes = 3
    sourceFingerprint.modifiedUnixMillis = 1
    try DownloadResumeRecord(
        transferID: "scoped-restore",
        sourcePath: "dm://app-sandbox/resume.bin",
        totalSizeBytes: 3,
        fingerprint: TransferFingerprintRecord(sourceFingerprint)
    ).save(to: DownloadResumeRecord.sidecarURL(forDestination: destination))
    try Data("a".utf8).write(to: AtomicDownloadWriter.partialURL(for: destination))

    let queueURL = try #require(ProductDeviceSessionCoordinator.transferPersistenceURL(
        directory: directory,
        fingerprint: fingerprint
    ))
    let jobID = UUID()
    let persistenceStore = try TransferQueuePersistenceStore(fileURL: queueURL)
    try persistenceStore.save(PersistedTransferQueue(jobs: [PersistedTransferJob(
        id: jobID,
        sequence: 0,
        request: PersistedTransferRequest(.download(AsyncDownloadCoordinatorRequest(
            sourcePath: "dm://app-sandbox/resume.bin",
            destinationURL: destination,
            freshTransferID: "scoped-restore"
        ))),
        state: .active,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )]))
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o000)],
        ofItemAtPath: destinationDirectory.path
    )

    let localAccess = ScopedRestoreLocalAccessProbe(directory: destinationDirectory)
    let sessions = SessionClientFactoryProbe(fingerprint: fingerprint)
    let coordinator = ProductDeviceSessionCoordinator(
        connectionPreparer: SessionConnectionPreparerProbe(deviceID: deviceID),
        credentialStore: SessionCredentialStoreProbe(records: [credential]),
        identityProbe: { _ in fingerprint },
        sessionFactory: { lease, credentials in
            await sessions.make(lease: lease, credentials: credentials)
        },
        pairingFactory: { _, _ in throw ProductDeviceSessionError.pairingNotRequired },
        transferPersistenceDirectoryURL: directory,
        localFileAccessProviderFactory: { _ in localAccess }
    )

    guard case .ready = try await coordinator.connect(to: deviceID) else {
        Issue.record("expected authenticated session")
        return
    }
    let scheduler = try await coordinator.transferScheduler()
    #expect(try await scheduler.snapshot(for: jobID).state == .paused)
    #expect(localAccess.acquisitionCount() == 1)
    #expect(localAccess.releaseCount() == 1)
    await coordinator.disconnect()
}

@Test func localFileAccessReadinessDefaultsToProcessLocalExecution() async throws {
    let provider = DefaultReadyLocalAccessProbe()
    #expect(await provider.isReadyForTransferExecution())
    #expect(await provider.isReadyForTransferExecution(
        targetURLs: [URL(fileURLWithPath: "/tmp/default-ready")]
    ))
    #expect(try await provider.withTransferExecutionPreparation { true })
}

@Test func productSessionConnectRetainsPairingLeaseUntilExplicitDisconnect() async throws {
    let deviceID = UUID()
    let fingerprint = Data(repeating: 0x31, count: PairingAuthenticator.digestLength)
    let preparer = SessionConnectionPreparerProbe(deviceID: deviceID)
    let store = SessionCredentialStoreProbe()
    let sessions = SessionClientFactoryProbe(fingerprint: fingerprint)
    let pairings = SessionPairingFactoryProbe()
    let coordinator = ProductDeviceSessionCoordinator(
        connectionPreparer: preparer,
        credentialStore: store,
        identityProbe: { _ in fingerprint },
        sessionFactory: { lease, credentials in
            await sessions.make(lease: lease, credentials: credentials)
        },
        pairingFactory: { lease, store in
            await pairings.make(lease: lease, store: store)
        }
    )

    #expect(try await coordinator.connect(to: deviceID) == .pairingRequired)
    #expect(await preparer.releaseCount() == 0)

    await coordinator.disconnect()
    #expect(await preparer.releaseCount() == 1)
    #expect(await sessions.makeCount() == 0)
}

@Test func productSessionRejectsNonceOnlyDebugEndpointWithStableFailure() async throws {
    let deviceID = UUID()
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyWithServerHello)
    defer { server.cancel() }
    let preparer = SessionConnectionPreparerProbe(deviceID: deviceID, port: server.port)
    let coordinator = ProductDeviceSessionCoordinator(
        connectionPreparer: preparer,
        credentialStore: SessionCredentialStoreProbe()
    )

    do {
        _ = try await coordinator.connect(to: deviceID)
        Issue.record("expected the nonce-only endpoint to be rejected")
    } catch ProductDeviceSessionError.secureEndpointRequired {
        // The debug harness proves transport reachability, not product trust.
    }

    #expect(await preparer.releaseCount() == 1)
}

@Test func productSessionSelectsCredentialByFingerprintAndOwnsReadyClient() async throws {
    let deviceID = UUID()
    let fingerprint = Data(repeating: 0x42, count: PairingAuthenticator.digestLength)
    let record = try sessionCredentialRecord(fingerprint: fingerprint)
    let preparer = SessionConnectionPreparerProbe(deviceID: deviceID)
    let store = SessionCredentialStoreProbe(records: [record])
    let sessions = SessionClientFactoryProbe(fingerprint: fingerprint)
    let accessProviders = LocalFileAccessProviderFactoryProbe()
    let coordinator = ProductDeviceSessionCoordinator(
        connectionPreparer: preparer,
        credentialStore: store,
        identityProbe: { _ in fingerprint },
        sessionFactory: { lease, credentials in
            await sessions.make(lease: lease, credentials: credentials)
        },
        pairingFactory: { _, _ in throw ProductDeviceSessionError.pairingNotRequired },
        localFileAccessProviderFactory: { ownerID in
            accessProviders.make(ownerID: ownerID)
        }
    )

    let outcome = try await coordinator.connect(to: deviceID)
    guard case let .ready(info) = outcome else {
        Issue.record("expected an authenticated product session")
        return
    }
    #expect(info.deviceID == deviceID)
    #expect(info.displayName == "Test Android")
    #expect(info.grantedCapabilities.contains(.fileList))
    #expect(await sessions.receivedPairingIDs() == [record.pairingID])
    #expect(store.secretReadCount() == 1)
    #expect(store.saveWriteCount() == 0)

    let directoryClient = try await coordinator.directoryListingClient()
    let page = try await directoryClient.listDirectoryPage(
        query: DirectoryListingQuery(path: "dm://roots/"),
        pageToken: nil
    )
    #expect(page.entries.isEmpty)
    let diagnostics = try await coordinator.diagnosticsSnapshot()
    #expect(diagnostics.model == "Phone")
    #expect(diagnostics.serviceState == .connected)

    let firstScheduler = try await coordinator.transferScheduler()
    let secondScheduler = try await coordinator.transferScheduler()
    #expect(firstScheduler === secondScheduler)
    #expect(store.secretReadCount() == 1)
    #expect(await firstScheduler.snapshots().isEmpty)
    let expectedOwnerID = try #require(LocalFileAccessOwnerID(
        authenticatedDeviceFingerprint: fingerprint
    ))
    #expect(firstScheduler.localFileAccessOwnerID == expectedOwnerID)
    #expect(accessProviders.ownerIDs() == [expectedOwnerID])

    await coordinator.disconnect()
    #expect(await sessions.closeCount() == 1)
    #expect(await preparer.releaseCount() == 1)
}

@Test func productSessionPairsWithVisibleApprovalThenAuthenticatesFreshSession() async throws {
    let deviceID = UUID()
    let fingerprint = Data(repeating: 0x53, count: PairingAuthenticator.digestLength)
    let preparer = SessionConnectionPreparerProbe(deviceID: deviceID)
    let store = SessionCredentialStoreProbe()
    let sessions = SessionClientFactoryProbe(fingerprint: fingerprint)
    let pairings = SessionPairingFactoryProbe(fingerprint: fingerprint)
    let coordinator = ProductDeviceSessionCoordinator(
        connectionPreparer: preparer,
        credentialStore: store,
        identityProbe: { _ in fingerprint },
        sessionFactory: { lease, credentials in
            await sessions.make(lease: lease, credentials: credentials)
        },
        pairingFactory: { lease, store in
            await pairings.make(lease: lease, store: store)
        }
    )
    #expect(try await coordinator.connect(to: deviceID) == .pairingRequired)

    let info = try await coordinator.pair { presentation in
        #expect(presentation.androidDisplayName == "Test Android")
        #expect(presentation.shortAuthenticationString == "123456")
        #expect(presentation.deviceIdentityFingerprint == fingerprint)
        return true
    }

    #expect(info.deviceID == deviceID)
    #expect(await pairings.makeCount() == 1)
    #expect(await sessions.makeCount() == 1)
    #expect(try store.list().count == 1)
    #expect(store.secretReadCount() == 0)
    #expect(store.saveWriteCount() == 1)
    await coordinator.disconnect()
}

@Test func productSessionFailureClosesNegotiatingClientAndReleasesForward() async throws {
    let deviceID = UUID()
    let fingerprint = Data(repeating: 0x64, count: PairingAuthenticator.digestLength)
    let record = try sessionCredentialRecord(fingerprint: fingerprint)
    let preparer = SessionConnectionPreparerProbe(deviceID: deviceID)
    let store = SessionCredentialStoreProbe(records: [record])
    let sessions = SessionClientFactoryProbe(
        fingerprint: fingerprint,
        handshakeError: AsyncRpcAuthenticationError.invalidServerProof
    )
    let coordinator = ProductDeviceSessionCoordinator(
        connectionPreparer: preparer,
        credentialStore: store,
        identityProbe: { _ in fingerprint },
        sessionFactory: { lease, credentials in
            await sessions.make(lease: lease, credentials: credentials)
        },
        pairingFactory: { _, _ in throw ProductDeviceSessionError.pairingNotRequired }
    )

    do {
        _ = try await coordinator.connect(to: deviceID)
        Issue.record("expected authentication failure")
    } catch ProductDeviceSessionError.authenticationFailed {
        // Expected normalized product failure.
    }
    #expect(await sessions.closeCount() == 1)
    #expect(await preparer.releaseCount() == 1)
}

@Test func productSessionTreatsMismatchedLoadedCredentialAsUnavailable() async throws {
    let deviceID = UUID()
    let selectedFingerprint = Data(repeating: 0x71, count: PairingAuthenticator.digestLength)
    let changedFingerprint = Data(repeating: 0x72, count: PairingAuthenticator.digestLength)
    let selectedRecord = try sessionCredentialRecord(fingerprint: selectedFingerprint)
    let changedRecord = try sessionCredentialRecord(fingerprint: changedFingerprint)
    let store = SessionCredentialStoreProbe(
        records: [changedRecord],
        listedMetadata: [selectedRecord.metadata]
    )
    let preparer = SessionConnectionPreparerProbe(deviceID: deviceID)
    let sessions = SessionClientFactoryProbe(fingerprint: selectedFingerprint)
    let accessProviders = LocalFileAccessProviderFactoryProbe()
    let coordinator = ProductDeviceSessionCoordinator(
        connectionPreparer: preparer,
        credentialStore: store,
        identityProbe: { _ in selectedFingerprint },
        sessionFactory: { lease, credentials in
            await sessions.make(lease: lease, credentials: credentials)
        },
        pairingFactory: { _, _ in throw ProductDeviceSessionError.pairingNotRequired },
        localFileAccessProviderFactory: { ownerID in
            accessProviders.make(ownerID: ownerID)
        }
    )

    await #expect(throws: ProductDeviceSessionError.credentialsUnavailable) {
        _ = try await coordinator.connect(to: deviceID)
    }
    #expect(await sessions.makeCount() == 0)
    #expect(accessProviders.ownerIDs().isEmpty)
    #expect(await preparer.releaseCount() == 1)
}
