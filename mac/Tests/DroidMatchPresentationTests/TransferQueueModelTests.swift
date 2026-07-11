@testable import DroidMatchCore
import DroidMatchPresentation
import Foundation
import Testing

@Test func transferQueueItemRedactsMacPathsAndKeepsStructuredState() {
    let id = UUID()
    let download = TransferQueuePresentationItem(snapshot: makeSnapshot(
        id: id,
        kind: .download,
        state: .retrying,
        source: "dm://media-images/media/123",
        destination: "/Users/example/Desktop/private-photo.jpg",
        failureDescription: "resume sidecar missing: /Users/example/Desktop/private-photo.jpg.json",
        canPause: true,
        canCancel: true
    ))

    #expect(download.id == id)
    #expect(download.localFileName == "private-photo.jpg")
    #expect(download.remotePath == "dm://media-images/media/123")
    #expect(download.state == .retrying)
    #expect(download.fractionCompleted == 0.4)
    #expect(download.canPause)
    #expect(download.canCancel)
    #expect(!String(reflecting: download).contains("/Users/example"))

    let upload = TransferQueuePresentationItem(snapshot: makeSnapshot(
        kind: .upload,
        source: "/Volumes/Work/client-archive.zip",
        destination: "dm://saf-root/client-archive.zip"
    ))
    #expect(upload.localFileName == "client-archive.zip")
    #expect(upload.remotePath == "dm://saf-root/client-archive.zip")
    #expect(!String(reflecting: upload).contains("/Volumes/Work"))

    let malformedRemote = TransferQueuePresentationItem(snapshot: makeSnapshot(
        source: "/Users/example/must-not-become-remote-state.bin",
        destination: "/tmp/local.bin"
    ))
    #expect(malformedRemote.remotePath == nil)
    #expect(!String(reflecting: malformedRemote).contains("/Users/example"))
}

@Test
@MainActor
func transferQueueModelSubscribesOnceAndPreservesSchedulerOrder() async throws {
    let source = TransferQueueDataSourceProbe()
    let model = TransferQueueModel(dataSource: source)
    let first = makeSnapshot(kind: .download, source: "dm://first", destination: "/tmp/first")
    let second = makeSnapshot(kind: .upload, source: "/tmp/second", destination: "dm://second")

    model.start()
    model.start()
    #expect(await waitForSubscriptionCount(source, expected: 1))
    await source.setPersistenceStatus(.writeFailed)
    await source.yield([first, second], to: 1)
    #expect(await waitForItems(model) { $0.map(\.id) == [first.id, second.id] })
    #expect(model.isObserving)
    #expect(model.items.map(\.localFileName) == ["first", "second"])
    #expect(model.persistenceStatus == .writeFailed)

    model.stop()
}

@Test
@MainActor
func transferQueueModelStopRetainsItemsAndRestartRejectsOldStream() async throws {
    let source = TransferQueueDataSourceProbe()
    let model = TransferQueueModel(dataSource: source)
    let first = makeSnapshot(destination: "/tmp/first")
    let stale = makeSnapshot(destination: "/tmp/stale")
    let current = makeSnapshot(destination: "/tmp/current")

    model.start()
    #expect(await waitForSubscriptionCount(source, expected: 1))
    await source.yield([first], to: 1)
    #expect(await waitForItems(model) { $0.map(\.id) == [first.id] })

    model.stop()
    #expect(!model.isObserving)
    #expect(model.items.map(\.id) == [first.id])
    await source.yield([stale], to: 1)
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(model.items.map(\.id) == [first.id])

    model.start()
    #expect(await waitForSubscriptionCount(source, expected: 2))
    await source.yield([current], to: 2)
    #expect(await waitForItems(model) { $0.map(\.id) == [current.id] })

    await source.finish(subscription: 2)
    #expect(await waitForObservationToEnd(model))
    #expect(model.items.map(\.id) == [current.id])
}

@Test
@MainActor
func transferQueueModelRoutesActionsWithoutOptimisticMutation() async throws {
    let source = TransferQueueDataSourceProbe()
    let model = TransferQueueModel(dataSource: source)
    let id = UUID()
    let queued = makeSnapshot(id: id, state: .queued, canPause: true, canCancel: true)

    model.start()
    #expect(await waitForSubscriptionCount(source, expected: 1))
    await source.yield([queued], to: 1)
    #expect(await waitForItems(model) { $0.first?.state == .queued })

    #expect(await model.pause(id))
    #expect(model.items.first?.state == .queued)
    await source.yield([
        makeSnapshot(id: id, state: .paused, canResume: true, canCancel: true),
    ], to: 1)
    #expect(await waitForItems(model) { $0.first?.state == .paused })

    #expect(await model.resume(id))
    #expect(await model.cancel(id))
    #expect(await model.remove(id))
    #expect(await source.recordedActions() == [
        .pause(id),
        .resume(id),
        .cancel(id),
        .remove(id),
    ])

    model.stop()
}

