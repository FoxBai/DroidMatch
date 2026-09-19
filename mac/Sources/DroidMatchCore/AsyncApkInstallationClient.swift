import Foundation

public protocol ApkInstallControlClient: Sendable {
    func listApkInstalls() async throws -> ApkInstallationSnapshot
    func prepareApkInstall(id: String, name: String, size: Int64, sha256: Data) async throws
        -> ApkInstallationOperation
    func cancelApkInstall(id: String) async throws -> ApkInstallationOperation
}

public extension ApkInstallControlClient {
    func listApkInstalls() async throws -> ApkInstallationSnapshot { throw ApkInstallationError.unsupported }
    func prepareApkInstall(id: String, name: String, size: Int64, sha256: Data) async throws
        -> ApkInstallationOperation { throw ApkInstallationError.unsupported }
    func cancelApkInstall(id: String) async throws -> ApkInstallationOperation { throw ApkInstallationError.unsupported }
}

extension AsyncRpcControlClient: ApkInstallControlClient {
    public func listApkInstalls() async throws -> ApkInstallationSnapshot {
        try requireApkInstallation()
        do {
            let response = try await execute(payload: Droidmatch_V1_ListApkInstallsRequest(),
                requestPayloadType: .listApkInstallsRequest, responsePayloadType: .listApkInstallsResponse,
                cancellationSafety: .drainReadOnlyResponse) { payload in
                    try ApkInstallationCodec.response(payload)
                }
            return try ApkInstallationCodec.snapshot(response)
        } catch let RpcControlClientError.remoteError(error) { throw ApkInstallationCodec.failure(error.code) }
    }

    public func prepareApkInstall(id: String, name: String, size: Int64, sha256: Data) async throws
        -> ApkInstallationOperation {
        try requireApkInstallation()
        guard ApkInstallationPolicy.validID(id), ApkInstallationPolicy.acceptedFilename(name) == name,
              (1...ApkInstallationPolicy.maximumBytes).contains(size), sha256.count == 32 else {
            throw ApkInstallationError.invalidFile
        }
        var request = Droidmatch_V1_PrepareApkInstallRequest()
        request.operationID = id; request.displayName = name; request.sizeBytes = UInt64(size); request.sha256 = sha256
        do {
            return try await execute(payload: request, requestPayloadType: .prepareApkInstallRequest,
                responsePayloadType: .prepareApkInstallResponse) { payload in
                    guard payload.count <= 2048 else { throw ApkInstallationError.invalidResponse }
                    let response = try Droidmatch_V1_PrepareApkInstallResponse(serializedBytes: payload)
                    if response.hasError { throw ApkInstallationCodec.failure(response.error.code) }
                    let operation = try ApkInstallationCodec.operation(response.operation)
                    guard operation.id == id, operation.displayName == name, operation.sizeBytes == size,
                          response.uploadDestination == ApkInstallationPolicy.destination(id) else {
                        throw ApkInstallationError.invalidResponse
                    }
                    return operation
                }
        } catch let RpcControlClientError.remoteError(error) { throw ApkInstallationCodec.failure(error.code) }
    }

    public func cancelApkInstall(id: String) async throws -> ApkInstallationOperation {
        try requireApkInstallation()
        guard ApkInstallationPolicy.validID(id) else { throw ApkInstallationError.invalidFile }
        var request = Droidmatch_V1_CancelApkInstallRequest(); request.operationID = id
        do {
            return try await execute(payload: request, requestPayloadType: .cancelApkInstallRequest,
                responsePayloadType: .cancelApkInstallResponse) { payload in
                    guard payload.count <= 2048 else { throw ApkInstallationError.invalidResponse }
                    let response = try Droidmatch_V1_CancelApkInstallResponse(serializedBytes: payload)
                    if response.hasError { throw ApkInstallationCodec.failure(response.error.code) }
                    let operation = try ApkInstallationCodec.operation(response.operation)
                    guard operation.id == id,
                          [.succeeded, .failed, .cancelled].contains(operation.state) else {
                        throw ApkInstallationError.invalidResponse
                    }
                    return operation
                }
        } catch let RpcControlClientError.remoteError(error) { throw ApkInstallationCodec.failure(error.code) }
    }

    private func requireApkInstallation() throws {
        try requireReady()
        try requireAuthenticatedSession()
        do { try requireCapability(.apkInstall) }
        catch { throw ApkInstallationError.unsupported }
    }
}
