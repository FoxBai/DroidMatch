import Foundation
import Testing
@testable import DroidMatchAppSupport
@_spi(DroidMatchAppSupport) @testable import DroidMatchCore

@Test func repairedManifestRetryRestoresCheckpointOnlyInsideBookmarkScope() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let owner = try #require(LocalFileAccessOwnerID(
        authenticatedDeviceFingerprint: Data(repeating: 0x4a, count: 32)
    ))
    let activeDestination = directory.appendingPathComponent("active.bin")
    let queuedDestination = directory.appendingPathComponent("queued.bin")
    let activeSource = "dm://app-sandbox/active.bin"
    let activeID = UUID()
    let queuedID = UUID()
    let manifestStore = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue/manifest.json")
    )
    try manifestStore.save(PersistedTransferQueue(jobs: [
        retryRestoreJob(
            id: activeID,
            sequence: 0,
            state: .active,
            sourcePath: activeSource,
            destinationURL: activeDestination
        ),
        retryRestoreJob(
            id: queuedID,
            sequence: 1,
            state: .queued,
            sourcePath: "dm://app-sandbox/queued.bin",
            destinationURL: queuedDestination
        ),
    ]))
    let repairedManifest = try Data(contentsOf: directory
        .appendingPathComponent("queue/manifest.json"))
    let manifestURL = directory.appendingPathComponent("queue/manifest.json")
    try Data("corrupt-manifest".utf8).write(to: manifestURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: manifestURL.path
    )

    let executionProbe = RetryRestoreExecutionProbe()
    let scheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: manifestStore,
        initialPersistenceLoadFailed: true,
        downloadExecutor: { _, _, _ in
            try await executionProbe.rejectExecution()
        },
        uploadExecutor: { _, _, _ in
            throw RetryRestoreTestError.unexpectedUpload
        },
        localFileAccessOwnerID: owner,
        startQueuedJobs: false
    )
    #expect(await scheduler.snapshots().isEmpty)
    #expect(await scheduler.persistenceStatus() == .writeFailed)

    let scopeProbe = RetryRestoreBookmarkCodec {
        try installRetryRestoreCheckpoint(
            destination: activeDestination,
            sourcePath: activeSource
        )
    }
    let bookmarkStore = try SecurityScopedBookmarkStore(
        fileURL: directory.appendingPathComponent("bookmarks/archive.json"),
        codec: scopeProbe
    )
    let adapter = BookmarkingTransferQueueFactory(store: bookmarkStore)
        .transferQueueDataSource(for: scheduler)

    #expect(!FileManager.default.fileExists(atPath: DownloadResumeRecord
        .sidecarURL(forDestination: activeDestination).path))
    try repairedManifest.write(to: manifestURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: manifestURL.path
    )

    // A repaired archive must not be canonicalized before every checkpoint
    // target has an active bookmark lease and directory capability.
    #expect(!(await adapter.retryPersistence()))
    #expect(await scheduler.snapshots().isEmpty)
    #expect(try Data(contentsOf: manifestURL) == repairedManifest)
    #expect(scopeProbe.state().starts == 0)
    #expect(await executionProbe.count() == 0)

    try await bookmarkStore.register(
        owner: owner,
        targetURL: activeDestination,
        authorizationURL: directory
    )

    // The queued target is intentionally not authorized yet. Reload may
    // validate the active checkpoint, but execution must remain held.
    #expect(!(await adapter.retryPersistence()))
    #expect(try await scheduler.snapshot(for: activeID).state == .paused)
    #expect(try await scheduler.snapshot(for: queuedID).state == .queued)
    #expect(await executionProbe.count() == 0)
    #expect(await scheduler.persistenceStatus() == .writeFailed)
    let firstScopeState = scopeProbe.state()
    #expect(firstScopeState.starts == 1)
    #expect(firstScopeState.stops == 1)
    #expect(firstScopeState.installedWhileActive)
    let canonicalAfterHeldRetry = try manifestStore.load()
    #expect(canonicalAfterHeldRetry.jobs.first { $0.id == activeID }?.state == .paused)
    #expect(canonicalAfterHeldRetry.jobs.first { $0.id == queuedID }?.state == .queued)

    try await bookmarkStore.register(
        owner: owner,
        targetURL: queuedDestination,
        authorizationURL: directory
    )
    #expect(await adapter.retryPersistence())
    #expect(await waitForRetryRestoreExecution(executionProbe))
    #expect(try await scheduler.snapshot(for: activeID).state == .paused)
    #expect(await scheduler.persistenceStatus() == .healthy)
    let finalScopeState = scopeProbe.state()
    #expect(finalScopeState.starts == 2)
    #expect(finalScopeState.stops == 2)
    #expect(finalScopeState.maximumActive == 1)
    #expect(finalScopeState.installedWhileActive)
}

