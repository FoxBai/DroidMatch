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

    #expect(item.safeDisplayName == "invoicegpj.txt")
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
