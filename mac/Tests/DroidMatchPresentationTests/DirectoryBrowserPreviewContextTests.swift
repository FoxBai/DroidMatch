@testable import DroidMatchCore
@testable import DroidMatchPresentation
import Foundation
import Testing

@Test
@MainActor
func directoryBrowserPreviewContextRejectsCrossWindowPublicationAndDismissal() async throws {
    let client = DirectoryListingClientProbe()
    await client.setThumbnailHold(true)
    let model = DirectoryBrowserModel(client: client)
    let first = previewMediaEntry(path: "dm://media-images/media/first", name: "first.jpg")
    let second = previewMediaEntry(path: "dm://media-images/media/second", name: "second.jpg")

    model.load(DirectoryListingQuery(path: "dm://media-images/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page([first, second]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    let firstTarget = try #require(model.loadPreview(for: model.entries[0]))
    #expect(await waitForThumbnailCallCount(client, 1))
    let secondTarget = try #require(model.loadPreview(for: model.entries[1]))

    #expect(model.previewState(for: firstTarget.context) == .invalidated)
    #expect(model.previewState(for: secondTarget.context) == .loading)
    #expect(!model.clearPreview(context: firstTarget.context))
    #expect(model.previewState(for: secondTarget.context) == .loading)
    #expect(await client.thumbnailCallCount() == 1)
    #expect(await client.maximumThumbnailActiveRequests() == 1)

    await client.completeThumbnail(path: first.path)
    #expect(await waitForThumbnailCallCount(client, 2))
    await client.completeThumbnail(path: second.path)
    #expect(await waitForReadyPreview(model, context: secondTarget.context))

    #expect(model.previewState(for: firstTarget.context) == .invalidated)
    guard case let .ready(preview) = model.previewState(for: secondTarget.context) else {
        Issue.record("Expected only the second window context to receive its preview")
        return
    }
    #expect(preview.encodedImage == Data([1, 2, 3]))
    #expect(!model.clearPreview(context: firstTarget.context))
    #expect(model.previewState(for: secondTarget.context) == .ready(preview))
    #expect(model.clearPreview(context: secondTarget.context))
    #expect(model.previewState(for: secondTarget.context) == .invalidated)
    #expect(await client.thumbnailCancellations() == 0)
    #expect(await client.maximumThumbnailActiveRequests() == 1)
}

@Test
@MainActor
func directoryBrowserPreviewContextRejectsSamePathAfterRefresh() async throws {
    let client = DirectoryListingClientProbe()
    await client.setThumbnailHold(true)
    let model = DirectoryBrowserModel(client: client)
    let query = DirectoryListingQuery(path: "dm://media-images/")
    let media = previewMediaEntry(path: "dm://media-images/media/same", name: "same.jpg")

    model.load(query)
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page([media]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    let oldTarget = try #require(model.loadPreview(for: model.entries[0]))
    #expect(await waitForThumbnailCallCount(client, 1))
    #expect(model.refresh())
    #expect(model.previewState(for: oldTarget.context) == .invalidated)
    #expect(await waitForDirectoryCallCount(client, 2))

    await client.completeThumbnail(path: media.path)
    await client.succeed(2, page([media]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    let newTarget = try #require(model.loadPreview(for: model.entries[0]))
    #expect(newTarget.context != oldTarget.context)
    #expect(await waitForThumbnailCallCount(client, 2))
    await client.completeThumbnail(path: media.path)
    #expect(await waitForReadyPreview(model, context: newTarget.context))

    #expect(!model.clearPreview(context: oldTarget.context))
    guard case let .ready(preview) = model.previewState(for: newTarget.context) else {
        Issue.record("Expected the refreshed row's context to remain ready")
        return
    }
    #expect(preview.encodedImage == Data([1, 2, 3]))
    #expect(model.previewState(for: oldTarget.context) == .invalidated)
    #expect(await client.thumbnailCancellations() == 0)
    #expect(await client.maximumThumbnailActiveRequests() == 1)
}

@Test
@MainActor
func directoryBrowserPreviewContextSettlesAfterNavigationAndAuthorizationLoss() async throws {
    let client = DirectoryListingClientProbe()
    await client.setThumbnailHold(true)
    let model = DirectoryBrowserModel(client: client)
    let first = previewMediaEntry(path: "dm://media-images/media/old", name: "old.jpg")
    let second = previewMediaEntry(path: "dm://media-images/media/new", name: "new.jpg")

    model.load(DirectoryListingQuery(path: "dm://media-images/old/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page([first]))
    #expect(await waitForDirectoryPhase(model, .loaded))
    let navigationTarget = try #require(model.loadPreview(for: model.entries[0]))
    #expect(await waitForThumbnailCallCount(client, 1))

    model.load(DirectoryListingQuery(path: "dm://media-images/new/"))
    #expect(model.previewState(for: navigationTarget.context) == .invalidated)
    #expect(await waitForDirectoryCallCount(client, 2))
    await client.completeThumbnail(path: first.path)
    await client.succeed(2, page([second]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    let authorizationTarget = try #require(model.loadPreview(for: model.entries[0]))
    #expect(await waitForThumbnailCallCount(client, 2))
    model.invalidateAuthorizationContent()

    #expect(model.previewState(for: authorizationTarget.context) == .invalidated)
    #expect(model.entries.isEmpty)
    #expect(model.phase == .idle)
    await client.completeThumbnail(path: second.path)
    #expect(await waitForNoActiveThumbnails(client))
    #expect(model.previewState(for: navigationTarget.context) == .invalidated)
    #expect(model.previewState(for: authorizationTarget.context) == .invalidated)
    #expect(await client.thumbnailCancellations() == 0)
    #expect(await client.maximumThumbnailActiveRequests() == 1)
}

private func previewMediaEntry(path: String, name: String) -> DirectoryListingEntry {
    DirectoryListingEntry(
        path: path,
        name: name,
        kind: .file,
        sizeBytes: 10,
        modifiedUnixMillis: 1,
        mimeType: "image/jpeg",
        canRead: true,
        canWrite: false
    )
}

private func waitForThumbnailCallCount(
    _ client: DirectoryListingClientProbe,
    _ expected: Int
) async -> Bool {
    for _ in 0..<200 {
        if await client.thumbnailCallCount() == expected { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@MainActor
private func waitForReadyPreview(
    _ model: DirectoryBrowserModel,
    context: DirectoryPreviewContext
) async -> Bool {
    for _ in 0..<200 {
        if case .ready = model.previewState(for: context) { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

private func waitForNoActiveThumbnails(_ client: DirectoryListingClientProbe) async -> Bool {
    for _ in 0..<200 {
        if await client.thumbnailActiveRequests() == 0 { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}