private func retryRestoreJob(
    id: UUID,
    sequence: UInt64,
    state: PersistedTransferJobState,
    sourcePath: String,
    destinationURL: URL
) -> PersistedTransferJob {
    PersistedTransferJob(
        id: id,
        sequence: sequence,
        request: PersistedTransferRequest(.download(AsyncDownloadCoordinatorRequest(
            sourcePath: sourcePath,
            destinationURL: destinationURL,
            freshTransferID: id.uuidString
        ))),
        state: state,
        attemptNumber: 1,
        attemptBase: 0,
        resumeAttemptBase: nil,
        pauseRequiresResume: false
    )
}

private func installRetryRestoreCheckpoint(
    destination: URL,
    sourcePath: String
) throws {
    var fingerprint = Droidmatch_V1_TransferFingerprint()
    fingerprint.sizeBytes = 10
    fingerprint.modifiedUnixMillis = 1
    try DownloadResumeRecord(
        transferID: "retry-restore-active",
        sourcePath: sourcePath,
        totalSizeBytes: 10,
        fingerprint: TransferFingerprintRecord(fingerprint)
    ).save(to: DownloadResumeRecord.sidecarURL(forDestination: destination))
    try Data("abc".utf8).write(to: AtomicDownloadWriter.partialURL(for: destination))
}

private enum RetryRestoreTestError: Error {
    case executionRejected
    case unexpectedUpload
}

private actor RetryRestoreExecutionProbe {
    private var starts = 0

    func rejectExecution() throws -> AsyncDownloadCoordinatorResult {
        starts += 1
        throw RetryRestoreTestError.executionRejected
    }

    func count() -> Int { starts }
}

private func waitForRetryRestoreExecution(_ probe: RetryRestoreExecutionProbe) async -> Bool {
    for _ in 0..<1_000 {
        if await probe.count() == 1 { return true }
        await Task.yield()
    }
    return false
}

private final class RetryRestoreBookmarkCodec:
    SecurityScopedBookmarkCoding,
    @unchecked Sendable {
    struct State {
        let starts: Int
        let stops: Int
        let maximumActive: Int
        let installedWhileActive: Bool
    }

    private let lock = NSLock()
    private let installCheckpoint: @Sendable () throws -> Void
    private var starts = 0
    private var stops = 0
    private var active = 0
    private var maximumActive = 0
    private var installedWhileActive = false

    init(installCheckpoint: @escaping @Sendable () throws -> Void) {
        self.installCheckpoint = installCheckpoint
    }

    func create(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
    }

    func startAccessing(_ url: URL) -> Bool {
        _ = url
        lock.withLock {
            starts += 1
            active += 1
            maximumActive = max(maximumActive, active)
        }
        do {
            try installCheckpoint()
            lock.withLock { installedWhileActive = active > 0 }
            return true
        } catch {
            lock.withLock { active -= 1 }
            return false
        }
    }

    func stopAccessing(_ url: URL) {
        _ = url
        lock.withLock {
            stops += 1
            active -= 1
        }
    }

    func state() -> State {
        lock.withLock {
            State(
                starts: starts,
                stops: stops,
                maximumActive: maximumActive,
                installedWhileActive: installedWhileActive
            )
        }
    }
}
