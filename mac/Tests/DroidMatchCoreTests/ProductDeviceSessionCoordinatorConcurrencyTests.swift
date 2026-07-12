@testable import DroidMatchCore
import Foundation
import Testing

@Test func concurrentTransferSchedulerCallsShareOnePersistentBuild() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let deviceID = UUID()
    let fingerprint = Data(repeating: 0x81, count: PairingAuthenticator.digestLength)
    let record = try sessionCredentialRecord(fingerprint: fingerprint)
    let preparation = TransferSchedulerPreparationProbe()
    let factory = TransferSchedulerAccessFactory(first: preparation)
    let coordinator = makeConcurrencyCoordinator(
        deviceID: deviceID,
        fingerprint: fingerprint,
        record: record,
        directory: directory,
        factory: factory
    )
    guard case .ready = try await coordinator.connect(to: deviceID) else {
        Issue.record("expected authenticated session")
        return
    }

    let first = Task { try await coordinator.transferScheduler() }
    await preparation.waitUntilPreparationEntered()
    let second = Task { try await coordinator.transferScheduler() }
    for _ in 0..<20 { await Task.yield() }
    #expect(factory.makeCount() == 1)
    #expect(await preparation.preparationCount() == 1)
    await preparation.releasePreparation()

    let firstScheduler = try await first.value
    let secondScheduler = try await second.value
    #expect(firstScheduler === secondScheduler)
    #expect(factory.makeCount() == 1)
    #expect(await preparation.preparationCount() == 1)
    await coordinator.disconnect()
}

@Test func disconnectDuringReadinessCannotReviveOldScheduler() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let deviceID = UUID()
    let fingerprint = Data(repeating: 0x82, count: PairingAuthenticator.digestLength)
    let record = try sessionCredentialRecord(fingerprint: fingerprint)
    let queueURL = try #require(ProductDeviceSessionCoordinator.transferPersistenceURL(
        directory: directory,
        fingerprint: fingerprint
    ))
    let destination = directory.appendingPathComponent("blocked.bin")
    try TransferQueuePersistenceStore(fileURL: queueURL).save(PersistedTransferQueue(jobs: [
        PersistedTransferJob(
            id: UUID(),
            sequence: 0,
            request: PersistedTransferRequest(.download(AsyncDownloadCoordinatorRequest(
                sourcePath: "dm://app-sandbox/blocked.bin",
                destinationURL: destination
            ))),
            state: .queued,
            attemptNumber: 1,
            attemptBase: 0,
            resumeAttemptBase: nil,
            pauseRequiresResume: false
        ),
    ]))
    let readiness = TransferSchedulerReadinessProbe()
    let factory = TransferSchedulerAccessFactory(first: readiness)
    let coordinator = makeConcurrencyCoordinator(
        deviceID: deviceID,
        fingerprint: fingerprint,
        record: record,
        directory: directory,
        factory: factory
    )
    guard case .ready = try await coordinator.connect(to: deviceID) else {
        Issue.record("expected authenticated session")
        return
    }

    let oldBuild = Task { try await coordinator.transferScheduler() }
    await readiness.waitUntilReadinessEntered()
    await coordinator.disconnect()
    guard case .ready = try await coordinator.connect(to: deviceID) else {
        Issue.record("expected authenticated reconnect")
        return
    }
    let rebuilt = try await coordinator.transferScheduler()
    #expect(factory.makeCount() == 2)
    #expect(!(await rebuilt.snapshots().isEmpty))
    #expect(await rebuilt.persistenceStatus() == .writeFailed)
    #expect(await readiness.acquisitionCount() == 0)

    // Let the old generation unwind only after the replacement is published.
    // Its cleanup must not clear or overwrite the newer scheduler.
    await readiness.releaseReadiness()
    await #expect(throws: CancellationError.self) { _ = try await oldBuild.value }
    #expect(try await coordinator.transferScheduler() === rebuilt)
    #expect(await readiness.acquisitionCount() == 0)
    await coordinator.disconnect()
}

private func makeConcurrencyCoordinator(
    deviceID: UUID,
    fingerprint: Data,
    record: PairingCredentialRecord,
    directory: URL,
    factory: TransferSchedulerAccessFactory
) -> ProductDeviceSessionCoordinator {
    let sessions = SessionClientFactoryProbe(fingerprint: fingerprint)
    return ProductDeviceSessionCoordinator(
        connectionPreparer: SessionConnectionPreparerProbe(deviceID: deviceID),
        credentialStore: SessionCredentialStoreProbe(records: [record]),
        identityProbe: { _ in fingerprint },
        sessionFactory: { lease, credentials in
            await sessions.make(lease: lease, credentials: credentials)
        },
        pairingFactory: { _, _ in throw ProductDeviceSessionError.pairingNotRequired },
        transferPersistenceDirectoryURL: directory,
        localFileAccessProviderFactory: { _ in factory.make() }
    )
}

private final class TransferSchedulerAccessFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let first: any LocalFileAccessProviding
    private var count = 0

    init(first: any LocalFileAccessProviding) { self.first = first }

    func make() -> any LocalFileAccessProviding {
        lock.withLock {
            count += 1
            return count == 1 ? first : NeverReadyTransferAccess()
        }
    }

    func makeCount() -> Int { lock.withLock { count } }
}

private actor TransferSchedulerPreparationProbe: LocalFileAccessProviding {
    private var entered = false
    private var released = false
    private var count = 0
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func withTransferExecutionPreparation<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        count += 1
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return try await operation()
    }

    func waitUntilPreparationEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func releasePreparation() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func preparationCount() -> Int { count }
    func acquireAccess(to url: URL) throws -> any LocalFileAccessLease {
        _ = url
        return ConcurrencyAccessLease()
    }
}

private actor TransferSchedulerReadinessProbe: LocalFileAccessProviding {
    private var entered = false
    private var released = false
    private var acquisitions = 0
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func isReadyForTransferExecution(targetURLs: Set<URL>) async -> Bool {
        _ = targetURLs
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return true
    }

    func waitUntilReadinessEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func releaseReadiness() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func acquireAccess(to url: URL) throws -> any LocalFileAccessLease {
        _ = url
        acquisitions += 1
        return ConcurrencyAccessLease()
    }

    func acquisitionCount() -> Int { acquisitions }
}

private struct NeverReadyTransferAccess: LocalFileAccessProviding {
    func isReadyForTransferExecution(targetURLs: Set<URL>) async -> Bool {
        _ = targetURLs
        return false
    }

    func acquireAccess(to url: URL) throws -> any LocalFileAccessLease {
        _ = url
        return ConcurrencyAccessLease()
    }
}

private struct ConcurrencyAccessLease: LocalFileAccessLease {
    func release() {}
}
