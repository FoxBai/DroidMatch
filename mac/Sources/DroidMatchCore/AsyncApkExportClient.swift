import Foundation

extension AsyncRpcControlClient {
    func prepareApkExport(identifier: String) async throws -> ApkExportManifest {
        try requireApkExport()
        guard ApplicationLibraryCodec.validIdentifier(identifier) else { throw ApkExportError.sourceChanged }
        var request = Droidmatch_V1_PrepareApkExportRequest(); request.packageIdentifier = identifier
        do {
            return try await execute(payload: request, requestPayloadType: .prepareApkExportRequest,
                responsePayloadType: .prepareApkExportResponse) { bytes in
                    try ApkExportCodec.manifest(bytes, identifier: identifier)
                }
        } catch let RpcControlClientError.remoteError(error) { throw ApkExportCodec.failure(error.code) }
    }

    func validateApkExport(id: String) async throws {
        try requireApkExport()
        var request = Droidmatch_V1_ValidateApkExportRequest(); request.exportID = id
        do {
            let _: Bool = try await execute(payload: request, requestPayloadType: .validateApkExportRequest,
                responsePayloadType: .validateApkExportResponse) { bytes in
                    guard bytes.count <= 1024 else { throw ApkExportError.invalidResponse }
                    let response = try Droidmatch_V1_ValidateApkExportResponse(serializedBytes: bytes)
                    if response.hasError {
                        guard response.exportID.isEmpty, response.error.code != .unspecified else {
                            throw ApkExportError.invalidResponse
                        }
                        throw ApkExportCodec.failure(response.error.code)
                    }
                    guard response.exportID == id else { throw ApkExportError.invalidResponse }
                    return true
                }
        } catch let RpcControlClientError.remoteError(error) { throw ApkExportCodec.failure(error.code) }
    }

    private func requireApkExport() throws {
        try requireReady(); try requireAuthenticatedSession()
        do { try requireCapability(.apkExport); try requireCapability(.fileRead) }
        catch { throw ApkExportError.unsupported }
    }
}
