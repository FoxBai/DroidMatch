import DroidMatchCore
import Foundation

/**
 Pure policy for directory-browser presentation decisions.

 The policy validates only already-canonical product values and maps typed Core
 failures to bounded UI categories. It owns no task, client, generation, page
 token, cache, or published state.

 中文：该纯策略仅校验既有 canonical 产品值并把 Core 错误映射为有限 UI 分类；
 它不持有 Task、client、generation、分页 token、缓存或 Published 状态。
 */
enum DirectoryBrowserPolicy {
    static func supportsThumbnail(_ item: DirectoryBrowserItem) -> Bool {
        let isMediaFile = item.kind == .file
            && (item.path.hasPrefix("dm://media-images/media/")
                || item.path.hasPrefix("dm://media-videos/media/"))
        let isImageAlbum = item.kind == .directory
            && item.path.hasPrefix("dm://media-images/albums/")
            && item.path != "dm://media-images/albums/"
        return isMediaFile || isImageAlbum
    }

    static func supportsPreview(_ item: DirectoryBrowserItem) -> Bool {
        item.kind == .file
            && (item.path.hasPrefix("dm://media-images/media/")
                || item.path.hasPrefix("dm://media-videos/media/"))
    }

    static func createDirectoryPath(
        in query: DirectoryListingQuery,
        name: String
    ) -> String? {
        guard let normalizedName = normalizedMutationName(name) else { return nil }
        return childPath(in: query, name: normalizedName, isDirectory: true)
    }

    static func renameDestination(
        for item: DirectoryBrowserItem,
        to name: String,
        in query: DirectoryListingQuery,
        visibleEntries: [DirectoryBrowserItem]
    ) -> String? {
        guard item.canWrite,
              item.kind == .file || item.kind == .directory,
              visibleEntries.contains(where: { $0.id == item.id }),
              let normalizedName = normalizedMutationName(name) else { return nil }
        let destination = childPath(
            in: query,
            name: normalizedName,
            isDirectory: item.kind == .directory
        )
        return destination == item.path ? nil : destination
    }

    static func canDelete(
        _ item: DirectoryBrowserItem,
        visibleEntries: [DirectoryBrowserItem]
    ) -> Bool {
        item.canWrite
            && (item.kind == .file || item.kind == .directory)
            && visibleEntries.contains(where: { $0.id == item.id })
    }

    static func batchDeletionItems(
        _ items: [DirectoryBrowserItem],
        visibleEntries: [DirectoryBrowserItem]
    ) -> [DirectoryBrowserItem]? {
        let visibleByPath = Dictionary(
            uniqueKeysWithValues: visibleEntries.map { ($0.path, $0) }
        )
        let unique = Dictionary(
            items.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        .values
        .sorted { $0.path < $1.path }
        guard unique.allSatisfy({ item in
            item.canWrite
                && (item.kind == .file || item.kind == .directory)
                && visibleByPath[item.path] == item
        }) else { return nil }
        return unique
    }

    static func normalizedMutationName(_ name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\0") else { return nil }
        return value
    }

    static func presentationMutationFailure(
        _ error: Error?
    ) -> DirectoryMutationPresentationFailure {
        guard let mutationError = error as? DirectoryMutationError else { return .unavailable }
        switch mutationError {
        case .invalidPath, .invalidResponse:
            return .unavailable
        case let .remote(failure):
            switch failure {
            case .permissionRequired: return .permissionRequired
            case .alreadyExists: return .alreadyExists
            case .notFound: return .notFound
            case .invalidArgument: return .invalidName
            case .unsupported: return .unsupported
            case .unavailable: return .unavailable
            }
        }
    }

    static func presentationFailure(_ error: Error) -> DirectoryBrowserFailure {
        guard let error = error as? DirectoryListingError else {
            return .unavailable
        }
        switch error {
        case .invalidPath, .invalidPageSize:
            return .invalidRequest
        case .invalidResponse:
            return .invalidResponse
        case let .remote(failure):
            switch failure {
            case .permissionRequired, .unauthorized:
                return .permissionRequired
            case .notFound:
                return .notFound
            case .invalidArgument:
                return .invalidRequest
            case .unsupportedCapability:
                return .unsupported
            case .cancelled, .timeout, .transportLost, .other:
                return .unavailable
            }
        }
    }

    private static func childPath(
        in query: DirectoryListingQuery,
        name: String,
        isDirectory: Bool
    ) -> String {
        let separator = query.path.hasSuffix("/") ? "" : "/"
        let kindSuffix = isDirectory ? "/" : ""
        return query.path + separator + name + kindSuffix
    }
}
