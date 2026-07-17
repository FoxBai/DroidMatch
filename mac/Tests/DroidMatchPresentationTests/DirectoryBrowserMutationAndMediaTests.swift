@testable import DroidMatchCore
@testable import DroidMatchPresentation
import Foundation
import Testing

@Test
@MainActor
func directoryBrowserCreatesDirectChildThenRefreshes() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://app-sandbox/exports/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.createDirectory(named: "Receipts"))
    #expect(await waitForDirectoryCallCount(client, 2))
    #expect(await client.lastCreatedPath() == "dm://app-sandbox/exports/Receipts/")
    await client.succeed(2, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))
    #expect(model.mutationFailure == nil)
}

@Test
@MainActor
func directoryBrowserRejectsUnsafeNameAndClassifiesRemoteFailure() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://app-sandbox/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(!model.createDirectory(named: "../escape"))
    #expect(model.mutationFailure == .invalidName)

    await client.setCreateError(.remote(.alreadyExists))
    #expect(model.createDirectory(named: "Existing"))
    for _ in 0..<200 where model.isMutating {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(model.mutationFailure == .alreadyExists)
    #expect(await client.lastCreatedPath() == "dm://app-sandbox/Existing/")
}

@Test
@MainActor
func directoryBrowserNavigationClearsPriorDirectoryMutationFailure() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://app-sandbox/old/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(!model.createDirectory(named: "../unsafe"))
    #expect(model.mutationFailure == .invalidName)

    model.load(DirectoryListingQuery(path: "dm://app-sandbox/new/"))
    #expect(model.mutationFailure == nil)
    #expect(await waitForDirectoryCallCount(client, 2))
    await client.succeed(2, page([]))
}

@Test
@MainActor
func directoryBrowserRenamesVisibleWritableEntryThenRefreshes() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://app-sandbox/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    let writable = DirectoryListingEntry(
        path: "dm://app-sandbox/Before/",
        name: "Before",
        kind: .directory,
        sizeBytes: nil,
        modifiedUnixMillis: 1,
        mimeType: "inode/directory",
        canRead: true,
        canWrite: true
    )
    await client.succeed(1, page([writable]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.rename(model.entries[0], to: "After"))
    #expect(await waitForDirectoryCallCount(client, 2))
    #expect(await client.lastRename() == [
        "dm://app-sandbox/Before/",
        "dm://app-sandbox/After/",
    ])
    await client.succeed(2, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))
}

@Test
@MainActor
func directoryBrowserDeletesConfirmedDirectoryRecursivelyThenRefreshes() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://app-sandbox/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    let writable = DirectoryListingEntry(
        path: "dm://app-sandbox/Archive/",
        name: "Archive",
        kind: .directory,
        sizeBytes: nil,
        modifiedUnixMillis: 1,
        mimeType: "inode/directory",
        canRead: true,
        canWrite: true
    )
    await client.succeed(1, page([writable]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.delete(model.entries[0]))
    #expect(await waitForDirectoryCallCount(client, 2))
    let deletion = await client.lastDelete()
    #expect(deletion?.0 == "dm://app-sandbox/Archive/")
    #expect(deletion?.1 == true)
    await client.succeed(2, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))
}

@Test
@MainActor
func directoryBrowserBatchDeleteIsStableAndRefreshesAfterPartialFailure() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://app-sandbox/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    let first = DirectoryListingEntry(
        path: "dm://app-sandbox/a.txt", name: "a.txt", kind: .file,
        sizeBytes: 1, modifiedUnixMillis: 1, mimeType: "text/plain",
        canRead: true, canWrite: true
    )
    let second = DirectoryListingEntry(
        path: "dm://app-sandbox/b/", name: "b", kind: .directory,
        sizeBytes: nil, modifiedUnixMillis: 1, mimeType: "inode/directory",
        canRead: true, canWrite: true
    )
    await client.succeed(1, page([second, first]))
    #expect(await waitForDirectoryPhase(model, .loaded))
    await client.failDelete(at: 2)

    #expect(model.delete(Array(model.entries.reversed())))
    #expect(await waitForDirectoryCallCount(client, 2))
    #expect(await client.deletes().map(\.0) == [first.path, second.path])
    #expect(await client.deletes().map(\.1) == [false, true])
    #expect(model.mutationFailure == .partialFailure)
    await client.succeed(2, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))
}

