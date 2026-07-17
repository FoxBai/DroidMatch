@testable import DroidMatchCore
@testable import DroidMatchPresentation
import Foundation
import Testing

@Test
func directoryBrowserPolicyNormalizesOnlySafeDirectChildNames() {
    #expect(DirectoryBrowserPolicy.normalizedMutationName("  Reports  ") == "Reports")
    #expect(DirectoryBrowserPolicy.normalizedMutationName("") == nil)
    #expect(DirectoryBrowserPolicy.normalizedMutationName("   \n") == nil)
    #expect(DirectoryBrowserPolicy.normalizedMutationName(".") == nil)
    #expect(DirectoryBrowserPolicy.normalizedMutationName("..") == nil)
    #expect(DirectoryBrowserPolicy.normalizedMutationName("nested/name") == nil)
    #expect(DirectoryBrowserPolicy.normalizedMutationName("nul\0name") == nil)
}

@Test
func directoryBrowserPolicyBuildsOnlyVisibleWritableMutationTargets() {
    let query = DirectoryListingQuery(path: "dm://app-sandbox")
    let file = browserItem(
        path: "dm://app-sandbox/old.bin",
        name: "old.bin",
        kind: .file,
        canWrite: true
    )
    let directory = browserItem(
        path: "dm://app-sandbox/Archive/",
        name: "Archive",
        kind: .directory,
        canWrite: true
    )

    #expect(DirectoryBrowserPolicy.createDirectoryPath(
        in: query,
        name: " Reports "
    ) == "dm://app-sandbox/Reports/")
    #expect(DirectoryBrowserPolicy.renameDestination(
        for: file,
        to: " next.bin ",
        in: query,
        visibleEntries: [file, directory]
    ) == "dm://app-sandbox/next.bin")
    #expect(DirectoryBrowserPolicy.renameDestination(
        for: directory,
        to: "Photos",
        in: query,
        visibleEntries: [file, directory]
    ) == "dm://app-sandbox/Photos/")
    #expect(DirectoryBrowserPolicy.renameDestination(
        for: file,
        to: "old.bin",
        in: query,
        visibleEntries: [file]
    ) == nil)
    #expect(DirectoryBrowserPolicy.renameDestination(
        for: file,
        to: "missing.bin",
        in: query,
        visibleEntries: []
    ) == nil)
    let readOnly = browserItem(
        path: file.path,
        name: file.name,
        kind: .file,
        canWrite: false
    )
    #expect(DirectoryBrowserPolicy.renameDestination(
        for: readOnly,
        to: "blocked.bin",
        in: query,
        visibleEntries: [readOnly]
    ) == nil)
}

@Test
func directoryBrowserPolicyStabilizesBatchDeletionAndRejectsStaleMetadata() throws {
    let first = browserItem(
        path: "dm://app-sandbox/a.bin",
        name: "a.bin",
        kind: .file,
        canWrite: true
    )
    let second = browserItem(
        path: "dm://app-sandbox/b/",
        name: "b",
        kind: .directory,
        canWrite: true
    )
    let stable = try #require(DirectoryBrowserPolicy.batchDeletionItems(
        [second, first, second],
        visibleEntries: [first, second]
    ))
    #expect(stable.map(\.path) == [first.path, second.path])
    #expect(DirectoryBrowserPolicy.canDelete(first, visibleEntries: [first, second]))

    let stale = browserItem(
        path: first.path,
        name: first.name,
        kind: .file,
        canWrite: false
    )
    #expect(DirectoryBrowserPolicy.batchDeletionItems(
        [first],
        visibleEntries: [stale, second]
    ) == nil)
    #expect(!DirectoryBrowserPolicy.canDelete(stale, visibleEntries: [stale, second]))
}

