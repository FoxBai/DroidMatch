import Foundation
import Testing
@testable import DroidMatchAppSupport
@_spi(DroidMatchAppSupport) @testable import DroidMatchCore

@Test func corruptBookmarksKeepRestoredQueueStoppedUntilCoveredRetry() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ownerID = try readinessOwner(0x01)
    let manifestStore = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue/manifest.json")
    )
    let seedProbe = TransferExecutionStartProbe()
    let seed = try await makeReadinessScheduler(
        store: manifestStore,
        ownerID: ownerID,
        startQueuedJobs: false,
        probe: seedProbe
    )
    let queuedURL = directory.appendingPathComponent("queued.bin")
    let pausedURL = directory.appendingPathComponent("paused.bin")
    let queuedID = await seed.submit(.download(AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/queued.bin",
        destinationURL: queuedURL
    )))
    let pausedID = await seed.submit(.download(AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/paused.bin",
        destinationURL: pausedURL
    )))
    #expect(await seed.pause(pausedID))
    #expect(await seedProbe.count() == 0)

    let bookmarkURL = directory.appendingPathComponent("bookmarks/archive.json")
    try FileManager.default.createDirectory(
        at: bookmarkURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("corrupt".utf8).write(to: bookmarkURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: bookmarkURL.path
    )
    let bookmarkStore = try SecurityScopedBookmarkStore(
        fileURL: bookmarkURL,
        codec: BookmarkCodecReadinessProbe()
    )
    let executionProbe = TransferExecutionStartProbe()
    let scheduler = try await makeReadinessScheduler(
        store: manifestStore,
        ownerID: ownerID,
        startQueuedJobs: await bookmarkStore.isReadyForTransferExecution(
            owner: ownerID,
            targetURLs: [queuedURL, pausedURL]
        ),
        probe: executionProbe
    )
    let adapter = BookmarkingTransferQueueFactory(store: bookmarkStore)
        .transferQueueDataSource(for: scheduler)

    #expect(await adapter.persistenceStatus() == .writeFailed)
    #expect(await scheduler.snapshots().map(\.id) == [queuedID, pausedID])
    #expect(await scheduler.snapshots().map(\.state) == [.queued, .paused])
    #expect(await executionProbe.count() == 0)
    #expect(!(await adapter.retryPersistence()))
    #expect(!(await adapter.resume(pausedID)))
    #expect(await executionProbe.count() == 0)

    // A structurally valid but empty replacement must not unlock work whose
    // local authorization records are absent.
    try FileManager.default.removeItem(at: bookmarkURL)
    #expect(!(await adapter.retryPersistence()))
    #expect(await adapter.persistenceStatus() == .writeFailed)
    #expect(!(await bookmarkStore.isReadyForTransferExecution(
        owner: ownerID,
        targetURLs: [queuedURL, pausedURL]
    )))
    #expect(!(await adapter.resume(pausedID)))
    #expect(await scheduler.snapshots().map(\.state) == [.queued, .paused])
    #expect(await executionProbe.count() == 0)

    try await bookmarkStore.register(
        owner: ownerID,
        targetURL: queuedURL,
        authorizationURL: directory
    )
    try await bookmarkStore.register(
        owner: ownerID,
        targetURL: pausedURL,
        authorizationURL: directory
    )
    #expect(await bookmarkStore.isReadyForTransferExecution(
        owner: ownerID,
        targetURLs: [queuedURL, pausedURL]
    ))
    #expect(await adapter.retryPersistence())
    #expect(await waitForTransferExecutionStart(executionProbe, count: 1))
    #expect(await adapter.persistenceStatus() == .healthy)
}

