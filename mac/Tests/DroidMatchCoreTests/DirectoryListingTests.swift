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
    root.canRead = true

    var file = Droidmatch_V1_FileEntry()
    file.path = "dm://media-images/media/42"
    file.name = "IMG_0042.jpg"
    file.kind = .file
    file.sizeBytes = 1_024
    file.modifiedUnixMillis = 1_700_000_000_000
    file.mimeType = "image/jpeg"
    file.canRead = true

    var response = Droidmatch_V1_ListDirResponse()
    response.entries = [root, file]
    response.nextPageToken = "opaque-next"

    let page = try DirectoryListingCodec.page(
        response: response,
        requestedPageToken: nil
    )

    #expect(page.entries.map(\.path) == [root.path, file.path])
    #expect(page.entries.map(\.kind) == [.virtual, .file])
    #expect(page.entries.map(\.name) == [nil, "IMG_0042.jpg"])
    #expect(page.entries[0].sizeBytes == nil)
    #expect(page.entries[0].modifiedUnixMillis == nil)
    #expect(page.entries[1].sizeBytes == 1_024)
    #expect(page.entries[1].modifiedUnixMillis == 1_700_000_000_000)
    #expect(page.nextPageToken == "opaque-next")
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
