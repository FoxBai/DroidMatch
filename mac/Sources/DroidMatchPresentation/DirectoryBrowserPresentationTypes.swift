import DroidMatchCore
import Foundation

/**
 Stable, privacy-bounded values published by the native directory browser.

 These declarations carry presentation data only. They own no client, task,
 pagination token, mutation state, or media cache; those remain in the
 MainActor-isolated `DirectoryBrowserModel`.

 中文：本文件只定义目录浏览器稳定、隐私有界的展示值；client、Task、分页、
 mutation 与媒体缓存仍由 MainActor 隔离的模型唯一持有。
 */
public enum DirectoryBrowserPhase: String, Sendable, Equatable {
    case idle
    case loading
    case loaded
    case refreshing
    case loadingMore
    case failed
}

public enum DirectoryBrowserFailure: String, Sendable, Equatable {
    case invalidRequest
    case permissionRequired
    case notFound
    case unsupported
    case unavailable
    case invalidResponse
}

public enum DirectoryMutationPresentationFailure: String, Sendable, Equatable {
    case invalidName
    case permissionRequired
    case alreadyExists
    case notFound
    case unsupported
    case unavailable
    case partialFailure
}

/// Privacy-bounded row state for a device directory entry.
///
/// Device file names are intentionally displayable product data. This type does
/// not implement `CustomStringConvertible`, and the browser model never logs or
/// copies names into failure state.
public struct DirectoryBrowserItem: Identifiable, Sendable, Equatable {
    private static let disallowedDisplayFormatting = CharacterSet(charactersIn:
        "\u{061C}\u{200B}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2060}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}"
    )
    public var id: String { path }

    public let path: String
    public let name: String?
    public let kind: DirectoryEntryKind
    public let sizeBytes: Int64?
    public let modifiedUnixMillis: Int64?
    public let mimeType: String?
    public let canRead: Bool
    public let canWrite: Bool

    /// A bounded UI-only rendering that cannot visually reorder adjacent text.
    /// The raw name and canonical path remain unchanged for explicit operations.
    public var safeDisplayName: String? {
        guard let name else { return nil }
        let scalars = name.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !Self.disallowedDisplayFormatting.contains($0)
        }
        let value = String(String.UnicodeScalarView(scalars))
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return String(value.prefix(240))
    }

    init(_ entry: DirectoryListingEntry) {
        path = entry.path
        name = entry.name
        kind = entry.kind
        sizeBytes = entry.sizeBytes
        modifiedUnixMillis = entry.modifiedUnixMillis
        mimeType = entry.mimeType
        canRead = entry.canRead
        canWrite = entry.canWrite
    }
}
