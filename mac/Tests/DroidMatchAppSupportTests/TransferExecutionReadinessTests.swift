import DroidMatchCore
import Foundation
import Testing
@testable import DroidMatchAppSupport

@Test func corruptBookmarksKeepRestoredQueueStoppedUntilCoveredRetry() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifestStore = try TransferQueuePersistenceStore(
        fileURL: directory.appendingPathComponent("queue/manifest.json")
    )
    let seedProbe = TransferExecutionStartProbe()
    let seed = try await makeReadinessScheduler(
        store: manifestStore,
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
        startQueuedJobs: await bookmarkStore.isReadyForTransferExecution(
            targetURLs: [queuedURL, pausedURL]
        ),
        probe: executionProbe
    )
    let adapter = BookmarkingTransferQueueDataSource(
        scheduler: scheduler,
        store: bookmarkStore
    )

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
        targetURLs: [queuedURL, pausedURL]
    )))
    #expect(!(await adapter.resume(pausedID)))
    #expect(await scheduler.snapshots().map(\.state) == [.queued, .paused])
    #expect(await executionProbe.count() == 0)

    try await bookmarkStore.register(targetURL: queuedURL, authorizationURL: directory)
    try await bookmarkStore.register(targetURL: pausedURL, authorizationURL: directory)
    #expect(await bookmarkStore.isReadyForTransferExecution(
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
    let manifestURL = directory.appendingPathComponent("queue/manifest.json")
    let manifestStore = try TransferQueuePersistenceStore(fileURL: manifestURL)
    let seedProbe = TransferExecutionStartProbe()
    let seed = try await makeReadinessScheduler(
        store: manifestStore,
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
    try await bookmarkStore.register(targetURL: preservedURL, authorizationURL: directory)
    let adapter = BookmarkingTransferQueueDataSource(
        scheduler: scheduler,
        store: bookmarkStore
    )

    _ = await adapter.updates()
    #expect(await bookmarkStore.isReadyForTransferExecution(targetURLs: [preservedURL]))
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
    #expect(await bookmarkStore.isReadyForTransferExecution(targetURLs: [preservedURL]))
    #expect(!(await bookmarkStore.isReadyForTransferExecution(targetURLs: [queuedURL])))

    try await bookmarkStore.register(targetURL: queuedURL, authorizationURL: directory)
    #expect(await adapter.retryPersistence())
    #expect(await waitForTransferExecutionStart(executionProbe, count: 1))
    #expect(await scheduler.persistenceStatus() == .healthy)
}

@Test func processLocalAuthoritativeUpdatesStillPruneOrphanedBookmarks() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let probe = TransferExecutionStartProbe()
    let factory: AsyncRpcControlClientFactory = { _ in
        try await probe.rejectClientCreation()
    }
    let scheduler = AsyncTransferScheduler(
        downloadCoordinator: AsyncDownloadCoordinator(clientFactory: factory),
        uploadCoordinator: AsyncUploadCoordinator(clientFactory: factory),
        maxConcurrentJobs: 1
    )
    let bookmarkStore = try SecurityScopedBookmarkStore(
        fileURL: directory.appendingPathComponent("bookmarks/archive.json"),
        codec: BookmarkCodecReadinessProbe()
    )
    let orphanURL = directory.appendingPathComponent("orphan.bin")
    try await bookmarkStore.register(targetURL: orphanURL, authorizationURL: directory)
    let adapter = BookmarkingTransferQueueDataSource(
        scheduler: scheduler,
        store: bookmarkStore
    )

    _ = await adapter.updates()
    #expect(!(await bookmarkStore.isReadyForTransferExecution(targetURLs: [orphanURL])))
    #expect(await probe.count() == 0)
}

private func makeReadinessScheduler(
    store: TransferQueuePersistenceStore,
    startQueuedJobs: Bool,
    probe: TransferExecutionStartProbe
) async throws -> AsyncTransferScheduler {
    let factory: AsyncRpcControlClientFactory = { _ in
        try await probe.rejectClientCreation()
    }
    return try await AsyncTransferScheduler.restoring(
        downloadCoordinator: AsyncDownloadCoordinator(clientFactory: factory),
        uploadCoordinator: AsyncUploadCoordinator(clientFactory: factory),
        persistenceStore: store,
        maxConcurrentJobs: 1,
        startQueuedJobs: startQueuedJobs
    )
}

private func waitForTransferExecutionStart(
    _ probe: TransferExecutionStartProbe,
    count expected: Int
) async -> Bool {
    for _ in 0..<1_000 {
        if await probe.count() == expected { return true }
        await Task.yield()
    }
    return false
}

private enum TransferExecutionReadinessTestError: Error {
    case unavailable
}

private actor TransferExecutionStartProbe {
    private var starts = 0

    func rejectClientCreation() throws -> AsyncRpcControlClient {
        starts += 1
        throw TransferExecutionReadinessTestError.unavailable
    }

    func count() -> Int { starts }
}

private struct BookmarkCodecReadinessProbe: SecurityScopedBookmarkCoding {
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
    }

    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}
