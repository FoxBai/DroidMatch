import Foundation
import Testing
@testable import DroidMatchCore

@Test func directoryListingCodecBuildsCompleteOpaquePageRequest() throws {
    let query = DirectoryListingQuery(
        path: "dm://media-images/",
        pageSize: 75,
        sortField: .name,
        descending: true,
        searchQuery: "photo"
    )

    let request = try DirectoryListingCodec.request(
        query: query,
        pageToken: "opaque-provider-token"
    )

    #expect(request.path == query.path)
    #expect(request.pageSize == 75)
    #expect(request.sortField == .name)
    #expect(request.descending)
    #expect(request.pageToken == "opaque-provider-token")
    #expect(request.searchQuery == "photo")
}

@Test func directoryListingCodecRejectsInvalidProductQueriesBeforeTransport() {
    #expect(throws: DirectoryListingError.invalidPath) {
        _ = try DirectoryListingCodec.request(
            query: DirectoryListingQuery(path: "/private/device-path"),
            pageToken: nil
        )
    }
    #expect(throws: DirectoryListingError.invalidPageSize) {
        _ = try DirectoryListingCodec.request(
            query: DirectoryListingQuery(path: "dm://roots/", pageSize: 0),
            pageToken: nil
        )
    }
    #expect(throws: DirectoryListingError.invalidPageSize) {
        _ = try DirectoryListingCodec.request(
            query: DirectoryListingQuery(path: "dm://roots/", pageSize: 1_001),
            pageToken: nil
        )
    }
}

@Test func directoryListingCodecMapsProviderRootsAndUnknownMetadata() throws {
    var root = Droidmatch_V1_FileEntry()
    root.path = "dm://media-images/"
    root.kind = .virtual
    root.modifiedUnixMillis = 0
    root.mimeType = "vnd.droidmatch.root"
    root.durationMillis = 9_999
    root.canRead = true

    var file = Droidmatch_V1_FileEntry()
    file.path = "dm://media-images/media/42"
    file.name = "IMG_0042.jpg"
    file.kind = .file
    file.sizeBytes = 1_024
    file.modifiedUnixMillis = 1_700_000_000_000
    file.mimeType = "IMAGE/JPEG"
    file.durationMillis = 12_345
    file.canRead = true

    var video = Droidmatch_V1_FileEntry()
    video.path = "dm://media-videos/media/43"
    video.name = "VID_0043.mp4"
    video.kind = .file
    video.sizeBytes = 2_048
    video.mimeType = "video/mp4"
    video.durationMillis = 123_456
    video.canRead = true

    var response = Droidmatch_V1_ListDirResponse()
    response.entries = [root, file, video]
    response.nextPageToken = "opaque-next"

    let page = try DirectoryListingCodec.page(
        response: response,
        requestedPageToken: nil
    )

    #expect(page.entries.map(\.path) == [root.path, file.path, video.path])
    #expect(page.entries.map(\.kind) == [.virtual, .file, .file])
    #expect(page.entries.map(\.name) == [nil, "IMG_0042.jpg", "VID_0043.mp4"])
    #expect(page.entries[0].sizeBytes == nil)
    #expect(page.entries[0].modifiedUnixMillis == nil)
    #expect(page.entries[1].sizeBytes == 1_024)
    #expect(page.entries[1].modifiedUnixMillis == 1_700_000_000_000)
    #expect(page.entries.map(\.mimeType) == [
        "vnd.droidmatch.root", "image/jpeg", "video/mp4",
    ])
    #expect(page.entries.map(\.durationMillis) == [nil, nil, 123_456])
    #expect(page.nextPageToken == "opaque-next")
    #expect(ProductMimeType.value("vnd.android.document/directory")
        == "vnd.android.document/directory")
    #expect(ProductMimeType.value("video/mp4\n\u{202E}text/plain") == nil)
    #expect(ProductMimeType.value("image/jpeg; charset=utf-8") == nil)
    #expect(ProductMimeType.value(String(repeating: "a", count: 128) + "/x") == nil)
}