@Test func corruptManifestReloadsBeforeBookmarkCoverageAndActivation() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ownerID = try readinessOwner(0x02)
    let manifestURL = directory.appendingPathComponent("queue/manifest.json")
    let manifestStore = try TransferQueuePersistenceStore(fileURL: manifestURL)
    let seedProbe = TransferExecutionStartProbe()
    let seed = try await makeReadinessScheduler(
        store: manifestStore,
        ownerID: ownerID,
        startQueuedJobs: false,
        probe: seedProbe
    )
    let queuedURL = directory.appendingPathComponent("restored-queued.bin")
    let queuedID = await seed.submit(.download(AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/restored-queued.bin",
        destinationURL: queuedURL
    )))
    let repairedManifest = try Data(contentsOf: manifestURL)
    try Data("corrupt-manifest".utf8).write(to: manifestURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: manifestURL.path
    )

    let executionProbe = TransferExecutionStartProbe()
    let scheduler = try await makeReadinessScheduler(
        store: manifestStore,
        ownerID: ownerID,
        startQueuedJobs: false,
        probe: executionProbe
    )
    #expect(await scheduler.snapshots().isEmpty)
    #expect(await scheduler.persistenceStatus() == .writeFailed)

    let bookmarkStore = try SecurityScopedBookmarkStore(
        fileURL: directory.appendingPathComponent("bookmarks/archive.json"),
        codec: BookmarkCodecReadinessProbe()
    )
    let preservedURL = directory.appendingPathComponent("preserved.bin")
    try await bookmarkStore.register(
        owner: ownerID,
        targetURL: preservedURL,
        authorizationURL: directory
    )
    let adapter = BookmarkingTransferQueueFactory(store: bookmarkStore)
        .transferQueueDataSource(for: scheduler)

    _ = await adapter.updates()
    #expect(await bookmarkStore.isReadyForTransferExecution(
        owner: ownerID,
        targetURLs: [preservedURL]
    ))
    #expect(await executionProbe.count() == 0)

    try repairedManifest.write(to: manifestURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: manifestURL.path
    )
    #expect(!(await adapter.retryPersistence()))
    #expect(try await scheduler.snapshot(for: queuedID).state == .queued)
    #expect(await scheduler.persistenceStatus() == .writeFailed)
    #expect(await executionProbe.count() == 0)
    #expect(await bookmarkStore.isReadyForTransferExecution(
        owner: ownerID,
        targetURLs: [preservedURL]
    ))
    #expect(!(await bookmarkStore.isReadyForTransferExecution(
        owner: ownerID,
        targetURLs: [queuedURL]
    )))

    try await bookmarkStore.register(
        owner: ownerID,
        targetURL: queuedURL,
        authorizationURL: directory
    )
    #expect(await adapter.retryPersistence())
    #expect(await waitForTransferExecutionStart(executionProbe, count: 1))
    #expect(await scheduler.persistenceStatus() == .healthy)
}

@Test func ownerScopedFactoryPruningPreservesOfflineOwnerAndNilOwnerFailsClosed() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let onlineOwner = try readinessOwner(0x03)
    let offlineOwner = try readinessOwner(0x04)
    let probe = TransferExecutionStartProbe()
    let factory: AsyncRpcControlClientFactory = { _ in
        try await probe.rejectClientCreation()
    }
    let executors = AsyncTransferSchedulerExecutors(
        downloadCoordinator: AsyncDownloadCoordinator(clientFactory: factory),
        uploadCoordinator: AsyncUploadCoordinator(clientFactory: factory)
    )
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: executors.download,
        uploadExecutor: executors.upload,
        localFileAccessOwnerID: onlineOwner
    )
    let bookmarkStore = try SecurityScopedBookmarkStore(
        fileURL: directory.appendingPathComponent("bookmarks/archive.json"),
        codec: BookmarkCodecReadinessProbe()
    )
    let onlineOrphanURL = directory.appendingPathComponent("online-orphan.bin")
    let offlineURL = directory.appendingPathComponent("offline.bin")
    try await bookmarkStore.register(
        owner: onlineOwner,
        targetURL: onlineOrphanURL,
        authorizationURL: directory
    )
    try await bookmarkStore.register(
        owner: offlineOwner,
        targetURL: offlineURL,
        authorizationURL: directory
    )
    let queueFactory = BookmarkingTransferQueueFactory(store: bookmarkStore)
    let adapter = queueFactory
        .transferQueueDataSource(for: scheduler)

    _ = await adapter.updates()
    #expect(!(await bookmarkStore.isReadyForTransferExecution(
        owner: onlineOwner,
        targetURLs: [onlineOrphanURL]
    )))
    #expect(await bookmarkStore.isReadyForTransferExecution(
        owner: offlineOwner,
        targetURLs: [offlineURL]
    ))

    let nilOwnerScheduler = AsyncTransferScheduler(
        downloadCoordinator: AsyncDownloadCoordinator(clientFactory: factory),
        uploadCoordinator: AsyncUploadCoordinator(clientFactory: factory),
        maxConcurrentJobs: 1
    )
    let nilOwnerDataSource = queueFactory.transferQueueDataSource(for: nilOwnerScheduler)
    _ = await nilOwnerDataSource.updates()
    #expect(await nilOwnerDataSource.persistenceStatus() == .writeFailed)
    #expect(await nilOwnerDataSource.submitDownload(
        sourcePath: "dm://app-sandbox/must-not-submit.bin",
        destinationURL: directory.appendingPathComponent("must-not-submit.bin"),
        authorizationURL: directory
    ) == nil)
    #expect(await bookmarkStore.isReadyForTransferExecution(
        owner: offlineOwner,
        targetURLs: [offlineURL]
    ))
    #expect(await probe.count() == 0)
}

