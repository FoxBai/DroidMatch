@testable import DroidMatchCore
import DroidMatchPresentation
import Foundation
import Testing

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
func transferQueueModelRetriesPersistenceAndReloadsAuthoritativeHealth() async throws {
    let source = TransferQueueDataSourceProbe()
    let model = TransferQueueModel(dataSource: source)
    await source.setPersistenceStatus(.writeFailed)

    model.start()
    #expect(await waitForSubscriptionCount(source, expected: 1))
    await source.yield([], to: 1)
    #expect(await waitForPersistenceStatus(model, .writeFailed))

    #expect(await model.retryPersistence())
    #expect(model.persistenceStatus == .healthy)
    #expect(!model.isRetryingPersistence)
    #expect(await source.recordedActions() == [.retryPersistence])
    #expect(!(await model.retryPersistence()))
    model.stop()
}

@Test
@MainActor
func transferQueueModelReloadsPersistenceHealthAfterRejectedSubmission() async throws {
    let source = TransferQueueDataSourceProbe()
    let model = TransferQueueModel(dataSource: source)
    model.start()
    #expect(await waitForSubscriptionCount(source, expected: 1))
    await source.blockNextPersistenceStatusRead()
    await source.yield([], to: 1)
    guard await waitForBlockedPersistenceRead(source) else {
        Issue.record("observation did not enter the controlled persistence read")
        model.stop()
        return
    }
    await source.rejectNextSubmissionWithPersistenceFailure()

    let downloadID = await model.submitDownload(
        sourcePath: "dm://app-sandbox/rejected.bin",
        destinationURL: URL(fileURLWithPath: "/tmp/rejected.bin"),
        authorizationURL: URL(fileURLWithPath: "/tmp")
    )
    await source.releaseBlockedPersistenceRead()
    for _ in 0..<10 { await Task.yield() }

    #expect(downloadID == nil)
    #expect(model.persistenceStatus == .writeFailed)
    #expect(await source.recordedActions() == [
        .submitDownload("dm://app-sandbox/rejected.bin", "/tmp/rejected.bin", "/tmp"),
    ])
    model.stop()

    let uploadSource = TransferQueueDataSourceProbe()
    let uploadModel = TransferQueueModel(dataSource: uploadSource)
    await uploadSource.rejectNextSubmissionWithPersistenceFailure()
    let uploadID = await uploadModel.submitUpload(
        sourceURL: URL(fileURLWithPath: "/tmp/rejected-upload.bin"),
        directoryPath: "dm://app-sandbox/"
    )
    #expect(uploadID == nil)
    #expect(uploadModel.persistenceStatus == .writeFailed)
    #expect(await uploadSource.recordedActions() == [
        .submitUpload("/tmp/rejected-upload.bin", "dm://app-sandbox/"),
    ])
}

@Test
@MainActor
func transferQueueModelReloadsPersistenceHealthAfterQueueMutation() async throws {
    for mutation in QueueMutationProbe.allCases {
        let source = TransferQueueDataSourceProbe()
        let model = TransferQueueModel(dataSource: source)
        let id = UUID()
        await source.failPersistenceAfterNextMutation()

        let succeeded: Bool
        let expectedAction: TransferQueueDataSourceProbe.Action
        switch mutation {
        case .pause:
            succeeded = await model.pause(id)
            expectedAction = .pause(id)
        case .resume:
            succeeded = await model.resume(id)
            expectedAction = .resume(id)
        case .cancel:
            succeeded = await model.cancel(id)
            expectedAction = .cancel(id)
        case .remove:
            succeeded = await model.remove(id)
            expectedAction = .remove(id)
        }
        #expect(succeeded)
        #expect(model.persistenceStatus == .writeFailed)
        #expect(await source.recordedActions() == [expectedAction])
    }
}

@Test
@MainActor
func transferQueueModelSubmitsValidatedDownloadThroughDataSource() async throws {
    let source = TransferQueueDataSourceProbe()
    let model = TransferQueueModel(dataSource: source)
    let destination = URL(fileURLWithPath: "/tmp/product-download.bin")
    let authorization = URL(fileURLWithPath: "/tmp")

    let id = await model.submitDownload(
        sourcePath: "dm://app-sandbox/product-download.bin",
        destinationURL: destination,
        authorizationURL: authorization
    )

    #expect(id != nil)
    #expect(await source.recordedActions() == [
        .submitDownload(
            "dm://app-sandbox/product-download.bin",
            destination.path,
            authorization.path
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

@Test
@MainActor
func transferQueueModelSubmitsSelectedDownloadsInStableInputOrder() async {
    let source = TransferQueueDataSourceProbe()
    let model = TransferQueueModel(dataSource: source)
    let requests = [
        ("dm://media-images/media/1", URL(fileURLWithPath: "/tmp/one.jpg")),
        ("dm://media-images/media/2", URL(fileURLWithPath: "/tmp/two.jpg")),
    ]

    let ids = await model.submitDownloads(requests.map {
        (sourcePath: $0.0, destinationURL: $0.1)
    })

    #expect(ids.count == 2)
    #expect(await source.recordedActions() == [
        .submitDownload(requests[0].0, requests[0].1.path, nil),
        .submitDownload(requests[1].0, requests[1].1.path, nil),
    ])
}