@Test
@MainActor
func transferQueueModelSubmitsValidatedDownloadThroughDataSource() async throws {
    let source = TransferQueueDataSourceProbe()
    let model = TransferQueueModel(dataSource: source)
    let destination = URL(fileURLWithPath: "/tmp/product-download.bin")

    let id = await model.submitDownload(
        sourcePath: "dm://app-sandbox/product-download.bin",
        destinationURL: destination
    )

    #expect(id != nil)
    #expect(await source.recordedActions() == [
        .submitDownload(
            "dm://app-sandbox/product-download.bin",
            destination.path
        ),
    ])
}

@Test
@MainActor
func transferQueueModelSubmitsUploadThroughCurrentDirectoryBoundary() async {
    let source = TransferQueueDataSourceProbe()
    let model = TransferQueueModel(dataSource: source)
    let localFile = URL(fileURLWithPath: "/tmp/local-upload.zip")

    let id = await model.submitUpload(
        sourceURL: localFile,
        directoryPath: "dm://saf-a1b2/doc/0123456789abcdef"
    )

    #expect(id != nil)
    #expect(await source.recordedActions() == [
        .submitUpload(
            localFile.path,
            "dm://saf-a1b2/doc/0123456789abcdef"
        ),
    ])
}

@Test
@MainActor
func transferQueueModelSubmitsDroppedBatchInStableInputOrder() async {
    let source = TransferQueueDataSourceProbe()
    let model = TransferQueueModel(dataSource: source)
    let files = [
        URL(fileURLWithPath: "/tmp/first.jpg"),
        URL(fileURLWithPath: "/tmp/second.jpg"),
    ]

    let ids = await model.submitUploads(
        sourceURLs: files,
        directoryPath: "dm://app-sandbox/imports/"
    )

    #expect(ids.count == 2)
    #expect(await source.recordedActions() == [
        .submitUpload(files[0].path, "dm://app-sandbox/imports/"),
        .submitUpload(files[1].path, "dm://app-sandbox/imports/"),
    ])
}

@Test func transferQueueSchedulerAdapterRejectsNonProductPathsBeforeEnqueue() async {
    let factory: AsyncRpcControlClientFactory = { _ in
        throw PresentationTestError.expectedFailure
    }
    let scheduler = AsyncTransferScheduler(
        downloadCoordinator: AsyncDownloadCoordinator(clientFactory: factory),
        uploadCoordinator: AsyncUploadCoordinator(clientFactory: factory)
    )
    let source = AsyncTransferSchedulerDataSource(scheduler: scheduler)

    #expect(await source.submitDownload(
        sourcePath: "/private/android/path",
        destinationURL: URL(fileURLWithPath: "/tmp/rejected.bin")
    ) == nil)
    #expect(await source.submitDownload(
        sourcePath: "dm://app-sandbox/valid.bin",
        destinationURL: URL(string: "https://example.invalid/rejected.bin")!
    ) == nil)
    #expect(await source.submitUpload(
        sourceURL: URL(string: "https://example.invalid/local.bin")!,
        directoryPath: "dm://app-sandbox/"
    ) == nil)
    #expect(await source.submitUpload(
        sourceURL: URL(fileURLWithPath: "/tmp/100%done.bin"),
        directoryPath: "dm://app-sandbox/"
    ) == nil)
    #expect(await source.submitUpload(
        sourceURL: URL(fileURLWithPath: "/tmp/local.bin"),
        directoryPath: "dm://roots/"
    ) == nil)
    #expect(await scheduler.snapshots().isEmpty)
}