@Test func bookmarkQueueRejectsDuplicateDownloadBeforeReplacingAuthority() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = try readinessOwner(0x09)
    let codec = BookmarkDuplicateAdmissionCodec()
    let bookmarkStore = try SecurityScopedBookmarkStore(
        fileURL: directory.appendingPathComponent("bookmarks/archive.json"),
        codec: codec
    )
    let executionGate = AsyncRpcOneShot<Void>()
    let starts = LockedValue(0)
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 2,
        downloadExecutor: { _, _, _ in
            starts.update { $0 += 1 }
            try await executionGate.wait(onCancel: {
                executionGate.resolve(.failure(CancellationError()))
            })
            throw TransferExecutionReadinessTestError.unavailable
        },
        uploadExecutor: { _, _, _ in
            throw TransferExecutionReadinessTestError.unavailable
        },
        localFileAccessOwnerID: owner
    )
    let adapter = BookmarkingTransferQueueFactory(store: bookmarkStore)
        .transferQueueDataSource(for: scheduler)
    let destination = directory.appendingPathComponent("same.bin")
    let lexicalAlias = URL(
        fileURLWithPath: directory.path + "/nested/../same.bin"
    )
    let firstAuthority = directory.appendingPathComponent("first-authority")
    let replacementAuthority = directory.appendingPathComponent("replacement-authority")

    let firstID = try #require(await adapter.submitDownload(
        sourcePath: "dm://app-sandbox/first.bin",
        destinationURL: lexicalAlias,
        authorizationURL: firstAuthority
    ))
    #expect(await waitForLockedCount(starts, expected: 1))
    #expect(codec.createdURLs() == [firstAuthority])

    #expect(await adapter.submitDownload(
        sourcePath: "dm://app-sandbox/duplicate.bin",
        destinationURL: destination,
        authorizationURL: replacementAuthority
    ) == nil)
    #expect(codec.createdURLs() == [firstAuthority])
    #expect(await scheduler.snapshots().map(\.id) == [firstID])
    #expect(starts.value() == 1)

    let lease = try await bookmarkStore.acquireAccess(owner: owner, to: destination)
    lease.release()
    #expect(codec.resolvedURLs() == [firstAuthority])

    #expect(await adapter.cancel(firstID))
    _ = try await scheduler.waitForCompletion(firstID)
}

