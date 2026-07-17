@testable import DroidMatchCore
@testable import DroidMatchPresentation
import Foundation
import Testing

@Test
@MainActor
func mediaLibraryKeepsIndependentSectionBrowsers() async throws {
    let client = DirectoryListingClientProbe()
    let model = MediaLibraryModel(client: client)

    model.start()
    #expect(await waitForDirectoryCallCount(client, 1))
    #expect(await client.call(1)?.query.path == "dm://roots/")
    #expect(await client.call(1)?.query.pageSize == 1_000)
    await client.succeed(1, page(mediaRoots()))

    #expect(await waitForDirectoryCallCount(client, 2))
    #expect(model.phase == .ready)
    #expect(model.selectedSection == .images)
    #expect(model.selectedRoot?.path == "dm://media-images/")
    #expect(await client.call(2)?.query.path == "dm://media-images/")
    await client.succeed(2, page([entry("dm://media-images/media/photo")]))
    #expect(await waitForDirectoryPhase(model.imagesBrowser, .loaded))

    model.select(.albums)
    #expect(await waitForDirectoryCallCount(client, 3))
    #expect(model.selectedBrowser === model.albumsBrowser)
    #expect(await client.call(3)?.query.path == "dm://media-images/albums/")
    await client.succeed(3, page([mediaAlbum()]))
    #expect(await waitForDirectoryPhase(model.albumsBrowser, .loaded))

    model.select(.videos)
    #expect(await waitForDirectoryCallCount(client, 4))
    #expect(model.selectedBrowser === model.videosBrowser)
    await client.succeed(4, page([entry("dm://media-videos/media/video")]))
    #expect(await waitForDirectoryPhase(model.videosBrowser, .loaded))

    // A late Images authorization failure must not invalidate the currently
    // selected Videos browser or issue an automatic root/list retry loop.
    model.requirePermission(for: .images)
    #expect(model.selectedSection == .videos)
    #expect(!model.selectedSectionRequiresPermission)
    #expect(model.videosBrowser.entries.map(\.path) == ["dm://media-videos/media/video"])
    #expect(model.imagesBrowser.entries.isEmpty)
    #expect(model.imagesBrowser.query?.path == "dm://media-images/")

    model.select(.images)
    #expect(model.selectedSectionRequiresPermission)
    #expect(await client.count() == 4)
}

@Test
@MainActor
func mediaLibraryRevocationClearsCachedNamesWithoutListingUnreadableRoot() async throws {
    let client = DirectoryListingClientProbe()
    let model = MediaLibraryModel(client: client)

    model.start()
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.succeed(1, page(mediaRoots()))
    #expect(await waitForDirectoryCallCount(client, 2))
    await client.succeed(2, page([entry("dm://media-images/media/private-name")]))
    #expect(await waitForDirectoryPhase(model.imagesBrowser, .loaded))

    // Android 14 can change its selected-photo set while the category root
    // remains readable. Explicit access refresh must clear old names first,
    // then reload every previously loaded query after the root catalog passes.
    model.refreshAccess()
    #expect(model.phase == .loadingAccess)
    #expect(model.imagesBrowser.entries.isEmpty)
    #expect(model.imagesBrowser.query?.path == "dm://media-images/")
    #expect(await waitForDirectoryCallCount(client, 3))
    await client.succeed(3, page(mediaRoots()))
    #expect(await waitForDirectoryCallCount(client, 4))
    #expect(await client.call(4)?.query.path == "dm://media-images/")
    await client.succeed(4, page([entry("dm://media-images/media/allowed-name")]))
    #expect(await waitForDirectoryPhase(model.imagesBrowser, .loaded))
    #expect(model.imagesBrowser.entries.map(\.path) == [
        "dm://media-images/media/allowed-name",
    ])

    #expect(model.imagesBrowser.refresh())
    #expect(await waitForDirectoryCallCount(client, 5))
    await client.fail(5, .remote(.permissionRequired))
    #expect(await waitForDirectoryPhase(model.imagesBrowser, .failed))
    #expect(model.imagesBrowser.entries.isEmpty)
    #expect(model.imagesBrowser.thumbnails.isEmpty)

    model.requirePermission(for: .images)
    #expect(model.selectedSectionRequiresPermission)
    #expect(model.selectedRoot?.canBrowse == true)
    #expect(model.imagesBrowser.query?.path == "dm://media-images/")
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(await client.count() == 5)

    model.refreshAccess()
    #expect(await waitForDirectoryCallCount(client, 6))
    await client.succeed(6, page(mediaRoots(imagesReadable: false)))
    #expect(await waitForMediaLibraryPhase(model, .ready))

    #expect(model.selectedRoot?.canBrowse == false)
    #expect(model.selectedRoot?.canAcceptUpload == true)
    #expect(model.imagesBrowser.query == nil)
    #expect(model.imagesBrowser.entries.isEmpty)
    #expect(model.imagesBrowser.thumbnails.isEmpty)
    #expect(await client.count() == 6)
}

@Test
@MainActor
func mediaLibraryMapsRootCatalogFailureAndRetriesLatestGeneration() async throws {
    let client = DirectoryListingClientProbe()
    let model = MediaLibraryModel(client: client)

    model.start()
    #expect(await waitForDirectoryCallCount(client, 1))
    await client.fail(1, .remote(.transportLost))
    #expect(await waitForMediaLibraryPhase(model, .failed))
    #expect(model.failure == .unavailable)
    #expect(model.selectedRoot == nil)

    model.refreshAccess()
    #expect(await waitForDirectoryCallCount(client, 2))
    await client.succeed(2, page(mediaRoots(imagesReadable: false)))
    #expect(await waitForMediaLibraryPhase(model, .ready))
    #expect(model.failure == nil)
    #expect(model.selectedRoot?.canBrowse == false)
    #expect(await client.count() == 2)
}

private func mediaRoots(imagesReadable: Bool = true) -> [DirectoryListingEntry] {
    [
        mediaRoot(
            path: "dm://media-images/",
            name: "Images",
            canRead: imagesReadable,
            canWrite: true
        ),
        mediaRoot(
            path: "dm://media-images/albums/",
            name: "Image Albums",
            canRead: true,
            canWrite: false
        ),
        mediaRoot(
            path: "dm://media-videos/",
            name: "Videos",
            canRead: true,
            canWrite: true
        )
    ]
}

private func mediaRoot(
    path: String,
    name: String,
    canRead: Bool,
    canWrite: Bool
) -> DirectoryListingEntry {
    DirectoryListingEntry(
        path: path,
        name: name,
        kind: .virtual,
        sizeBytes: nil,
        modifiedUnixMillis: nil,
        mimeType: "vnd.droidmatch.root",
        canRead: canRead,
        canWrite: canWrite
    )
}

private func mediaAlbum() -> DirectoryListingEntry {
    DirectoryListingEntry(
        path: "dm://media-images/albums/opaque/",
        name: "Album",
        kind: .directory,
        sizeBytes: nil,
        modifiedUnixMillis: nil,
        mimeType: "vnd.droidmatch.album",
        canRead: true,
        canWrite: false
    )
}

@MainActor
private func waitForMediaLibraryPhase(
    _ model: MediaLibraryModel,
    _ expected: MediaLibraryPhase
) async -> Bool {
    for _ in 0..<200 {
        if model.phase == expected { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}
