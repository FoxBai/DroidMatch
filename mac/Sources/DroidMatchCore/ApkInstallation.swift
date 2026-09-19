import Foundation

public enum ApkInstallationState: Int, Sendable, CaseIterable {
    case waitingForUpload = 1, uploading, waitingForAndroidApproval, submitting
    case waitingForSystemConfirmation, waitingForSystemResult, succeeded, failed, cancelled
    case outcomeUnknown, cleanupRequired

    public var canCancel: Bool {
        switch self {
        case .waitingForUpload, .uploading, .waitingForAndroidApproval, .cleanupRequired: return true
        default: return false
        }
    }
}

public struct ApkInstallationOperation: Identifiable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let sizeBytes: Int64
    public let uploadedBytes: Int64
    public let state: ApkInstallationState
    public let failure: ApkInstallationError?

    public init(id: String, displayName: String, sizeBytes: Int64, uploadedBytes: Int64,
                state: ApkInstallationState, failure: ApkInstallationError? = nil) {
        self.id = id; self.displayName = displayName; self.sizeBytes = sizeBytes
        self.uploadedBytes = uploadedBytes; self.state = state; self.failure = failure
    }
}

public struct ApkInstallationSnapshot: Sendable, Equatable {
    public let operations: [ApkInstallationOperation]
    public let incomingRequestsEnabled: Bool
    public let systemSourceTrusted: Bool
    public let canStartInstall: Bool

    public init(operations: [ApkInstallationOperation], incomingRequestsEnabled: Bool,
                systemSourceTrusted: Bool, canStartInstall: Bool) {
        self.operations = operations; self.incomingRequestsEnabled = incomingRequestsEnabled
        self.systemSourceTrusted = systemSourceTrusted; self.canStartInstall = canStartInstall
    }
}

public enum ApkInstallationError: Error, Sendable, Equatable {
    case unsupported, permissionRequired, needsAndroidAttention, invalidFile, sourceChanged
    case invalidResponse, connectionUnavailable, unavailable, notFound, cancelled, integrityFailure
}

public struct ApkInstallUploadProgress: Sendable, Equatable {
    public enum Stage: Sendable { case checkingFile, sending }
    public let stage: Stage
    public let completedBytes: Int64
    public let totalBytes: Int64
    public init(stage: Stage, completedBytes: Int64, totalBytes: Int64) {
        self.stage = stage; self.completedBytes = completedBytes; self.totalBytes = totalBytes
    }
}

public protocol ApkInstallationClient: Sendable {
    func installationSnapshot() async throws -> ApkInstallationSnapshot
    func uploadApk(sourceURL: URL, operationID: String,
                   progress: @escaping @Sendable (ApkInstallUploadProgress) async -> Void) async throws
        -> ApkInstallationOperation
    func cancelInstallation(id: String) async throws -> ApkInstallationOperation
}

public struct UnsupportedApkInstallationClient: ApkInstallationClient {
    public init() {}
    public func installationSnapshot() async throws -> ApkInstallationSnapshot { throw ApkInstallationError.unsupported }
    public func uploadApk(sourceURL: URL, operationID: String,
                          progress: @escaping @Sendable (ApkInstallUploadProgress) async -> Void) async throws
        -> ApkInstallationOperation { throw ApkInstallationError.unsupported }
    public func cancelInstallation(id: String) async throws -> ApkInstallationOperation { throw ApkInstallationError.unsupported }
}

public enum ApkInstallationPolicy {
    public static let maximumBytes: Int64 = 1_073_741_824
    public static func acceptedFilename(_ name: String) -> String? {
        let normalized = name.precomposedStringWithCanonicalMapping
        guard normalized.unicodeScalars.count <= 160, normalized.lowercased().hasSuffix(".apk"),
              normalized.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .format, .surrogate, .lineSeparator, .paragraphSeparator: return false
                  default: return scalar != "/" && scalar != "\\"
                  }
              }) else { return nil }
        return normalized
    }
    static func validID(_ id: String) -> Bool {
        id.count == 36 && UUID(uuidString: id)?.uuidString.lowercased() == id
    }
    static func destination(_ id: String) -> String { "dm://apk-install/\(id)/base.apk" }
}