@Test
func directoryBrowserPolicySeparatesThumbnailAndPreviewEligibility() {
    let media = browserItem(
        path: "dm://media-images/media/opaque-id",
        name: "photo.jpg",
        kind: .file,
        canWrite: false
    )
    let album = browserItem(
        path: "dm://media-images/albums/0123456789abcdef01234567/",
        name: "Camera",
        kind: .directory,
        canWrite: false
    )
    let albumRoot = browserItem(
        path: "dm://media-images/albums/",
        name: "Albums",
        kind: .directory,
        canWrite: false
    )
    let unreadableMedia = browserItem(
        path: "dm://media-images/media/locked",
        name: "locked.jpg",
        kind: .file,
        canRead: false,
        canWrite: false
    )

    #expect(DirectoryBrowserPolicy.supportsThumbnail(media))
    #expect(DirectoryBrowserPolicy.supportsPreview(media))
    #expect(DirectoryBrowserPolicy.supportsThumbnail(album))
    #expect(!DirectoryBrowserPolicy.supportsPreview(album))
    #expect(!DirectoryBrowserPolicy.supportsThumbnail(albumRoot))
    #expect(!DirectoryBrowserPolicy.supportsThumbnail(unreadableMedia))
    #expect(!DirectoryBrowserPolicy.supportsPreview(unreadableMedia))
}

@Test
func directoryBrowserPolicyMapsCoreErrorsToBoundedPresentationFailures() {
    #expect(DirectoryBrowserPolicy.presentationFailure(
        DirectoryListingError.invalidPath
    ) == .invalidRequest)
    #expect(DirectoryBrowserPolicy.presentationFailure(
        DirectoryListingError.invalidResponse(.repeatedPageToken)
    ) == .invalidResponse)
    #expect(DirectoryBrowserPolicy.presentationFailure(
        DirectoryListingError.remote(.unauthorized)
    ) == .permissionRequired)
    #expect(DirectoryBrowserPolicy.presentationFailure(
        DirectoryListingError.remote(.unsupportedCapability)
    ) == .unsupported)
    #expect(DirectoryBrowserPolicy.presentationFailure(
        CancellationError()
    ) == .unavailable)

    #expect(DirectoryBrowserPolicy.presentationMutationFailure(
        DirectoryMutationError.remote(.alreadyExists)
    ) == .alreadyExists)
    #expect(DirectoryBrowserPolicy.presentationMutationFailure(
        DirectoryMutationError.remote(.invalidArgument)
    ) == .invalidName)
    #expect(DirectoryBrowserPolicy.presentationMutationFailure(nil) == .unavailable)

    let guidanceCases: [(
        DirectoryMutationOperation,
        DirectoryMutationPresentationFailure?,
        DirectoryMutationGuidance
    )] = [
        (.createDirectory, .invalidName, .invalidName),
        (.renameItem, .invalidName, .invalidName),
        (.deleteItem, .invalidName, .staleItem),
        (.deleteItems, .invalidName, .staleItem),
        (.createDirectory, .permissionRequired, .permissionRequired),
        (.renameItem, .permissionRequired, .permissionRequired),
        (.deleteItem, .permissionRequired, .permissionRequired),
        (.deleteItems, .permissionRequired, .permissionRequired),
        (.createDirectory, .alreadyExists, .alreadyExists),
        (.renameItem, .alreadyExists, .alreadyExists),
        (.deleteItem, .alreadyExists, .deleteUnavailable),
        (.deleteItems, .alreadyExists, .batchDeleteUnavailable),
        (.createDirectory, .notFound, .locationUnavailable),
        (.renameItem, .notFound, .itemUnavailable),
        (.deleteItem, .notFound, .itemUnavailable),
        (.deleteItems, .notFound, .itemUnavailable),
        (.createDirectory, .unsupported, .createUnsupported),
        (.renameItem, .unsupported, .renameUnsupported),
        (.deleteItem, .unsupported, .deleteUnsupported),
        (.deleteItems, .unsupported, .deleteUnsupported),
        (.createDirectory, .partialFailure, .createUnavailable),
        (.renameItem, .partialFailure, .renameUnavailable),
        (.deleteItem, .partialFailure, .deleteUnavailable),
        (.deleteItems, .partialFailure, .partialDeletion),
        (.createDirectory, .unavailable, .createUnavailable),
        (.renameItem, .unavailable, .renameUnavailable),
        (.deleteItem, .unavailable, .deleteUnavailable),
        (.deleteItems, .unavailable, .batchDeleteUnavailable),
        (.createDirectory, nil, .createUnavailable),
        (.renameItem, nil, .renameUnavailable),
        (.deleteItem, nil, .deleteUnavailable),
        (.deleteItems, nil, .batchDeleteUnavailable),
    ]
    for (operation, failure, expected) in guidanceCases {
        #expect(operation.guidance(for: failure) == expected)
    }
}

private func browserItem(
    path: String,
    name: String?,
    kind: DirectoryEntryKind,
    canRead: Bool = true,
    canWrite: Bool
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