@Test func directoryListingCodecMapsEmbeddedRemoteErrorsWithoutMessageLeakage() {
    var remoteError = Droidmatch_V1_DroidMatchError()
    remoteError.code = .permissionRequired
    remoteError.message = "private filename IMG_0042.jpg is denied"
    var response = Droidmatch_V1_ListDirResponse()
    response.error = remoteError

    do {
        _ = try DirectoryListingCodec.page(
            response: response,
            requestedPageToken: nil
        )
        Issue.record("expected embedded list error")
    } catch let error as DirectoryListingError {
        #expect(error == .remote(.permissionRequired))
        #expect(!error.description.contains("IMG_0042.jpg"))
    } catch {
        Issue.record("unexpected listing error type")
    }
}

@Test func directoryListingCodecRejectsUnstableRowIdentityAndTokenLoops() {
    var entry = Droidmatch_V1_FileEntry()
    entry.path = "dm://app-sandbox/file.bin"
    entry.name = "file.bin"
    entry.kind = .file
    var duplicateResponse = Droidmatch_V1_ListDirResponse()
    duplicateResponse.entries = [entry, entry]

    #expect(throws: DirectoryListingError.invalidResponse(.duplicateEntryPath)) {
        _ = try DirectoryListingCodec.page(
            response: duplicateResponse,
            requestedPageToken: nil
        )
    }

    var invalidKind = entry
    invalidKind.path = "dm://app-sandbox/other.bin"
    invalidKind.kind = .unspecified
    var invalidKindResponse = Droidmatch_V1_ListDirResponse()
    invalidKindResponse.entries = [invalidKind]
    #expect(throws: DirectoryListingError.invalidResponse(.invalidEntryKind)) {
        _ = try DirectoryListingCodec.page(
            response: invalidKindResponse,
            requestedPageToken: nil
        )
    }

    var loopingResponse = Droidmatch_V1_ListDirResponse()
    loopingResponse.entries = [entry]
    loopingResponse.nextPageToken = "same-token"
    #expect(throws: DirectoryListingError.invalidResponse(.repeatedPageToken)) {
        _ = try DirectoryListingCodec.page(
            response: loopingResponse,
            requestedPageToken: "same-token"
        )
    }
}

@Test func directoryListingTraversalCountsPagesAndReturnsOpaqueTokens() throws {
    var traversal = DirectoryListingTraversal()
    let firstToken = try traversal.accept(DirectoryListingPage(
        entries: [listingEntry(path: "dm://app-sandbox/a")],
        nextPageToken: "opaque-1"
    ))
    let finalToken = try traversal.accept(DirectoryListingPage(
        entries: [listingEntry(path: "dm://app-sandbox/b")],
        nextPageToken: nil
    ))

    #expect(firstToken == "opaque-1")
    #expect(finalToken == nil)
    #expect(traversal.entryCount == 2)
    #expect(traversal.pageCounts == [1, 1])
}

@Test func directoryListingTraversalRejectsCrossPageIdentityAndTokenCycles() throws {
    var duplicateTraversal = DirectoryListingTraversal()
    _ = try duplicateTraversal.accept(DirectoryListingPage(
        entries: [listingEntry(path: "dm://app-sandbox/same")],
        nextPageToken: "opaque-1"
    ))
    #expect(throws: DirectoryListingError.invalidResponse(.crossPageDuplicateEntryPath)) {
        _ = try duplicateTraversal.accept(DirectoryListingPage(
            entries: [listingEntry(path: "dm://app-sandbox/same")],
            nextPageToken: nil
        ))
    }

    var tokenTraversal = DirectoryListingTraversal()
    _ = try tokenTraversal.accept(DirectoryListingPage(
        entries: [],
        nextPageToken: "opaque-cycle"
    ))
    #expect(throws: DirectoryListingError.invalidResponse(.paginationTokenCycle)) {
        _ = try tokenTraversal.accept(DirectoryListingPage(
            entries: [],
            nextPageToken: "opaque-cycle"
        ))
    }
}

private func listingEntry(path: String) -> DirectoryListingEntry {
    DirectoryListingEntry(
        path: path,
        name: nil,
        kind: .file,
        sizeBytes: 0,
        modifiedUnixMillis: nil,
        mimeType: nil,
        canRead: true,
        canWrite: false
    )
}
