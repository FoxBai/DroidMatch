import Foundation

public enum ApplicationLibrarySortOrder: String, CaseIterable, Sendable {
    case name
    case recentlyUpdated
}

public struct ApplicationLibraryQuery: Sendable, Equatable {
    public let searchQuery: String
    public let sortOrder: ApplicationLibrarySortOrder
    public let pageSize: Int

    public init(searchQuery: String = "", sortOrder: ApplicationLibrarySortOrder = .name,
                pageSize: Int = 100) {
        self.searchQuery = searchQuery
        self.sortOrder = sortOrder
        self.pageSize = pageSize
    }
}

/// Application information explicitly shared by Android; never a filesystem path.
public struct ApplicationLibraryEntry: Identifiable, Sendable, Equatable {
    public var id: String { packageIdentifier }
    public let packageIdentifier: String
    public let displayName: String
    public let versionName: String
    public let versionCode: UInt64
    public let updatedUnixMillis: Int64?
    public let isSystemApplication: Bool

    public init(packageIdentifier: String, displayName: String, versionName: String,
                versionCode: UInt64, updatedUnixMillis: Int64?, isSystemApplication: Bool) {
        self.packageIdentifier = packageIdentifier
        self.displayName = displayName
        self.versionName = versionName
        self.versionCode = versionCode
        self.updatedUnixMillis = updatedUnixMillis.flatMap {
            (1...253_402_300_799_000).contains($0) ? $0 : nil
        }
        self.isSystemApplication = isSystemApplication
    }
}

public struct ApplicationLibraryPage: Sendable, Equatable {
    public let entries: [ApplicationLibraryEntry]
    public let totalCount: Int
    /// Provider-owned cursor, returned unchanged and never logged or persisted.
    public let nextPageToken: String?

    public init(entries: [ApplicationLibraryEntry], totalCount: Int, nextPageToken: String?) {
        self.entries = entries
        self.totalCount = totalCount
        self.nextPageToken = nextPageToken
    }
}

public enum ApplicationLibraryError: Error, Sendable, Equatable {
    case unsupported
    case permissionRequired
    case refreshRequired
    case invalidQuery
    case invalidResponse
    case connectionUnavailable
    case failed
}

public protocol ApplicationLibraryClient: Sendable {
    func listApplications(query: ApplicationLibraryQuery, pageToken: String?) async throws
        -> ApplicationLibraryPage
}

public extension ApplicationLibraryClient {
    func listApplications(query: ApplicationLibraryQuery, pageToken: String?) async throws
        -> ApplicationLibraryPage {
        throw ApplicationLibraryError.unsupported
    }
}

public struct UnsupportedApplicationLibraryClient: ApplicationLibraryClient {
    public init() {}
}

enum ApplicationLibraryCodec {
    static func request(query: ApplicationLibraryQuery, pageToken: String?) throws
        -> Droidmatch_V1_ListApplicationsRequest {
        guard (1...100).contains(query.pageSize), query.searchQuery.unicodeScalars.count <= 128,
              query.searchQuery.unicodeScalars.allSatisfy(visible),
              (pageToken?.utf8.count ?? 0) <= 92 else {
            throw ApplicationLibraryError.invalidQuery
        }
        var request = Droidmatch_V1_ListApplicationsRequest()
        request.query = query.searchQuery
        request.pageSize = UInt32(query.pageSize)
        request.pageToken = pageToken ?? ""
        request.sortField = query.sortOrder == .name ? .name : .updated
        request.descending = query.sortOrder == .recentlyUpdated
        return request
    }

    /// Runs inside the read-only response validator, including when a cancelled
    /// caller's late reply is being drained. 中文：迟到畸形响应也不能逃过边界校验。
    static func response(_ payload: Data, pageSize: Int, requestedToken: String?) throws
        -> Droidmatch_V1_ListApplicationsResponse {
        guard payload.count <= 256 * 1024 else { throw ApplicationLibraryError.invalidResponse }
        let response = try Droidmatch_V1_ListApplicationsResponse(serializedBytes: payload)
        if response.hasError {
            guard response.entries.isEmpty, response.totalCount == 0,
                  response.nextPageToken.isEmpty, response.error.code != .unspecified else {
                throw ApplicationLibraryError.invalidResponse
            }
            return response
        }
        guard response.entries.count <= pageSize, response.totalCount <= 4096,
              Int(response.totalCount) >= response.entries.count,
              response.nextPageToken.utf8.count <= 92,
              response.nextPageToken.unicodeScalars.allSatisfy({ $0.isASCII && visible($0) }),
              response.nextPageToken.isEmpty || (!response.entries.isEmpty
                && response.entries.count == pageSize && response.nextPageToken != requestedToken) else {
            throw ApplicationLibraryError.invalidResponse
        }
        var seen = Set<String>()
        for entry in response.entries {
            guard validIdentifier(entry.packageIdentifier), seen.insert(entry.packageIdentifier).inserted,
                  !entry.displayName.isEmpty, validDisplay(entry.displayName),
                  validDisplay(entry.versionName), entry.versionCode <= UInt64(Int64.max),
                  entry.updatedMillis <= UInt64(Int64.max) else {
                throw ApplicationLibraryError.invalidResponse
            }
        }
        return response
    }

    static func page(_ response: Droidmatch_V1_ListApplicationsResponse) throws -> ApplicationLibraryPage {
        if response.hasError { throw failure(response.error.code) }
        return ApplicationLibraryPage(entries: response.entries.map { entry in
            ApplicationLibraryEntry(packageIdentifier: entry.packageIdentifier,
                displayName: entry.displayName, versionName: entry.versionName,
                versionCode: entry.versionCode, updatedUnixMillis: Int64(exactly: entry.updatedMillis),
                isSystemApplication: entry.systemApplication)
        }, totalCount: Int(response.totalCount),
           nextPageToken: response.nextPageToken.isEmpty ? nil : response.nextPageToken)
    }

    static func failure(_ code: Droidmatch_V1_ErrorCode) -> ApplicationLibraryError {
        switch code {
        case .permissionRequired: return .permissionRequired
        case .unsupportedCapability: return .unsupported
        case .invalidArgument: return .refreshRequired
        case .unauthorized, .transportLost, .timeout: return .connectionUnavailable
        default: return .failed
        }
    }

    private static func validDisplay(_ value: String) -> Bool {
        value.unicodeScalars.count <= 160 && value.unicodeScalars.allSatisfy(visible)
    }

    private static func visible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .lineSeparator, .paragraphSeparator: return false
        default: return true
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255 else { return false }
        var beginning = true
        for byte in value.utf8 {
            if byte == 46 {
                guard !beginning else { return false }
                beginning = true
            } else {
                let letter = (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
                guard letter || (!beginning && (48...57).contains(byte)) else { return false }
                beginning = false
            }
        }
        return !beginning
    }
}