@Test
@MainActor
func transferQueueSchedulerAdapterDeliversCurrentStateAndRemoval() async throws {
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { _, _, _ in
            throw PresentationTestError.expectedFailure
        },
        uploadExecutor: { _, _, _ in
            throw PresentationTestError.expectedFailure
        }
    )
    let id = await scheduler.submit(.download(AsyncDownloadCoordinatorRequest(
        sourcePath: "dm://app-sandbox/adapter.bin",
        destinationURL: URL(fileURLWithPath: "/Users/example/adapter.bin")
    )))
    let outcome = try await scheduler.waitForCompletion(id)
    guard case .failure = outcome else {
        Issue.record("expected injected scheduler failure")
        return
    }

    let model = TransferQueueModel(scheduler: scheduler)
    model.start()
    #expect(await waitForItems(model) {
        $0.first?.id == id && $0.first?.state == .failed
    })
    #expect(model.items.first?.localFileName == "adapter.bin")
    #expect(model.items.first?.canRemove == true)
    #expect(!String(reflecting: model.items).contains("/Users/example"))

    #expect(await model.remove(id))
    #expect(await waitForItems(model) { $0.isEmpty })
    model.stop()
}

private actor TransferQueueDataSourceProbe: TransferQueueDataSource {
    enum Action: Equatable, Sendable {
        case submitDownload(String, String)
        case submitUpload(String, String)
        case pause(UUID)
        case resume(UUID)
        case cancel(UUID)
        case remove(UUID)
    }

    private var subscriptionNumber = 0
    private var continuations: [Int: AsyncStream<[AsyncTransferJobSnapshot]>.Continuation] = [:]
    private var actions: [Action] = []
    private var currentPersistenceStatus: AsyncTransferQueuePersistenceStatus = .healthy

    func updates() async -> AsyncStream<[AsyncTransferJobSnapshot]> {
        subscriptionNumber += 1
        let number = subscriptionNumber
        let pair = AsyncStream<[AsyncTransferJobSnapshot]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[number] = pair.continuation
        return pair.stream
    }

    func persistenceStatus() async -> AsyncTransferQueuePersistenceStatus {
        currentPersistenceStatus
    }

    func setPersistenceStatus(_ status: AsyncTransferQueuePersistenceStatus) {
        currentPersistenceStatus = status
    }

    func submitDownload(sourcePath: String, destinationURL: URL) -> UUID? {
        actions.append(.submitDownload(sourcePath, destinationURL.path))
        return UUID()
    }

    func submitUpload(sourceURL: URL, directoryPath: String) -> UUID? {
        actions.append(.submitUpload(sourceURL.path, directoryPath))
        return UUID()
    }

    func pause(_ id: UUID) async -> Bool {
        actions.append(.pause(id))
        return true
    }

    func resume(_ id: UUID) async -> Bool {
        actions.append(.resume(id))
        return true
    }

    func cancel(_ id: UUID) async -> Bool {
        actions.append(.cancel(id))
        return true
    }

    func remove(_ id: UUID) async -> Bool {
        actions.append(.remove(id))
        return true
    }

    func count() -> Int {
        subscriptionNumber
    }

    func yield(_ snapshots: [AsyncTransferJobSnapshot], to subscription: Int) {
        continuations[subscription]?.yield(snapshots)
    }

    func finish(subscription: Int) {
        continuations[subscription]?.finish()
    }

    func recordedActions() -> [Action] {
        actions
    }
}

private enum PresentationTestError: Error {
    case expectedFailure
}

private func makeSnapshot(
    id: UUID = UUID(),
    kind: AsyncTransferJobKind = .download,
    state: AsyncTransferJobState = .running,
    source: String = "dm://app-sandbox/source.bin",
    destination: String = "/tmp/destination.bin",
    failureDescription: String? = nil,
    canPause: Bool = false,
    canResume: Bool = false,
    canCancel: Bool = true,
    canRemove: Bool = false
) -> AsyncTransferJobSnapshot {
    AsyncTransferJobSnapshot(
        id: id,
        kind: kind,
        state: state,
        source: source,
        destination: destination,
        attemptNumber: 2,
        confirmedBytes: 4,
        totalBytes: 10,
        recentBytesPerSecond: 2,
        retryDelayMilliseconds: state == .retrying ? 250 : nil,
        failureDescription: failureDescription,
        canPause: canPause,
        canResume: canResume,
        canCancel: canCancel,
        canRemove: canRemove
    )
}

private func waitForSubscriptionCount(
    _ source: TransferQueueDataSourceProbe,
    expected: Int
) async -> Bool {
    for _ in 0..<200 {
        if await source.count() == expected { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@MainActor
private func waitForItems(
    _ model: TransferQueueModel,
    matching predicate: ([TransferQueuePresentationItem]) -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if predicate(model.items) { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@MainActor
private func waitForObservationToEnd(_ model: TransferQueueModel) async -> Bool {
    for _ in 0..<200 {
        if !model.isObserving { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}