@Test
@MainActor
func directoryBrowserLoadsVisibleMediaThumbnailOnce() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://media-images/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    let media = DirectoryListingEntry(
        path: "dm://media-images/media/42", name: "photo.jpg", kind: .file,
        sizeBytes: 10, modifiedUnixMillis: 1, mimeType: "image/jpeg",
        canRead: true, canWrite: false
    )
    await client.succeed(1, page([media]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    model.loadThumbnail(for: model.entries[0])
    for _ in 0..<200 where model.thumbnails[media.path] == nil {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    model.loadThumbnail(for: model.entries[0])
    #expect(model.thumbnails[media.path] == Data([1, 2, 3]))
    #expect(await client.thumbnailCalls() == [media.path])

    // The cache is bounded by bytes as well as item count. Nine 1 MiB
    // derivatives must evict the oldest entry instead of retaining 9 MiB.
    await client.setThumbnailData(Data(repeating: 7, count: 1_024 * 1_024))
    await client.setThumbnailHold(true)
    model.load(DirectoryListingQuery(path: "dm://media-images/"))
    #expect(await waitForDirectoryCallCount(client, 2))
    let manyMedia = (0..<9).map { index in
        DirectoryListingEntry(
            path: "dm://media-images/media/large-\(index)",
            name: "large-\(index).jpg",
            kind: .file,
            sizeBytes: 10,
            modifiedUnixMillis: 1,
            mimeType: "image/jpeg",
            canRead: true,
            canWrite: false
        )
    }
    await client.succeed(2, page(manyMedia))
    #expect(await waitForDirectoryPhase(model, .loaded))
    for item in model.entries { model.loadThumbnail(for: item) }
    for entry in manyMedia {
        for _ in 0..<200 {
            if await client.thumbnailCalls().contains(entry.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await client.completeThumbnail(path: entry.path)
        for _ in 0..<200 where model.thumbnails[entry.path] == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    #expect(model.thumbnails.count == 8)
    #expect(model.thumbnails[manyMedia[0].path] == nil)
    #expect(Set(model.thumbnails.keys) == Set(manyMedia.dropFirst().map(\.path)))
    #expect(model.thumbnails.values.reduce(0) { $0 + $1.count }
        <= 8 * 1_024 * 1_024)
    await client.setThumbnailHold(false)
}

@Test @MainActor
func directoryBrowserLoadsBoundedMediaPreviewAndClearsIt() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://media-images/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    let media = DirectoryListingEntry(
        path: "dm://media-images/media/42", name: "photo.jpg", kind: .file,
        sizeBytes: 10, modifiedUnixMillis: 1, mimeType: "image/jpeg",
        canRead: true, canWrite: false
    )
    await client.succeed(1, page([media]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.loadPreview(for: model.entries[0]))
    for _ in 0..<200 where model.preview == nil {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(model.preview?.encodedImage == Data([1, 2, 3]))
    #expect(await client.thumbnailDimensions() == [512])
    #expect(!model.isLoadingPreview)
    #expect(!model.previewFailed)

    model.clearPreview()
    #expect(model.preview == nil)

    await client.setThumbnailHold(true)
    #expect(model.loadPreview(for: model.entries[0]))
    for _ in 0..<200 {
        if await client.thumbnailCallCount() == 2 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    model.clearPreview()
    #expect(model.loadPreview(for: model.entries[0]))
    #expect(await client.thumbnailCallCount() == 2)
    #expect(await client.thumbnailCancellations() == 0)
    #expect(await client.maximumThumbnailActiveRequests() == 1)
    await client.failThumbnail(
        path: media.path,
        error: .remote(.permissionRequired)
    )
    #expect(await waitForDirectoryPhase(model, .failed))
    #expect(model.failure == .permissionRequired)
    #expect(model.entries.isEmpty)
    #expect(model.preview == nil)
    #expect(!model.isLoadingPreview)
    #expect(await client.thumbnailCallCount() == 2)
    await client.setThumbnailHold(false)
}

@Test
@MainActor
func directoryBrowserAcceptsPendingPreviewAfterLoadMoreCompletes() async throws {
    let client = DirectoryListingClientProbe()
    await client.setThumbnailHold(true)
    let model = DirectoryBrowserModel(client: client)
    let query = DirectoryListingQuery(path: "dm://media-images/")
    let media = DirectoryListingEntry(
        path: "dm://media-images/media/42",
        name: "photo.jpg",
        kind: .file,
        sizeBytes: 10,
        modifiedUnixMillis: 1,
        mimeType: "image/jpeg",
        canRead: true,
        canWrite: false
    )

    model.load(query)
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page([media], next: "page-2"))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.loadPreview(for: model.entries[0]))
    for _ in 0..<200 {
        if await client.thumbnailCallCount() == 1 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(await client.thumbnailDimensions() == [512])
    #expect(model.isLoadingPreview)

    #expect(model.loadMore())
    #expect(await waitForDirectoryCallCount(client, 2))
    await client.succeed(2, page([], next: nil))
    #expect(await waitForDirectoryPhase(model, .loaded))
    #expect(model.isLoadingPreview)

    await client.completeThumbnail(path: media.path)
    for _ in 0..<200 where model.preview == nil {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(model.preview?.encodedImage == Data([1, 2, 3]))
    #expect(!model.isLoadingPreview)
    #expect(!model.previewFailed)
}

@Test @MainActor
func directoryBrowserLoadsImageAlbumCoverWithoutTreatingItAsPreview() async throws {
    let client = DirectoryListingClientProbe()
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://media-images/albums/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    let album = DirectoryListingEntry(
        path: "dm://media-images/albums/0123456789abcdef01234567/",
        name: "Camera",
        kind: .directory,
        sizeBytes: nil,
        modifiedUnixMillis: 1,
        mimeType: "vnd.droidmatch.media-album",
        canRead: true,
        canWrite: false
    )
    await client.succeed(1, page([album]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    model.loadThumbnail(for: model.entries[0])
    for _ in 0..<200 where model.thumbnails[album.path] == nil {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(model.thumbnails[album.path] == Data([1, 2, 3]))
    #expect(await client.thumbnailDimensions() == [96])
    #expect(!model.loadPreview(for: model.entries[0]))

    model.suspendDerivativeWork()
    await client.setThumbnailHold(true)
    model.loadThumbnail(for: model.entries[0])
    for _ in 0..<200 {
        if await client.thumbnailCallCount() == 2 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    await client.failThumbnail(
        path: album.path,
        error: .remote(.permissionRequired)
    )
    #expect(await waitForDirectoryPhase(model, .failed))
    #expect(model.failure == .permissionRequired)
    #expect(model.entries.isEmpty)
    #expect(model.thumbnails.isEmpty)
    await client.setThumbnailHold(false)
}

@Test
@MainActor
func directoryBrowserBoundsThumbnailFIFOAndDropsOldGenerationQueue() async throws {
    let client = DirectoryListingClientProbe()
    await client.setThumbnailHold(true)
    let model = DirectoryBrowserModel(client: client)
    let query = DirectoryListingQuery(path: "dm://media-images/")
    model.load(query)
    #expect(await waitForDirectoryCallCount(client, 1))
    let oldEntries = (0..<12).map { index in
        DirectoryListingEntry(
            path: "dm://media-images/media/\(index + 100)",
            name: "old-\(index).jpg",
            kind: .file,
            sizeBytes: 10,
            modifiedUnixMillis: 1,
            mimeType: "image/jpeg",
            canRead: true,
            canWrite: false
        )
    }
    await client.succeed(1, page(oldEntries))
    #expect(await waitForDirectoryPhase(model, .loaded))
    for item in model.entries {
        model.loadThumbnail(for: item)
    }
    for _ in 0..<200 {
        if await client.thumbnailCallCount() >= 4 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(await client.thumbnailCallCount() == 4)
    #expect(await client.thumbnailActiveRequests() == 4)

    model.suspendDerivativeWork()
    #expect(model.query == query)
    #expect(model.entries.count == oldEntries.count)
    #expect(model.thumbnails.isEmpty)
    #expect(await client.thumbnailCallCount() == 4)

    model.invalidateAuthorizationContent()
    #expect(model.query == query)
    #expect(model.entries.isEmpty)
    #expect(await client.thumbnailCancellations() == 0)

    model.load(query)
    #expect(await waitForDirectoryCallCount(client, 2))
    let newEntries = (0..<2).map { index in
        DirectoryListingEntry(
            path: "dm://media-images/media/\(index + 900)",
            name: "new-\(index).jpg",
            kind: .file,
            sizeBytes: 10,
            modifiedUnixMillis: 2,
            mimeType: "image/jpeg",
            canRead: true,
            canWrite: false
        )
    }
    await client.succeed(2, page(newEntries))
    #expect(await waitForDirectoryPhase(model, .loaded))
    for item in model.entries {
        model.loadThumbnail(for: item)
    }
    #expect(await client.thumbnailCallCount() == 4)

    for entry in oldEntries.prefix(4) {
        await client.completeThumbnail(path: entry.path)
    }
    for _ in 0..<200 {
        if await client.thumbnailCallCount() >= 6 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(await client.thumbnailCalls() ==
        oldEntries.prefix(4).map(\.path) + newEntries.map(\.path))
    #expect(await client.maximumThumbnailActiveRequests() == 4)
    #expect(model.thumbnails.isEmpty)

    for entry in newEntries {
        await client.completeThumbnail(path: entry.path)
    }
    for _ in 0..<200 where model.thumbnails.count < 2 {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(Set(model.thumbnails.keys) == Set(newEntries.map(\.path)))
}

@Test
@MainActor
func directoryBrowserNavigationDoesNotCancelAdmittedMutation() async throws {
    let client = DirectoryListingClientProbe()
    await client.setCreateHold(true)
    let model = DirectoryBrowserModel(client: client)
    model.load(DirectoryListingQuery(path: "dm://app-sandbox/old/"))
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.createDirectory(named: "Committed"))
    for _ in 0..<200 {
        if await client.lastCreatedPath() != nil { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(await client.lastCreatedPath() == "dm://app-sandbox/old/Committed/")

    model.load(DirectoryListingQuery(path: "dm://app-sandbox/new/"))
    #expect(await waitForDirectoryCallCount(client, 2))
    #expect(model.isMutating)
    #expect(!model.createDirectory(named: "MustWait"))

    await client.completeCreate()
    for _ in 0..<200 where model.isMutating {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(!model.isMutating)
    #expect(model.mutationFailure == nil)
    #expect(await client.count() == 2)
    await client.succeed(2, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))
}

@Test
@MainActor
func directoryBrowserMutationRefreshesCurrentQueryAfterSamePathSearchChange() async throws {
    let client = DirectoryListingClientProbe()
    await client.setCreateHold(true)
    let model = DirectoryBrowserModel(client: client)
    let originalQuery = DirectoryListingQuery(
        path: "dm://app-sandbox/shared/",
        searchQuery: "before"
    )
    let currentQuery = DirectoryListingQuery(
        path: originalQuery.path,
        searchQuery: "after"
    )

    model.load(originalQuery)
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))

    #expect(model.createDirectory(named: "Committed"))
    for _ in 0..<200 {
        if await client.lastCreatedPath() != nil { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(await client.lastCreatedPath() ==
        "dm://app-sandbox/shared/Committed/")

    model.load(currentQuery)
    #expect(await waitForDirectoryCallCount(client, 2))
    await client.succeed(2, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))
    #expect(await client.call(2)?.query == currentQuery)

    await client.completeCreate()
    #expect(await waitForDirectoryCallCount(client, 3))
    #expect(await client.call(3)?.query == currentQuery)
    #expect(await client.call(3)?.query != originalQuery)
    await client.succeed(3, page([]))
    #expect(await waitForDirectoryPhase(model, .loaded))
    #expect(!model.isMutating)
    #expect(model.mutationFailure == nil)
}

@Test
func directoryBrowserItemSanitizesDisplayNameWithoutChangingIdentity() {
    let rawName = "invoice\u{202E}gpj\n\u{200B}.txt"
    let item = DirectoryBrowserItem(DirectoryListingEntry(
        path: "dm://app-sandbox/original-id",
        name: rawName,
        kind: .file,
        sizeBytes: 1,
        modifiedUnixMillis: 1,
        mimeType: "text/plain",
        canRead: true,
        canWrite: true
    ))

    #expect(item.safeDisplayName == "invoicegpj .txt")
    #expect(item.name == rawName)
    #expect(item.path == "dm://app-sandbox/original-id")

    let hidden = DirectoryBrowserItem(DirectoryListingEntry(
        path: "dm://app-sandbox/hidden-id",
        name: "\u{202E}\n\u{200B}",
        kind: .file,
        sizeBytes: nil,
        modifiedUnixMillis: nil,
        mimeType: nil,
        canRead: true,
        canWrite: false
    ))
    #expect(hidden.safeDisplayName == nil)
}