@Test func anotherOwnersSamePathCannotUnlockRestoredQueue() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let queueOwner = try readinessOwner(0x05)
    let otherOwner = try readinessOwner(0x06)
    let manifestStore = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue/manifest.json")
    )
    let seedProbe = TransferExecutionStartProbe()
    let seed = try await makeReadinessScheduler(
        store: manifestStore,
        ownerID: queueOwner,
        startQueuedJobs: false,
        probe: seedProbe
    )
    let sharedTarget = directory.appendingPathComponent("same-target.bin")
    _ = await seed.submit(.download(AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/same-target.bin",
        destinationURL: sharedTarget
    )))

    let bookmarkStore = try SecurityScopedBookmarkStore(
        fileURL: directory.appendingPathComponent("bookmarks/archive.json"),
        codec: BookmarkCodecReadinessProbe()
    )
    try await bookmarkStore.register(
        owner: otherOwner,
        targetURL: sharedTarget,
        authorizationURL: directory
    )
    let executionProbe = TransferExecutionStartProbe()
    let scheduler = try await makeReadinessScheduler(
        store: manifestStore,
        ownerID: queueOwner,
        startQueuedJobs: false,
        probe: executionProbe
    )
    let adapter = BookmarkingTransferQueueFactory(store: bookmarkStore)
        .transferQueueDataSource(for: scheduler)

    #expect(!(await adapter.retryPersistence()))
    #expect(await adapter.persistenceStatus() == .writeFailed)
    #expect(await executionProbe.count() == 0)
    #expect(await bookmarkStore.isReadyForTransferExecution(
        owner: otherOwner,
        targetURLs: [sharedTarget]
    ))
    #expect(!(await bookmarkStore.isReadyForTransferExecution(
        owner: queueOwner,
        targetURLs: [sharedTarget]
    )))

    try await bookmarkStore.register(
        owner: queueOwner,
        targetURL: sharedTarget,
        authorizationURL: directory
    )
    #expect(await adapter.retryPersistence())
    #expect(await waitForTransferExecutionStart(executionProbe, count: 1))
}

@Test func factorySharesPreparationGateAcrossOwnerProviderAndDataSource() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstOwner = try readinessOwner(0x07)
    let secondOwner = try readinessOwner(0x08)
    let store = try SecurityScopedBookmarkStore(
        fileURL: directory.appendingPathComponent("bookmarks/archive.json"),
        codec: BookmarkCodecReadinessProbe()
    )
    let factory = BookmarkingTransferQueueFactory(store: store)
    let firstProvider = factory.localFileAccessProvider(for: firstOwner)
    let secondScheduler = makeProcessLocalScheduler(ownerID: secondOwner)
    let secondDataSource = factory.transferQueueDataSource(for: secondScheduler)
    let hold = PreparationHoldProbe()
    let completion = AsyncCompletionProbe()

    let holdingTask = Task {
        try await firstProvider.withTransferExecutionPreparation {
            await hold.waitForRelease()
            return true
        }
    }
    #expect(await waitForPreparationHold(hold))
    let blockedStatus = Task {
        await completion.markStarted()
        let status = await secondDataSource.persistenceStatus()
        await completion.markFinished()
        return status
    }
    #expect(await waitForCompletionStart(completion))
    for _ in 0..<100 { await Task.yield() }
    #expect(!(await completion.isFinished()))

    await hold.release()
    #expect(try await holdingTask.value)
    #expect(await blockedStatus.value == .disabled)
    #expect(await completion.isFinished())

    await #expect(throws: TransferExecutionReadinessTestError.preparationFailed) {
        _ = try await firstProvider.withTransferExecutionPreparation { () async throws -> Bool in
            throw TransferExecutionReadinessTestError.preparationFailed
        }
    }
    let secondProvider = factory.localFileAccessProvider(for: secondOwner)
    #expect(try await secondProvider.withTransferExecutionPreparation { true })

    let cancellationHold = PreparationHoldProbe()
    let cancellationHolder = Task {
        try await firstProvider.withTransferExecutionPreparation {
            await cancellationHold.waitForRelease()
            return true
        }
    }
    #expect(await waitForPreparationHold(cancellationHold))
    let cancelledActivity = AsyncCompletionProbe()
    let cancelledWaiter = Task {
        await cancelledActivity.markStarted()
        return try await secondProvider.withTransferExecutionPreparation {
            await cancelledActivity.markFinished()
            return true
        }
    }
    #expect(await waitForCompletionStart(cancelledActivity))
    for _ in 0..<100 { await Task.yield() }
    cancelledWaiter.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await cancelledWaiter.value
    }
    #expect(!(await cancelledActivity.isFinished()))
    await cancellationHold.release()
    #expect(try await cancellationHolder.value)

    // Cancelling the queued waiter must remove it rather than handing the
    // permit to a task that can no longer release it.
    #expect(try await secondProvider.withTransferExecutionPreparation { true })
}

