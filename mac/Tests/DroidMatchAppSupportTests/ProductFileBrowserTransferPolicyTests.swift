import DroidMatchCore
import Foundation
import Testing
@testable import DroidMatchAppSupport
@testable import DroidMatchPresentation

@Test
func fileBrowserTransferPolicyAcceptsOnlyTheExactCurrentSnapshot() {
    let query = DirectoryListingQuery(path: "dm://app-sandbox/")
    let file = browserItem(path: "dm://app-sandbox/file.bin", name: "file.bin")
    let current = browserSnapshot(query: query, entries: [file])

    #expect(ProductFileBrowserTransferPolicy.isCurrentAuthorizedSnapshot(
        [file], query: query, current: current
    ))
    #expect(!ProductFileBrowserTransferPolicy.isCurrentAuthorizedSnapshot(
        [file],
        query: DirectoryListingQuery(path: query.path, searchQuery: "old"),
        current: current
    ))
    #expect(!ProductFileBrowserTransferPolicy.isCurrentAuthorizedSnapshot(
        [browserItem(path: file.path, name: "changed.bin")],
        query: query,
        current: current
    ))
}

@Test
func fileBrowserTransferPolicyFailsClosedForUnavailableOrDuplicateCurrentState() {
    let query = DirectoryListingQuery(path: "dm://app-sandbox/")
    let file = browserItem(path: "dm://app-sandbox/file.bin", name: "file.bin")

    for current in [
        browserSnapshot(query: query, entries: [file], phase: .refreshing),
        browserSnapshot(query: query, entries: [file], failure: .permissionRequired),
        browserSnapshot(query: query, entries: [file], canSubmit: false),
        browserSnapshot(query: query, entries: [file, file]),
    ] {
        #expect(!ProductFileBrowserTransferPolicy.isCurrentAuthorizedSnapshot(
            [file], query: query, current: current
        ))
    }
}

@Test
func fileBrowserTransferPolicySeparatesRootAndListedUploadTargets() {
    let query = DirectoryListingQuery(path: "dm://app-sandbox/")
    let root = browserItem(
        path: query.path,
        name: "App Sandbox",
        kind: .virtual,
        canRead: true,
        canWrite: true
    )
    let child = browserItem(
        path: "dm://app-sandbox/folder/",
        name: "folder",
        kind: .directory,
        canRead: true,
        canWrite: true
    )
    let current = browserSnapshot(
        query: query,
        entries: [child],
        currentDirectory: nil,
        rootDirectory: root
    )

    #expect(ProductFileBrowserTransferPolicy.isCurrentWritableUploadTarget(
        root,
        query: query,
        current: current,
        allowsUpload: true,
        requiresListingMembership: false
    ))
    #expect(ProductFileBrowserTransferPolicy.isCurrentWritableUploadTarget(
        child,
        query: query,
        current: current,
        allowsUpload: true,
        requiresListingMembership: true
    ))
    #expect(!ProductFileBrowserTransferPolicy.isCurrentWritableUploadTarget(
        child,
        query: query,
        current: current,
        allowsUpload: true,
        requiresListingMembership: false
    ))
}

@Test
func downloadSelectionPolicySanitizesLeavesAndPreservesOrder() throws {
    let directory = URL(fileURLWithPath: "/private/tmp/downloads", isDirectory: true)
    let first = browserItem(
        path: "dm://app-sandbox/first",
        name: "folder/first\u{202E}.bin"
    )
    let second = browserItem(path: "dm://app-sandbox/second", name: nil)
    let requests = try #require(ProductFileBrowserTransferPolicy.downloadRequests(
        for: [first, second],
        in: directory,
        fallbackName: "Download",
        destinationExists: { _ in false }
    ))

    #expect(requests.map(\.sourcePath) == [first.path, second.path])
    #expect(requests.map { $0.destinationURL.lastPathComponent } == [
        "first.bin",
        "Download",
    ])
}

@Test
func downloadSelectionPolicyRejectsDuplicateExistingAndNonFileTargets() {
    let directory = URL(fileURLWithPath: "/private/tmp/downloads", isDirectory: true)
    let upper = browserItem(path: "dm://app-sandbox/a", name: "Ｐhoto.JPG")
    let lower = browserItem(path: "dm://app-sandbox/b", name: "photo.jpg")

    #expect(ProductFileBrowserTransferPolicy.downloadRequests(
        for: [upper, lower],
        in: directory,
        fallbackName: "Download",
        destinationExists: { _ in false }
    ) == nil)
    #expect(ProductFileBrowserTransferPolicy.downloadRequests(
        for: [lower],
        in: directory,
        fallbackName: "Download",
        destinationExists: { $0.lastPathComponent == "photo.jpg" }
    ) == nil)
    #expect(ProductFileBrowserTransferPolicy.downloadRequests(
        for: [lower],
        in: URL(string: "https://example.invalid/downloads/")!,
        fallbackName: "Download",
        destinationExists: { _ in false }
    ) == nil)
}

private func browserSnapshot(
    query: DirectoryListingQuery,
    entries: [DirectoryBrowserItem],
    phase: DirectoryBrowserPhase = .loaded,
    failure: DirectoryBrowserFailure? = nil,
    currentDirectory: DirectoryBrowserItem? = nil,
    rootDirectory: DirectoryBrowserItem? = nil,
    canSubmit: Bool = true
) -> ProductFileBrowserTransferSnapshot {
    ProductFileBrowserTransferSnapshot(
        query: query,
        entries: entries,
        phase: phase,
        failure: failure,
        currentDirectory: currentDirectory,
        rootDirectory: rootDirectory,
        canPresentTransferSubmission: canSubmit
    )
}

private func browserItem(
    path: String,
    name: String?,
    kind: DirectoryEntryKind = .file,
    canRead: Bool = true,
    canWrite: Bool = false
) -> DirectoryBrowserItem {
    DirectoryBrowserItem(DirectoryListingEntry(
        path: path,
        name: name,
        kind: kind,
        sizeBytes: nil,
        modifiedUnixMillis: nil,
        mimeType: nil,
        canRead: canRead,
        canWrite: canWrite
    ))
}
