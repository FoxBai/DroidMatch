import Foundation

public enum DirectorySortField: String, Sendable, Equatable {
    case providerDefault
    case name
    case size
    case modifiedTime
    case kind
}

public struct DirectoryListingQuery: Sendable, Equatable {
    public let path: String
    public let pageSize: UInt32
    public let sortField: DirectorySortField
    public let descending: Bool
    public let searchQuery: String

    public init(
        path: String,
        pageSize: UInt32 = 200,
        sortField: DirectorySortField = .providerDefault,
        descending: Bool = false,
        searchQuery: String = ""
    ) {
        self.path = path
        self.pageSize = pageSize
        self.sortField = sortField
        self.descending = descending
        self.searchQuery = searchQuery
    }
}

public enum DirectoryEntryKind: String, Sendable, Equatable {
    case file
    case directory
    case symlink
    case virtual
}

/// Product-facing directory metadata with no protobuf dependency.
public struct DirectoryListingEntry: Identifiable, Sendable, Equatable {
    public var id: String { path }

    public let path: String
    public let name: String?
    public let kind: DirectoryEntryKind
    /// Nil means the provider did not expose a meaningful size.
    public let sizeBytes: Int64?
    /// Nil means the provider did not expose a meaningful timestamp.
    public let modifiedUnixMillis: Int64?
    public let mimeType: String?
    public let canRead: Bool
    public let canWrite: Bool

    public init(
        path: String,
        name: String?,
        kind: DirectoryEntryKind,
        sizeBytes: Int64?,
        modifiedUnixMillis: Int64?,
        mimeType: String?,
        canRead: Bool,
        canWrite: Bool
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modifiedUnixMillis = modifiedUnixMillis
        self.mimeType = mimeType
        self.canRead = canRead
        self.canWrite = canWrite
    }
}

public struct DirectoryListingPage: Sendable, Equatable {
    public let entries: [DirectoryListingEntry]
    /// Opaque provider-owned value. Callers must return it unchanged.
    public let nextPageToken: String?

    public init(entries: [DirectoryListingEntry], nextPageToken: String?) {
        self.entries = entries
        self.nextPageToken = nextPageToken
    }
}

public enum DirectoryListingRemoteFailure: String, Sendable, Equatable {
    case permissionRequired
    case notFound
    case invalidArgument
    case unauthorized
    case unsupportedCapability
    case cancelled
    case timeout
    case transportLost
    case other
}

public enum DirectoryListingResponseViolation: String, Sendable, Equatable {
    case invalidEntryPath
    case invalidEntryKind
    case duplicateEntryPath
    case repeatedPageToken
    case crossPageDuplicateEntryPath
    case paginationTokenCycle
}

/// Pure traversal state for consumers that intentionally exhaust every page.
/// Tokens remain provider-owned: this type stores them only for cycle detection
/// and never parses, logs, or persists their contents.
public struct DirectoryListingTraversal: Sendable {
    public private(set) var entryCount = 0
    public private(set) var pageCounts: [Int] = []

    private var seenEntryPaths = Set<String>()
    private var seenPageTokens = Set<String>()

    public init() {}

    /// Records one validated page and returns its opaque next token unchanged.
    public mutating func accept(
        _ page: DirectoryListingPage
    ) throws -> String? {
        for entry in page.entries {
            guard seenEntryPaths.insert(entry.path).inserted else {
                throw DirectoryListingError.invalidResponse(
                    .crossPageDuplicateEntryPath
                )
            }
        }
        if let token = page.nextPageToken,
           !seenPageTokens.insert(token).inserted {
            throw DirectoryListingError.invalidResponse(.paginationTokenCycle)
        }
        entryCount += page.entries.count
        pageCounts.append(page.entries.count)
        return page.nextPageToken
    }
}

public enum DirectoryListingError: Error, CustomStringConvertible, Sendable, Equatable {
    case invalidPath
    case invalidPageSize
    case remote(DirectoryListingRemoteFailure)
    case invalidResponse(DirectoryListingResponseViolation)

    public var description: String {
        switch self {
        case .invalidPath:
            return "directory listing path is invalid"
        case .invalidPageSize:
            return "directory listing page size must be between 1 and 1000"
        case let .remote(failure):
            return "directory listing failed remotely: \(failure.rawValue)"
        case let .invalidResponse(violation):
            return "directory listing response is invalid: \(violation.rawValue)"
        }
    }
}

