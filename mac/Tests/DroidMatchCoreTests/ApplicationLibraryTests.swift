import Foundation
import Testing
@testable import DroidMatchCore

@Test func applicationLibraryCodecBoundsRequestsAndPreservesAuthorizedMetadata() throws {
    let query = ApplicationLibraryQuery(searchQuery: "Notes", sortOrder: .recentlyUpdated, pageSize: 50)
    let request = try ApplicationLibraryCodec.request(query: query, pageToken: "opaque-cursor")
    #expect(request.query == "Notes" && request.pageToken == "opaque-cursor")
    #expect(request.sortField == .updated && request.descending && request.pageSize == 50)
    for invalid in [ApplicationLibraryQuery(pageSize: 101), .init(pageSize: 0),
                    .init(searchQuery: "line\nbreak"), .init(searchQuery: String(repeating: "🙂", count: 129))] {
        #expect(throws: ApplicationLibraryError.invalidQuery) {
            try ApplicationLibraryCodec.request(query: invalid, pageToken: nil)
        }
    }
    var response = applicationResponse()
    let decoded = try ApplicationLibraryCodec.response(response.serializedData(), pageSize: 100,
                                                       requestedToken: nil)
    let page = try ApplicationLibraryCodec.page(decoded)
    #expect(page.entries.first?.packageIdentifier == "example.notes")
    #expect(page.entries.first?.versionCode == 42)
    #expect(page.entries.first?.versionName == "2.1")
    #expect(page.entries.first?.isSystemApplication == true)
    #expect(page.totalCount == 1 && page.nextPageToken == nil)
    response.entries = []
    response.totalCount = 0
    response.error.code = .permissionRequired
    // Legitimate remote failures remain drainable replies; domain mapping occurs
    // after framing validation rather than closing the control connection.
    let denied = try ApplicationLibraryCodec.response(response.serializedData(), pageSize: 100,
                                                      requestedToken: nil)
    #expect(throws: ApplicationLibraryError.permissionRequired) { try ApplicationLibraryCodec.page(denied) }
}

@Test func applicationLibraryCodecRejectsPrivatePathsMalformedMetadataAndOversizedReplies() throws {
    let original = applicationResponse()
    var invalid: [Droidmatch_V1_ListApplicationsResponse] = []
    var response = original
    response.entries[0].packageIdentifier = "/private/application.apk"
    invalid.append(response)
    response = original
    response.entries[0].displayName = "Notes\u{202e}"
    invalid.append(response)
    response = original
    response.entries[0].versionCode = UInt64.max
    invalid.append(response)
    response = original
    response.entries.append(response.entries[0])
    response.totalCount = 2
    invalid.append(response)
    response = original
    response.error.code = .permissionRequired
    invalid.append(response)
    response = original
    response.totalCount = 5000
    invalid.append(response)
    response = original
    response.nextPageToken = "reused"
    invalid.append(response)
    for response in invalid {
        #expect(throws: ApplicationLibraryError.invalidResponse) {
            try ApplicationLibraryCodec.response(response.serializedData(), pageSize: 1,
                                                  requestedToken: "reused")
        }
    }
    #expect(throws: ApplicationLibraryError.invalidResponse) {
        try ApplicationLibraryCodec.response(Data(repeating: 0, count: 256 * 1024 + 1),
                                              pageSize: 100, requestedToken: nil)
    }
}

private func applicationResponse() -> Droidmatch_V1_ListApplicationsResponse {
    var entry = Droidmatch_V1_ApplicationEntry()
    entry.packageIdentifier = "example.notes"
    entry.displayName = "Notes"
    entry.versionName = "2.1"
    entry.versionCode = 42
    entry.updatedMillis = 1_700_000_000_000
    entry.systemApplication = true
    var response = Droidmatch_V1_ListApplicationsResponse()
    response.entries = [entry]
    response.totalCount = 1
    return response
}
