import Foundation

public enum DirectoryMutationFailure: String, Sendable, Equatable {
    case permissionRequired
    case alreadyExists
    case notFound
    case invalidArgument
    case unsupported
    case unavailable
}

public enum DirectoryMutationError: Error, Sendable, Equatable {
    case invalidPath
    case remote(DirectoryMutationFailure)
    case invalidResponse
}

/// Product boundary for mutations supported by a concrete remote provider.
public protocol DirectoryMutationClient: Sendable {
    func createDirectory(path: String) async throws
    func renamePath(sourcePath: String, destinationPath: String) async throws
    func deletePath(_ path: String, recursive: Bool) async throws
}

public extension DirectoryMutationClient {
    func createDirectory(path: String) async throws {
        throw DirectoryMutationError.remote(.unsupported)
    }

    func renamePath(sourcePath: String, destinationPath: String) async throws {
        throw DirectoryMutationError.remote(.unsupported)
    }

    func deletePath(_ path: String, recursive: Bool) async throws {
        throw DirectoryMutationError.remote(.unsupported)
    }
}

public protocol DirectoryBrowserClient: DirectoryListingClient, DirectoryMutationClient {}

extension AsyncRpcControlClient: DirectoryBrowserClient {
    public func createDirectory(path: String) async throws {
        guard path.hasPrefix("dm://"), path.count > "dm://".count, path.hasSuffix("/") else {
            throw DirectoryMutationError.invalidPath
        }
        try requireReady()
        try requireCapability(.fileWrite)

        var request = Droidmatch_V1_CreateDirectoryRequest()
        request.path = path
        let response: Droidmatch_V1_FileMutationResponse = try await execute(
            payload: request,
            requestPayloadType: .createDirectoryRequest,
            responsePayloadType: .fileMutationResponse
        ) { payload in
            try Droidmatch_V1_FileMutationResponse(serializedBytes: payload)
        }
        if response.hasError {
            throw DirectoryMutationError.remote(Self.mutationFailure(response.error.code))
        }
        guard response.ok else { throw DirectoryMutationError.invalidResponse }
    }

    public func renamePath(sourcePath: String, destinationPath: String) async throws {
        guard sourcePath.hasPrefix("dm://"),
              destinationPath.hasPrefix("dm://"),
              sourcePath != destinationPath else {
            throw DirectoryMutationError.invalidPath
        }
        try requireReady()
        try requireCapability(.fileWrite)
        var request = Droidmatch_V1_RenamePathRequest()
        request.sourcePath = sourcePath
        request.destinationPath = destinationPath
        let response: Droidmatch_V1_FileMutationResponse = try await execute(
            payload: request,
            requestPayloadType: .renamePathRequest,
            responsePayloadType: .fileMutationResponse
        ) { payload in
            try Droidmatch_V1_FileMutationResponse(serializedBytes: payload)
        }
        if response.hasError {
            throw DirectoryMutationError.remote(Self.mutationFailure(response.error.code))
        }
        guard response.ok else { throw DirectoryMutationError.invalidResponse }
    }

    public func deletePath(_ path: String, recursive: Bool) async throws {
        guard path.hasPrefix("dm://"), path.count > "dm://".count else {
            throw DirectoryMutationError.invalidPath
        }
        try requireReady()
        try requireCapability(.fileWrite)
        var request = Droidmatch_V1_DeletePathRequest()
        request.path = path
        request.recursive = recursive
        let response: Droidmatch_V1_FileMutationResponse = try await execute(
            payload: request,
            requestPayloadType: .deletePathRequest,
            responsePayloadType: .fileMutationResponse
        ) { payload in
            try Droidmatch_V1_FileMutationResponse(serializedBytes: payload)
        }
        if response.hasError {
            throw DirectoryMutationError.remote(Self.mutationFailure(response.error.code))
        }
        guard response.ok else { throw DirectoryMutationError.invalidResponse }
    }

    private static func mutationFailure(
        _ code: Droidmatch_V1_ErrorCode
    ) -> DirectoryMutationFailure {
        switch code {
        case .permissionRequired, .unauthorized: return .permissionRequired
        case .alreadyExists: return .alreadyExists
        case .notFound: return .notFound
        case .invalidArgument: return .invalidArgument
        case .unsupportedCapability, .unsupportedVersion: return .unsupported
        case .unspecified, .cancelled, .checksumMismatch, .storageReadOnly,
             .timeout, .transportLost, .internal, .protocolError, .UNRECOGNIZED:
            return .unavailable
        }
    }
}