public protocol DirectoryListingClient: Sendable {
    func listDirectoryPage(
        query: DirectoryListingQuery,
        pageToken: String?
    ) async throws -> DirectoryListingPage
}

enum DirectoryListingCodec {
    static let maximumPageSize: UInt32 = 1_000

    static func request(
        query: DirectoryListingQuery,
        pageToken: String?
    ) throws -> Droidmatch_V1_ListDirRequest {
        guard query.path.hasPrefix("dm://"), query.path.count > "dm://".count else {
            throw DirectoryListingError.invalidPath
        }
        guard query.pageSize > 0, query.pageSize <= maximumPageSize else {
            throw DirectoryListingError.invalidPageSize
        }
        guard query.searchQuery.count <= 256 else {
            throw DirectoryListingError.invalidPath
        }

        var request = Droidmatch_V1_ListDirRequest()
        request.path = query.path
        request.pageToken = pageToken ?? ""
        request.pageSize = query.pageSize
        request.sortField = protoSortField(query.sortField)
        request.descending = query.descending
        request.searchQuery = query.searchQuery
        return request
    }

    static func page(
        response: Droidmatch_V1_ListDirResponse,
        requestedPageToken: String?
    ) throws -> DirectoryListingPage {
        if response.hasError {
            throw DirectoryListingError.remote(remoteFailure(response.error.code))
        }

        var seenPaths = Set<String>()
        let entries = try response.entries.map { value in
            guard value.path.hasPrefix("dm://"), value.path.count > "dm://".count else {
                throw DirectoryListingError.invalidResponse(.invalidEntryPath)
            }
            guard seenPaths.insert(value.path).inserted else {
                throw DirectoryListingError.invalidResponse(.duplicateEntryPath)
            }
            let kind = try entryKind(value.kind)
            return DirectoryListingEntry(
                path: value.path,
                name: value.name.isEmpty ? nil : value.name,
                kind: kind,
                sizeBytes: kind == .file && value.sizeBytes >= 0
                    ? value.sizeBytes
                    : nil,
                modifiedUnixMillis: value.modifiedUnixMillis > 0
                    ? value.modifiedUnixMillis
                    : nil,
                mimeType: value.mimeType.isEmpty ? nil : value.mimeType,
                canRead: value.canRead,
                canWrite: value.canWrite
            )
        }

        let nextPageToken = response.nextPageToken.isEmpty
            ? nil
            : response.nextPageToken
        if let nextPageToken,
           nextPageToken == requestedPageToken {
            throw DirectoryListingError.invalidResponse(.repeatedPageToken)
        }
        return DirectoryListingPage(
            entries: entries,
            nextPageToken: nextPageToken
        )
    }

    private static func protoSortField(
        _ value: DirectorySortField
    ) -> Droidmatch_V1_SortField {
        switch value {
        case .providerDefault: return .unspecified
        case .name: return .name
        case .size: return .size
        case .modifiedTime: return .modifiedTime
        case .kind: return .kind
        }
    }

    private static func entryKind(
        _ value: Droidmatch_V1_FileKind
    ) throws -> DirectoryEntryKind {
        switch value {
        case .file: return .file
        case .directory: return .directory
        case .symlink: return .symlink
        case .virtual: return .virtual
        case .unspecified, .UNRECOGNIZED:
            throw DirectoryListingError.invalidResponse(.invalidEntryKind)
        }
    }

    private static func remoteFailure(
        _ code: Droidmatch_V1_ErrorCode
    ) -> DirectoryListingRemoteFailure {
        switch code {
        case .permissionRequired: return .permissionRequired
        case .notFound: return .notFound
        case .invalidArgument: return .invalidArgument
        case .unauthorized: return .unauthorized
        case .unsupportedCapability, .unsupportedVersion:
            return .unsupportedCapability
        case .cancelled: return .cancelled
        case .timeout: return .timeout
        case .transportLost: return .transportLost
        case .unspecified, .alreadyExists, .checksumMismatch, .storageReadOnly,
             .internal, .protocolError, .UNRECOGNIZED:
            return .other
        }
    }
}

extension AsyncRpcControlClient: DirectoryListingClient {
    public func listDirectoryPage(
        query: DirectoryListingQuery,
        pageToken: String?
    ) async throws -> DirectoryListingPage {
        let request = try DirectoryListingCodec.request(
            query: query,
            pageToken: pageToken
        )
        let response = try await listDir(request: request)
        return try DirectoryListingCodec.page(
            response: response,
            requestedPageToken: pageToken
        )
    }
}
