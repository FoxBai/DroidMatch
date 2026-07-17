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

    #expect(!model.isPersistenceStatusKnown)
    #expect(!model.canPresentTransferSubmission)
    #expect(!model.canPerformQueueActions)
    #expect(!(await model.pause(first.id)))
    #expect(await model.clearCompleted() == nil)
    #expect(await source.recordedActions().isEmpty)
    model.start()
    model.start()
    #expect(await waitForSubscriptionCount(source, expected: 1))
    await source.setPersistenceStatus(.writeFailed)
    await source.yield([first, second], to: 1)
    #expect(await waitForItems(model) { $0.map(\.id) == [first.id, second.id] })
    #expect(model.isObserving)
    #expect(model.items.map(\.localFileName) == ["first", "second"])
    #expect(model.persistenceStatus == .writeFailed)
    #expect(model.isPersistenceStatusKnown)
    #expect(!model.canPresentTransferSubmission)
    #expect(!model.canPerformQueueActions)

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
    #expect(model.canPerformQueueActions)

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
    #expect(!model.canSubmitTransfers)
    await source.blockNextPersistenceRetry()

    let retryTask = Task { await model.retryPersistence() }
    guard await waitForBlockedPersistenceRetry(source) else {
        Issue.record("persistence retry did not enter the controlled suspension")
        await source.releaseBlockedPersistenceRetry()
        _ = await retryTask.value
        model.stop()
        return
    }
    #expect(model.isRetryingPersistence)
    #expect(!model.canSubmitTransfers)
    #expect(!model.canPerformQueueActions)
    #expect(!(await model.cancel(UUID())))
    #expect(await model.submitUpload(
        sourceURL: URL(fileURLWithPath: "/tmp/retry-overlap.bin"),
        directoryPath: "dm://app-sandbox/"
    ) == nil)
    #expect(await source.recordedActions() == [.retryPersistence])

    await source.releaseBlockedPersistenceRetry()
    #expect(await retryTask.value)
    #expect(model.persistenceStatus == .healthy)
    #expect(!model.isRetryingPersistence)
    #expect(model.canSubmitTransfers)
    #expect(model.canPresentTransferSubmission)
    #expect(model.canPerformQueueActions)
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
    #expect(!model.canSubmitTransfers)
    #expect(await source.recordedActions() == [
        .submitDownload("dm://app-sandbox/rejected.bin", "/tmp/rejected.bin", "/tmp"),
    ])
    #expect(await model.submitUpload(
        sourceURL: URL(fileURLWithPath: "/tmp/blocked-after-failure.bin"),
        directoryPath: "dm://app-sandbox/"
    ) == nil)
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
    #expect(!uploadModel.canSubmitTransfers)
    #expect(await uploadSource.recordedActions() == [
        .submitUpload("/tmp/rejected-upload.bin", "dm://app-sandbox/"),
    ])
    #expect(await uploadModel.submitDownload(
        sourcePath: "dm://app-sandbox/blocked-after-failure.bin",
        destinationURL: URL(fileURLWithPath: "/tmp/blocked-after-failure.bin")
    ) == nil)
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
        model.start()
        #expect(await waitForSubscriptionCount(source, expected: 1))
        await source.yield([], to: 1)
        #expect(await waitForPersistenceStatus(model, .healthy))
        #expect(model.canPerformQueueActions)
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
        #expect(!model.canPerformQueueActions)
        #expect(await source.recordedActions() == [expectedAction])
        model.stop()
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

    let rejected = await model.submitUpload(
        sourceURL: URL(fileURLWithPath: "/tmp/not-an-image.mp4"),
        directoryPath: "dm://media-images/"
    )
    #expect(rejected == nil)
    #expect(await source.recordedActions().count == 1)

    let mediaFile = URL(fileURLWithPath: "/tmp/accepted-image.heic")
    let mediaID = await model.submitUpload(
        sourceURL: mediaFile,
        directoryPath: "dm://media-images/"
    )
    #expect(mediaID != nil)
    #expect(await source.recordedActions().last == .submitUpload(
        mediaFile.path,
        "dm://media-images/"
    ))
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

    let admissions = await model.submitDownloads(requests.map {
        (sourcePath: $0.0, destinationURL: $0.1)
    })

    #expect(admissions.map(\.requestIndex) == [0, 1])
    #expect(Set(admissions.map(\.jobID)).count == 2)
    #expect(await source.recordedActions() == [
        .submitDownload(requests[0].0, requests[0].1.path, nil),
        .submitDownload(requests[1].0, requests[1].1.path, nil),
    ])
}

@Test
@MainActor
func transferQueueModelPreservesAcceptedDownloadsWhenBatchAdmissionIsPartial() async {
    let source = TransferQueueDataSourceProbe()
    let model = TransferQueueModel(dataSource: source)
    let requests = [
        ("dm://media-images/media/1", URL(fileURLWithPath: "/tmp/one.jpg")),
        ("dm://media-images/media/2", URL(fileURLWithPath: "/tmp/two.jpg")),
        ("dm://media-images/media/3", URL(fileURLWithPath: "/tmp/three.jpg")),
    ]
    await source.setSubmissionAcceptances([true, false, true])

    let admissions = await model.submitDownloads(requests.map {
        (sourcePath: $0.0, destinationURL: $0.1)
    }, authorizationURL: URL(fileURLWithPath: "/tmp"))

    #expect(admissions.map(\.requestIndex) == [0, 2])
    #expect(Set(admissions.map(\.jobID)).count == 2)
    #expect(model.persistenceStatus == .writeFailed)
    #expect(await source.recordedActions() == requests.map {
        .submitDownload($0.0, $0.1.path, "/tmp")
    })
}

