import DroidMatchCore
import DroidMatchPresentation
import Foundation

/// Immutable product state used to revalidate a native file-panel completion.
///
/// Native panels may outlive the row, query, or permission state that opened
/// them. AppSupport owns this pure decision so stale UI values cannot enqueue a
/// transfer after navigation, refresh, permission loss, or persistence failure.
package struct ProductFileBrowserTransferSnapshot {
    package let query: DirectoryListingQuery?
    package let entries: [DirectoryBrowserItem]
    package let phase: DirectoryBrowserPhase
    package let failure: DirectoryBrowserFailure?
    package let currentDirectory: DirectoryBrowserItem?
    package let rootDirectory: DirectoryBrowserItem?
    package let canPresentTransferSubmission: Bool

    package init(
        query: DirectoryListingQuery?,
        entries: [DirectoryBrowserItem],
        phase: DirectoryBrowserPhase,
        failure: DirectoryBrowserFailure?,
        currentDirectory: DirectoryBrowserItem?,
        rootDirectory: DirectoryBrowserItem?,
        canPresentTransferSubmission: Bool
    ) {
        self.query = query
        self.entries = entries
        self.phase = phase
        self.failure = failure
        self.currentDirectory = currentDirectory
        self.rootDirectory = rootDirectory
        self.canPresentTransferSubmission = canPresentTransferSubmission
    }
}

package struct ProductDownloadSelectionRequest: Equatable {
    package let sourcePath: String
    package let destinationURL: URL
}

/// Pure admission shared by single and batch file-browser transfers.
///
/// Android and Core remain the authorization and filesystem authorities. This
/// policy is the fail-closed UI boundary before bookmark or scheduler effects.
package enum ProductFileBrowserTransferPolicy {
    package static func isCurrentAuthorizedSnapshot(
        _ entries: [DirectoryBrowserItem],
        query: DirectoryListingQuery,
        current: ProductFileBrowserTransferSnapshot
    ) -> Bool {
        guard !entries.isEmpty,
              current.canPresentTransferSubmission,
              current.query == query,
              current.phase == .loaded,
              current.failure != .permissionRequired else { return false }

        var currentEntries: [String: DirectoryBrowserItem] = [:]
        for entry in current.entries {
            guard currentEntries.updateValue(entry, forKey: entry.path) == nil else {
                return false
            }
        }
        return entries.allSatisfy { currentEntries[$0.path] == $0 }
    }

    package static func isCurrentWritableUploadTarget(
        _ target: DirectoryBrowserItem,
        query: DirectoryListingQuery,
        current: ProductFileBrowserTransferSnapshot,
        allowsUpload: Bool,
        requiresListingMembership: Bool
    ) -> Bool {
        guard allowsUpload,
              current.canPresentTransferSubmission,
              target.canAcceptUpload,
              current.query == query,
              current.phase == .loaded,
              current.failure != .permissionRequired else { return false }
        if requiresListingMembership {
            return isCurrentAuthorizedSnapshot([target], query: query, current: current)
        }
        guard target.path == query.path else { return false }
        return current.currentDirectory == target || current.rootDirectory == target
    }

    package static func downloadRequests(
        for entries: [DirectoryBrowserItem],
        in directoryURL: URL,
        fallbackName: String,
        destinationExists: (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        }
    ) -> [ProductDownloadSelectionRequest]? {
        guard directoryURL.isFileURL, !entries.isEmpty else { return nil }
        var names = Set<String>()
        var requests: [ProductDownloadSelectionRequest] = []
        requests.reserveCapacity(entries.count)

        for entry in entries {
            let name = destinationName(entry.safeDisplayName, fallback: fallbackName)
            let normalized = name.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            let destinationURL = directoryURL.appendingPathComponent(
                name,
                isDirectory: false
            )
            guard names.insert(normalized).inserted,
                  !destinationExists(destinationURL) else { return nil }
            requests.append(ProductDownloadSelectionRequest(
                sourcePath: entry.path,
                destinationURL: destinationURL
            ))
        }
        return requests
    }

    /// Treats device display data as one local leaf, never as a path.
    package static func destinationName(_ name: String?, fallback: String) -> String {
        guard let name, !name.isEmpty else { return fallback }
        let basename = URL(fileURLWithPath: name).lastPathComponent
        let bidirectionalFormatting = CharacterSet(charactersIn:
            "\u{061C}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"
        )
        let filtered = basename.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !bidirectionalFormatting.contains($0)
        }
        let value = String(String.UnicodeScalarView(filtered))
        return value.isEmpty || value == "." || value == ".." ? fallback : value
    }
}
