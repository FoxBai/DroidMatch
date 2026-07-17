import DroidMatchCore
import Foundation

/**
 Stable, privacy-bounded values published by the native directory browser.

 These declarations carry presentation data only. They own no client, task,
 pagination token, mutation state, or media cache. Published state plus listing
 and derivative work remain in `DirectoryBrowserModel`; the separate MainActor
 runner owns only the active remote-mutation task and operation identity.

 中文：本文件只定义目录浏览器稳定、隐私有界的展示值；Published 状态、listing
 与派生媒体工作仍由模型持有，独立 MainActor runner 只持有活跃 mutation Task
 与操作身份。
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

public enum DirectoryMutationOperation: String, Sendable, Equatable {
    case createDirectory
    case renameItem
    case deleteItem
    case deleteItems

    public func guidance(
        for failure: DirectoryMutationPresentationFailure?
    ) -> DirectoryMutationGuidance {
        switch failure {
        case .invalidName:
            switch self {
            case .createDirectory, .renameItem: return .invalidName
            case .deleteItem, .deleteItems: return .staleItem
            }
        case .permissionRequired:
            return .permissionRequired
        case .alreadyExists:
            switch self {
            case .createDirectory, .renameItem: return .alreadyExists
            case .deleteItem: return .deleteUnavailable
            case .deleteItems: return .batchDeleteUnavailable
            }
        case .notFound:
            return self == .createDirectory ? .locationUnavailable : .itemUnavailable
        case .unsupported:
            switch self {
            case .createDirectory: return .createUnsupported
            case .renameItem: return .renameUnsupported
            case .deleteItem, .deleteItems: return .deleteUnsupported
            }
        case .partialFailure:
            switch self {
            case .createDirectory: return .createUnavailable
            case .renameItem: return .renameUnavailable
            case .deleteItem: return .deleteUnavailable
            case .deleteItems: return .partialDeletion
            }
        case .unavailable, .none:
            switch self {
            case .createDirectory: return .createUnavailable
            case .renameItem: return .renameUnavailable
            case .deleteItem: return .deleteUnavailable
            case .deleteItems: return .batchDeleteUnavailable
            }
        }
    }
}

public enum DirectoryMutationGuidance: String, Sendable, Equatable {
    case invalidName
    case staleItem
    case permissionRequired
    case alreadyExists
    case locationUnavailable
    case itemUnavailable
    case createUnsupported
    case renameUnsupported
    case deleteUnsupported
    case createUnavailable
    case renameUnavailable
    case deleteUnavailable
    case batchDeleteUnavailable
    case partialDeletion
}

/// Privacy-bounded row state for a device directory entry.
///
/// Device file names are intentionally displayable product data. This type does
/// not implement `CustomStringConvertible`, and the browser model never logs or
/// copies names into failure state.
public struct DirectoryBrowserItem: Identifiable, Sendable, Equatable {
    public var id: String { path }

    public let path: String
    public let name: String?
    public let kind: DirectoryEntryKind
    public let sizeBytes: Int64?
    public let modifiedUnixMillis: Int64?
    public let mimeType: String?
    public let canRead: Bool
    public let canWrite: Bool

    /// Listing a container consumes read authorization; write authorization is
    /// deliberately independent so an unreadable media root can still receive
    /// a product upload without issuing a directory-list request.
    ///
    /// 中文：进入容器必须具备读取授权；写入授权保持独立，因此不可读的媒体根目录
    /// 仍可作为产品上传目标，且不会先发起目录列表请求。
    public var canBrowse: Bool {
        canRead && (kind == .directory || kind == .virtual)
    }

    public var canAcceptUpload: Bool {
        canWrite && (kind == .directory || kind == .virtual)
    }

    /// A bounded UI-only rendering that cannot visually reorder adjacent text.
    /// The raw name and canonical path remain unchanged for explicit operations.
    public var safeDisplayName: String? {
        ProductDisplayText.value(name, maximumScalars: 240)
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
