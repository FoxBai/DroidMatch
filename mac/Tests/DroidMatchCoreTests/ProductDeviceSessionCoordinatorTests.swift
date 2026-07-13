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
    #expect(first?.lastPathComponent == "queue-" + String(repeating: "0a", count: 32) + ".json")
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

@Test func productSessionRejectsCredentialWhoseLoadedFingerprintChanged() async throws {
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

    await #expect(throws: ProductDeviceSessionError.authenticationFailed) {
        _ = try await coordinator.connect(to: deviceID)
    }
    #expect(await sessions.makeCount() == 0)
    #expect(accessProviders.ownerIDs().isEmpty)
    #expect(await preparer.releaseCount() == 1)
}

actor SessionConnectionPreparerProbe: DeviceConnectionPreparing {
    private let deviceID: UUID
    private var releases = 0

    init(deviceID: UUID) {
        self.deviceID = deviceID
    }

    func prepareConnection(to deviceID: UUID) throws -> DeviceConnectionLease {
        guard deviceID == self.deviceID else {
            throw DeviceConnectionPreparationError.deviceUnavailable
        }
        return DeviceConnectionLease(deviceID: deviceID, host: "127.0.0.1", port: 45_600)
    }

    func releaseConnection(_ lease: DeviceConnectionLease) {
        releases += 1
    }

    func releaseCount() -> Int { releases }
}

private enum SessionLocalAccessProbeError: Error {
    case unavailable
}

private actor SessionLocalAccessProbe: LocalFileAccessProviding {
    private let ready: Bool
    private let coveredTargetPaths: Set<String>
    private var acquisitions = 0

    init(ready: Bool, coveredTargetURLs: Set<URL>) {
        self.ready = ready
        coveredTargetPaths = Set(coveredTargetURLs.map { $0.standardizedFileURL.path })
    }

    func isReadyForTransferExecution() async -> Bool { ready }

    func isReadyForTransferExecution(targetURLs: Set<URL>) async -> Bool {
        ready && targetURLs.allSatisfy {
            coveredTargetPaths.contains($0.standardizedFileURL.path)
        }
    }

    func acquireAccess(to url: URL) async throws -> any LocalFileAccessLease {
        _ = url
        acquisitions += 1
        throw SessionLocalAccessProbeError.unavailable
    }

    func acquisitionCount() -> Int { acquisitions }
}

private actor ManifestRepairingLocalAccessProbe: LocalFileAccessProviding {
    private let manifestURL: URL
    private let repairedManifest: Data
    private var targetReadinessCalls = 0
    private var acquisitions = 0

    init(manifestURL: URL, repairedManifest: Data) {
        self.manifestURL = manifestURL
        self.repairedManifest = repairedManifest
    }

    func isReadyForTransferExecution() async -> Bool { true }

    func isReadyForTransferExecution(targetURLs: Set<URL>) async -> Bool {
        _ = targetURLs
        targetReadinessCalls += 1
        try? repairedManifest.write(to: manifestURL)
        return true
    }

    func acquireAccess(to url: URL) async throws -> any LocalFileAccessLease {
        _ = url
        acquisitions += 1
        throw SessionLocalAccessProbeError.unavailable
    }

    func targetReadinessCount() -> Int { targetReadinessCalls }
    func acquisitionCount() -> Int { acquisitions }
}

private struct DefaultReadyLocalAccessProbe: LocalFileAccessProviding {
    func acquireAccess(to url: URL) async throws -> any LocalFileAccessLease {
        _ = url
        throw SessionLocalAccessProbeError.unavailable
    }
}

private final class LocalFileAccessProviderFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [LocalFileAccessOwnerID] = []

    func make(ownerID: LocalFileAccessOwnerID) -> any LocalFileAccessProviding {
        lock.withLock { owners.append(ownerID) }
        return UnrestrictedLocalFileAccessProvider()
    }

    func ownerIDs() -> [LocalFileAccessOwnerID] {
        lock.withLock { owners }
    }
}

final class SessionCredentialStoreProbe: PairingCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Data: PairingCredentialRecord]
    private let listedMetadata: [PairingCredentialMetadata]?

    init(
        records: [PairingCredentialRecord] = [],
        listedMetadata: [PairingCredentialMetadata]? = nil
    ) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.pairingID, $0) })
        self.listedMetadata = listedMetadata
    }

    func save(_ record: PairingCredentialRecord) throws {
        lock.lock()
        records[record.pairingID] = record
        lock.unlock()
    }

    func load(pairingID: Data) throws -> PairingCredentialRecord {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[pairingID] else {
            throw PairingCredentialStoreError.notFound
        }
        return record
    }

    func list() throws -> [PairingCredentialMetadata] {
        lock.lock()
        defer { lock.unlock() }
        if let listedMetadata { return listedMetadata }
        return records.values.map(\.metadata).sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    func revoke(pairingID: Data) throws {
        lock.lock()
        records.removeValue(forKey: pairingID)
        lock.unlock()
    }
}

