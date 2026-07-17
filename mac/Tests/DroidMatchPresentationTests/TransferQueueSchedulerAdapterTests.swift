@testable import DroidMatchCore
import DroidMatchPresentation
import Foundation
import Testing

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
        destinationURL: URL(fileURLWithPath: "/tmp/rejected.bin"),
        authorizationURL: nil
    ) == nil)
    #expect(await source.submitDownload(
        sourcePath: "dm://app-sandbox/valid.bin",
        destinationURL: URL(string: "https://example.invalid/rejected.bin")!,
        authorizationURL: nil
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
    #expect(await source.submitUpload(
        sourceURL: URL(fileURLWithPath: "/tmp/video.mp4"),
        directoryPath: "dm://media-images/"
    ) == nil)
    #expect(await source.submitUpload(
        sourceURL: URL(fileURLWithPath: "/tmp/image.jpg"),
        directoryPath: "dm://media-videos/"
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