@Test
@MainActor
func transferQueueModelBlocksConcurrentSubmissionBeforeDataSourceSideEffects() async {
    let source = TransferQueueDataSourceProbe()
    let model = TransferQueueModel(dataSource: source)
    let requests = [
        (sourcePath: "dm://app-sandbox/first.bin",
         destinationURL: URL(fileURLWithPath: "/tmp/first.bin")),
        (sourcePath: "dm://app-sandbox/second.bin",
         destinationURL: URL(fileURLWithPath: "/tmp/second.bin")),
    ]
    await source.blockNextSubmission()

    let firstTask = Task { @MainActor in
        await model.submitDownloads(
            requests,
            authorizationURL: URL(fileURLWithPath: "/tmp")
        )
    }
    guard await waitForBlockedSubmission(source) else {
        Issue.record("submission did not enter the controlled suspension")
        await source.releaseBlockedSubmission()
        _ = await firstTask.value
        return
    }

    #expect(model.isSubmittingTransfer)
    #expect(await model.submitUpload(
        sourceURL: URL(fileURLWithPath: "/tmp/duplicate.bin"),
        directoryPath: "dm://app-sandbox/"
    ) == nil)
    #expect(await source.recordedActions() == [
        .submitDownload("dm://app-sandbox/first.bin", "/tmp/first.bin", "/tmp"),
    ])

    await source.releaseBlockedSubmission()
    #expect(await firstTask.value.map(\.requestIndex) == [0, 1])
    #expect(!model.isSubmittingTransfer)
    #expect(await source.recordedActions() == [
        .submitDownload("dm://app-sandbox/first.bin", "/tmp/first.bin", "/tmp"),
        .submitDownload("dm://app-sandbox/second.bin", "/tmp/second.bin", "/tmp"),
    ])
}

@Test
@MainActor
func transferQueueModelClearsOnlySettledCompletionsInStableOrder() async throws {
    let source = TransferQueueDataSourceProbe()
    let model = TransferQueueModel(dataSource: source)
    let first = makeSnapshot(state: .completed, canCancel: false, canRemove: true)
    let failed = makeSnapshot(state: .failed, canCancel: false, canRemove: true)
    let second = makeSnapshot(state: .completed, canCancel: false, canRemove: true)
    let unwinding = makeSnapshot(state: .completed, canCancel: false, canRemove: false)
    let cancelled = makeSnapshot(state: .cancelled, canCancel: false, canRemove: true)

    model.start()
    #expect(await waitForSubscriptionCount(source, expected: 1))
    await source.yield([first, failed, second, unwinding, cancelled], to: 1)
    #expect(await waitForItems(model) { $0.count == 5 })
    await source.rejectRemovals([second.id])

    let result = await model.clearCompleted()

    #expect(result == CompletedTransferRemovalResult(requestedCount: 2, removedCount: 1))
    #expect(result?.isComplete == false)
    #expect(!model.isClearingCompleted)
    #expect(model.pendingActionIDs.isEmpty)
    #expect(await source.recordedActions() == [.remove(first.id), .remove(second.id)])
    model.stop()
}

@Test
@MainActor
func transferQueueModelBlocksDuplicateActionsWhileClearingCompleted() async throws {
    let source = TransferQueueDataSourceProbe()
    let model = TransferQueueModel(dataSource: source)
    let completed = makeSnapshot(state: .completed, canCancel: false, canRemove: true)

    model.start()
    #expect(await waitForSubscriptionCount(source, expected: 1))
    await source.yield([completed], to: 1)
    #expect(await waitForItems(model) { $0.first?.id == completed.id })
    await source.blockNextRemoval()

    let clearTask = Task { await model.clearCompleted() }
    guard await waitForBlockedRemoval(source) else {
        Issue.record("batch removal did not enter the controlled suspension")
        await source.releaseBlockedRemoval()
        _ = await clearTask.value
        model.stop()
        return
    }

    #expect(model.isClearingCompleted)
    #expect(!model.canSubmitTransfers)
    #expect(model.isActionPending(completed.id))
    #expect(model.completedRemovalCount == 0)
    #expect(await model.clearCompleted() == nil)
    #expect(!(await model.remove(completed.id)))
    #expect(await model.submitUpload(
        sourceURL: URL(fileURLWithPath: "/tmp/clear-overlap.bin"),
        directoryPath: "dm://app-sandbox/"
    ) == nil)
    #expect(await source.recordedActions() == [.remove(completed.id)])

    await source.releaseBlockedRemoval()
    #expect(await clearTask.value == CompletedTransferRemovalResult(
        requestedCount: 1,
        removedCount: 1
    ))
    #expect(!model.isClearingCompleted)
    #expect(model.canSubmitTransfers)
    #expect(model.pendingActionIDs.isEmpty)
    model.stop()
}

@Test
@MainActor
func transferQueueModelRefusesBulkCleanupWhilePersistenceIsUnhealthy() async throws {
    let source = TransferQueueDataSourceProbe()
    let model = TransferQueueModel(dataSource: source)
    let completed = makeSnapshot(state: .completed, canCancel: false, canRemove: true)
    await source.setPersistenceStatus(.writeFailed)

    model.start()
    #expect(await waitForSubscriptionCount(source, expected: 1))
    await source.yield([completed], to: 1)
    #expect(await waitForItems(model) { $0.first?.id == completed.id })
    #expect(await waitForPersistenceStatus(model, .writeFailed))

    #expect(await model.clearCompleted() == nil)
    #expect(await source.recordedActions().isEmpty)
    #expect(model.completedRemovalCount == 1)
    model.stop()
}