enum ApkInstallationCodec {
    static let maximumPayloadBytes = 8192

    static func response(_ payload: Data) throws -> Droidmatch_V1_ListApkInstallsResponse {
        guard payload.count <= maximumPayloadBytes else { throw ApkInstallationError.invalidResponse }
        let wire = try Droidmatch_V1_ListApkInstallsResponse(serializedBytes: payload)
        if wire.hasError {
            guard wire.operations.isEmpty, !wire.incomingRequestsEnabled, !wire.systemSourceTrusted,
                  !wire.canStartInstall, wire.error.code != .unspecified, !isUnknown(wire.error.code) else {
                throw ApkInstallationError.invalidResponse
            }
        } else { _ = try snapshot(wire) }
        return wire
    }

    static func operation(_ wire: Droidmatch_V1_ApkInstallOperation) throws -> ApkInstallationOperation {
        guard ApkInstallationPolicy.validID(wire.operationID),
              ApkInstallationPolicy.acceptedFilename(wire.displayName) == wire.displayName,
              (1...UInt64(ApkInstallationPolicy.maximumBytes)).contains(wire.sizeBytes),
              (0...wire.sizeBytes).contains(wire.uploadedBytes),
              let state = ApkInstallationState(rawValue: wire.state.rawValue) else {
            throw ApkInstallationError.invalidResponse
        }
        switch state {
        case .waitingForUpload:
            guard wire.uploadedBytes == 0 else { throw ApkInstallationError.invalidResponse }
        case .waitingForAndroidApproval, .submitting, .waitingForSystemConfirmation,
             .waitingForSystemResult, .succeeded, .outcomeUnknown:
            guard wire.uploadedBytes == wire.sizeBytes else { throw ApkInstallationError.invalidResponse }
        default: break
        }
        let hasFailure = [.failed, .cancelled, .outcomeUnknown, .cleanupRequired].contains(state)
        guard hasFailure == (wire.failureCode != .unspecified),
              state != .cancelled || wire.failureCode == .cancelled,
              !isUnknown(wire.failureCode) else { throw ApkInstallationError.invalidResponse }
        return .init(id: wire.operationID, displayName: wire.displayName, sizeBytes: Int64(wire.sizeBytes),
                     uploadedBytes: Int64(wire.uploadedBytes), state: state,
                     failure: hasFailure ? failure(wire.failureCode) : nil)
    }

    static func snapshot(_ wire: Droidmatch_V1_ListApkInstallsResponse) throws -> ApkInstallationSnapshot {
        if wire.hasError { throw failure(wire.error.code) }
        guard wire.operations.count <= 8 else { throw ApkInstallationError.invalidResponse }
        let operations = try wire.operations.map(operation)
        guard Set(operations.map(\.id)).count == operations.count,
              !wire.canStartInstall || (wire.incomingRequestsEnabled && wire.systemSourceTrusted),
              !wire.canStartInstall || operations.allSatisfy({
                  [.succeeded, .failed, .cancelled, .outcomeUnknown].contains($0.state)
              }) else { throw ApkInstallationError.invalidResponse }
        return .init(operations: operations, incomingRequestsEnabled: wire.incomingRequestsEnabled,
                     systemSourceTrusted: wire.systemSourceTrusted, canStartInstall: wire.canStartInstall)
    }

    static func failure(_ code: Droidmatch_V1_ErrorCode) -> ApkInstallationError {
        switch code {
        case .unsupportedCapability: return .unsupported
        case .unauthorized, .permissionRequired: return .permissionRequired
        case .alreadyExists: return .needsAndroidAttention
        case .invalidArgument: return .invalidFile
        case .notFound: return .notFound
        case .cancelled: return .cancelled
        case .checksumMismatch: return .integrityFailure
        case .transportLost, .timeout: return .connectionUnavailable
        default: return .unavailable
        }
    }
    private static func isUnknown(_ code: Droidmatch_V1_ErrorCode) -> Bool {
        if case .UNRECOGNIZED = code { return true }; return false
    }
}
