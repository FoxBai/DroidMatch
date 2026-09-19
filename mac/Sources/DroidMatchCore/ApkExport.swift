import Foundation

public enum ApkExportError: Error, Sendable, Equatable {
    case unsupported, permissionRequired, sourceChanged, invalidResponse
    case connectionUnavailable, localFileFailed, commitUncertain, busy
}

public struct ApkExportProgress: Sendable, Equatable {
    public enum Stage: Sendable { case preparing, receiving, validating }
    public let stage: Stage
    public let completedBytes: Int64
    public let totalBytes: Int64
    public init(stage: Stage, completedBytes: Int64, totalBytes: Int64) {
        self.stage = stage; self.completedBytes = completedBytes; self.totalBytes = totalBytes
    }
}

public struct ApkExportResult: Sendable, Equatable {
    public let filename: String
    public let componentCount: Int
    public let totalBytes: Int64
    public init(filename: String, componentCount: Int, totalBytes: Int64) {
        self.filename = filename; self.componentCount = componentCount; self.totalBytes = totalBytes
    }
}

public protocol ApkExportClient: Sendable {
    func exportApk(packageIdentifier: String, directoryURL: URL,
                   progress: @escaping @Sendable (ApkExportProgress) async -> Void) async throws -> ApkExportResult
}

public struct UnsupportedApkExportClient: ApkExportClient {
    public init() {}
    public func exportApk(packageIdentifier: String, directoryURL: URL,
                          progress: @escaping @Sendable (ApkExportProgress) async -> Void) async throws -> ApkExportResult {
        throw ApkExportError.unsupported
    }
}

struct ApkExportManifest: Sendable, Equatable {
    struct Component: Sendable, Equatable {
        let index: Int
        let splitName: String
        let sizeBytes: Int64
        var filename: String { index == 0 ? "base.apk" : "split-\(index).apk" }
    }
    let id: String
    let packageIdentifier: String
    let versionCode: UInt64
    let updatedMillis: UInt64
    let components: [Component]
    var totalBytes: Int64 { components.reduce(0) { $0 + $1.sizeBytes } }
    func path(_ component: Component) -> String { "dm://apk-export/\(id)/\(component.index).apk" }
    func etag(_ component: Component) -> String { "\(id):\(component.index)" }
}

enum ApkExportCodec {
    static let maximumComponentBytes: Int64 = 8 * 1024 * 1024 * 1024
    static let maximumTotalBytes: Int64 = 64 * 1024 * 1024 * 1024

    static func manifest(_ data: Data, identifier: String) throws -> ApkExportManifest {
        guard data.count <= 128 * 1024 else { throw ApkExportError.invalidResponse }
        let response = try Droidmatch_V1_PrepareApkExportResponse(serializedBytes: data)
        if response.hasError {
            guard response.exportID.isEmpty, response.packageIdentifier.isEmpty,
                  response.versionCode == 0, response.updatedMillis == 0, response.components.isEmpty,
                  response.error.code != .unspecified else { throw ApkExportError.invalidResponse }
            throw failure(response.error.code)
        }
        guard UUID(uuidString: response.exportID)?.uuidString.lowercased() == response.exportID,
              response.packageIdentifier == identifier, ApplicationLibraryCodec.validIdentifier(identifier),
              response.versionCode <= UInt64(Int64.max), response.updatedMillis <= UInt64(Int64.max),
              (1...256).contains(response.components.count) else { throw ApkExportError.invalidResponse }
        var seen = Set<String>()
        var total: Int64 = 0
        var components: [ApkExportManifest.Component] = []
        for (index, part) in response.components.enumerated() {
            guard part.index == UInt32(index), validSplitName(part.splitName, base: index == 0),
                  seen.insert(part.splitName).inserted, part.sizeBytes > 0,
                  part.sizeBytes <= UInt64(maximumComponentBytes) else { throw ApkExportError.invalidResponse }
            total += Int64(part.sizeBytes)
            guard total <= maximumTotalBytes else { throw ApkExportError.invalidResponse }
            components.append(.init(index: index, splitName: part.splitName, sizeBytes: Int64(part.sizeBytes)))
        }
        return .init(id: response.exportID, packageIdentifier: identifier, versionCode: response.versionCode,
                     updatedMillis: response.updatedMillis, components: components)
    }

    private static func validSplitName(_ value: String, base: Bool) -> Bool {
        if base { return value.isEmpty }
        return !value.isEmpty && value.utf8.count <= 160 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 95 || $0 == 46 || $0 == 45
        }
    }

    static func failure(_ code: Droidmatch_V1_ErrorCode) -> ApkExportError {
        switch code {
        case .permissionRequired: return .permissionRequired
        case .invalidArgument, .notFound: return .sourceChanged
        case .unsupportedCapability: return .unsupported
        default: return .connectionUnavailable
        }
    }
}