private func makeReadinessScheduler(
    store: TransferQueuePersistenceStore,
    ownerID: LocalFileAccessOwnerID,
    startQueuedJobs: Bool,
    probe: TransferExecutionStartProbe
) async throws -> AsyncTransferScheduler {
    let factory: AsyncRpcControlClientFactory = { _ in
        try await probe.rejectClientCreation()
    }
    let executors = AsyncTransferSchedulerExecutors(
        downloadCoordinator: AsyncDownloadCoordinator(clientFactory: factory),
        uploadCoordinator: AsyncUploadCoordinator(clientFactory: factory)
    )
    return try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: executors.download,
        uploadExecutor: executors.upload,
        localFileAccessOwnerID: ownerID,
        startQueuedJobs: startQueuedJobs
    )
}

private func readinessOwner(_ byte: UInt8) throws -> LocalFileAccessOwnerID {
    try #require(LocalFileAccessOwnerID(
        authenticatedDeviceFingerprint: Data(repeating: byte, count: 32)
    ))
}

private func waitForTransferExecutionStart(
    _ probe: TransferExecutionStartProbe,
    count expected: Int
) async -> Bool {
    for _ in 0..<1_000 {
        if await probe.count() == expected { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

private enum TransferExecutionReadinessTestError: Error {
    case unavailable
    case preparationFailed
}

private actor TransferExecutionStartProbe {
    private var starts = 0

    func rejectClientCreation() throws -> AsyncRpcControlClient {
        starts += 1
        throw TransferExecutionReadinessTestError.unavailable
    }

    func count() -> Int { starts }
}

private func makeProcessLocalScheduler(
    ownerID: LocalFileAccessOwnerID
) -> AsyncTransferScheduler {
    let downloadExecutor: AsyncDownloadJobExecutor = { _, _, _ in
        throw TransferExecutionReadinessTestError.unavailable
    }
    let uploadExecutor: AsyncUploadJobExecutor = { _, _, _ in
        throw TransferExecutionReadinessTestError.unavailable
    }
    return AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: downloadExecutor,
        uploadExecutor: uploadExecutor,
        localFileAccessOwnerID: ownerID
    )
}

private actor PreparationHoldProbe {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func hasEntered() -> Bool { entered }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor AsyncCompletionProbe {
    private var started = false
    private var finished = false

    func markStarted() { started = true }
    func markFinished() { finished = true }
    func hasStarted() -> Bool { started }
    func isFinished() -> Bool { finished }
}

private func waitForPreparationHold(_ probe: PreparationHoldProbe) async -> Bool {
    for _ in 0..<1_000 {
        if await probe.hasEntered() { return true }
        await Task.yield()
    }
    return false
}

private func waitForCompletionStart(_ probe: AsyncCompletionProbe) async -> Bool {
    for _ in 0..<1_000 {
        if await probe.hasStarted() { return true }
        await Task.yield()
    }
    return false
}

private func waitForLockedCount(
    _ value: LockedValue<Int>,
    expected: Int
) async -> Bool {
    for _ in 0..<1_000 {
        if value.value() == expected { return true }
        await Task.yield()
    }
    return false
}

private struct BookmarkCodecReadinessProbe: SecurityScopedBookmarkCoding {
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
    }

    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}

private final class BookmarkDuplicateAdmissionCodec:
    SecurityScopedBookmarkCoding,
    @unchecked Sendable {
    private let lock = NSLock()
    private var created: [URL] = []
    private var resolved: [URL] = []

    func create(for url: URL) throws -> Data {
        lock.withLock { created.append(url) }
        return Data(url.path.utf8)
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        lock.withLock {
            let url = URL(fileURLWithPath: String(decoding: data, as: UTF8.self))
            resolved.append(url)
            return (url, false)
        }
    }

    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
    func createdURLs() -> [URL] { lock.withLock { created } }
    func resolvedURLs() -> [URL] { lock.withLock { resolved } }
}