actor SessionClientFactoryProbe {
    private let fingerprint: Data
    private let handshakeError: (any Error & Sendable)?
    private let heartbeatError: (any Error & Sendable)?
    private let heartbeatResponseOffset: Int64
    private var clients: [SessionClientProbe] = []
    private var pairingIDs: [Data] = []

    init(
        fingerprint: Data,
        handshakeError: (any Error & Sendable)? = nil,
        heartbeatError: (any Error & Sendable)? = nil,
        heartbeatResponseOffset: Int64 = 0
    ) {
        self.fingerprint = fingerprint
        self.handshakeError = handshakeError
        self.heartbeatError = heartbeatError
        self.heartbeatResponseOffset = heartbeatResponseOffset
    }

    func make(
        lease: DeviceConnectionLease,
        credentials: PairingCredentials
    ) -> any ProductSessionClient {
        pairingIDs.append(credentials.pairingID)
        let client = SessionClientProbe(
            handshake: HandshakeSmokeResult(
                requestID: 1,
                serverName: "Test Android",
                serverVersion: "test",
                protocolMajor: 1,
                protocolMinor: 0,
                transport: .adb,
                grantedCapabilities: [
                    .fileList,
                    .fileRead,
                    .resumableTransfer,
                    .diagnostics,
                ],
                sessionNonce: Data(repeating: 1, count: 32),
                serverNonce: Data(repeating: 2, count: 32),
                deviceIdentityFingerprint: fingerprint,
                authenticationState: .authenticated
            ),
            handshakeError: handshakeError,
            heartbeatError: heartbeatError,
            heartbeatResponseOffset: heartbeatResponseOffset
        )
        clients.append(client)
        return client
    }

    func makeCount() -> Int { clients.count }
    func receivedPairingIDs() -> [Data] { pairingIDs }

    func closeCount() async -> Int {
        var count = 0
        for client in clients {
            count += await client.closeCount()
        }
        return count
    }
}

private actor SessionClientProbe: ProductSessionClient {
    private let result: HandshakeSmokeResult
    private let handshakeError: (any Error & Sendable)?
    private let heartbeatError: (any Error & Sendable)?
    private let heartbeatResponseOffset: Int64
    private var closes = 0

    init(
        handshake: HandshakeSmokeResult,
        handshakeError: (any Error & Sendable)?,
        heartbeatError: (any Error & Sendable)?,
        heartbeatResponseOffset: Int64
    ) {
        result = handshake
        self.handshakeError = handshakeError
        self.heartbeatError = heartbeatError
        self.heartbeatResponseOffset = heartbeatResponseOffset
    }

    func handshake() throws -> HandshakeSmokeResult {
        if let handshakeError { throw handshakeError }
        return result
    }

    func heartbeat(monotonicMillis: Int64) throws -> Droidmatch_V1_HeartbeatResponse {
        if let heartbeatError { throw heartbeatError }
        var response = Droidmatch_V1_HeartbeatResponse()
        response.monotonicMillis = monotonicMillis + heartbeatResponseOffset
        return response
    }

    func close() {
        closes += 1
    }

    func listDirectoryPage(
        query: DirectoryListingQuery,
        pageToken: String?
    ) throws -> DirectoryListingPage {
        DirectoryListingPage(entries: [], nextPageToken: nil)
    }

    func productDiagnosticsSnapshot() -> ProductDeviceDiagnosticsSnapshot {
        testDiagnosticsSnapshot()
    }

    func closeCount() -> Int { closes }
}

private actor SessionPairingFactoryProbe {
    private let fingerprint: Data?
    private var count = 0

    init(fingerprint: Data? = nil) {
        self.fingerprint = fingerprint
    }

    func make(
        lease: DeviceConnectionLease,
        store: any PairingCredentialStoring
    ) -> any ProductPairingClient {
        count += 1
        return SessionPairingClientProbe(
            fingerprint: fingerprint ?? Data(repeating: 0, count: 32),
            store: store
        )
    }

    func makeCount() -> Int { count }
}

private actor SessionPairingClientProbe: ProductPairingClient {
    private let fingerprint: Data
    private let store: any PairingCredentialStoring
    private var closed = false

    init(fingerprint: Data, store: any PairingCredentialStoring) {
        self.fingerprint = fingerprint
        self.store = store
    }

    func pair(
        clientDisplayName: String,
        approve: @escaping @Sendable (PairingPresentation) async throws -> Bool
    ) async throws -> PairingCredentialMetadata {
        let presentation = PairingPresentation(
            androidDisplayName: "Test Android",
            shortAuthenticationString: "123456",
            deviceIdentityFingerprint: fingerprint
        )
        guard try await approve(presentation) else {
            throw AsyncPairingClientError.userRejected
        }
        let record = try sessionCredentialRecord(fingerprint: fingerprint)
        try store.save(record)
        closed = true
        return record.metadata
    }

    func close() {
        closed = true
    }
}

func sessionCredentialRecord(fingerprint: Data) throws -> PairingCredentialRecord {
    try PairingCredentialRecord(
        pairingID: Data((0..<PairingAuthenticator.pairingIDLength).map { UInt8($0) }),
        deviceIdentityFingerprint: fingerprint,
        pairingKey: Data(repeating: 0xA5, count: PairingAuthenticator.keyLength),
        displayName: "Test Android",
        createdAt: Date(timeIntervalSince1970: 1),
        lastUsedAt: Date(timeIntervalSince1970: 2)
    )
}

private func testDiagnosticsSnapshot() -> ProductDeviceDiagnosticsSnapshot {
    ProductDeviceDiagnosticsSnapshot(
        manufacturer: "Example",
        model: "Phone",
        androidVersion: "14",
        sdkLevel: 34,
        totalStorageBytes: 1_000,
        freeStorageBytes: 400,
        batteryPercent: 70,
        permissions: [],
        serviceState: .connected,
        recentErrorCount: 0,
        counters: [:]
    )
}
