import CryptoKit
import Foundation

/// One authenticated product owner. Uploads have their own fresh RPC connection;
/// closing a staging transfer never cancels the browser's control connection.
/// 中文：安装上传使用独立认证连接，取消传输不关闭文件浏览连接。
actor ProductApkInstallationClient: ApkInstallationClient {
    private let control: any ApkInstallControlClient
    private let gate: ProductTransferSessionGate
    private var active = true
    private var uploadClient: AsyncRpcControlClient?
    private var uploadInProgress = false
    private var cancelClient: AsyncRpcControlClient?
    private var cancellationInProgress = false

    init(control: any ApkInstallControlClient, gate: ProductTransferSessionGate) {
        self.control = control; self.gate = gate
    }

    func installationSnapshot() async throws -> ApkInstallationSnapshot {
        try requireActive()
        let result = try await control.listApkInstalls()
        try requireActive()
        return result
    }

    func cancelInstallation(id: String) async throws -> ApkInstallationOperation {
        try requireActive()
        guard !cancellationInProgress else { throw ApkInstallationError.needsAndroidAttention }
        cancellationInProgress = true
        defer { cancellationInProgress = false }
        let client = try await gate.makeClient(attemptIndex: 0)
        guard active && !Task.isCancelled else {
            await client.close(); throw CancellationError()
        }
        cancelClient = client
        do {
            let result = try await withTaskCancellationHandler {
                _ = try await client.handshake()
                try requireActive()
                return try await client.cancelApkInstall(id: id)
            } onCancel: { Task { await client.close() } }
            await client.close(); cancelClient = nil
            try requireActive()
            return result
        } catch {
            await client.close(); cancelClient = nil
            throw error
        }
    }

    func uploadApk(sourceURL: URL, operationID: String,
                   progress: @escaping @Sendable (ApkInstallUploadProgress) async -> Void) async throws
        -> ApkInstallationOperation {
        try requireActive()
        guard !uploadInProgress else { throw ApkInstallationError.needsAndroidAttention }
        guard ApkInstallationPolicy.validID(operationID), sourceURL.isFileURL,
              let name = ApkInstallationPolicy.acceptedFilename(sourceURL.lastPathComponent) else {
            throw ApkInstallationError.invalidFile
        }
        uploadInProgress = true
        defer { uploadInProgress = false }
        let source = AsyncUploadFileSource(sourceURL: sourceURL)
        var preparationAttempted = false
        do {
            let snapshot = try await source.snapshot()
            guard (1...ApkInstallationPolicy.maximumBytes).contains(snapshot.sizeBytes) else {
                throw ApkInstallationError.invalidFile
            }
            let digest = try await hash(source: source, snapshot: snapshot, progress: progress)
            try requireActive()
            let client = try await gate.makeClient(attemptIndex: 0)
            guard active && !Task.isCancelled else {
                await client.close(); throw CancellationError()
            }
            uploadClient = client
            let operation = try await withTaskCancellationHandler {
                _ = try await client.handshake()
                try requireActive()
                preparationAttempted = true
                let prepared = try await client.prepareApkInstall(id: operationID, name: name,
                    size: snapshot.sizeBytes, sha256: digest)
                guard prepared.state == .waitingForUpload else { throw ApkInstallationError.needsAndroidAttention }
                try requireActive()
                let transfer = try await client.openUpload(sourcePath: TransferWireMetadata.localUploadSource,
                    destinationPath: ApkInstallationPolicy.destination(operationID), transferID: operationID,
                    requestedOffsetBytes: 0, expectedSizeBytes: snapshot.sizeBytes)
                guard transfer.openResponse.acceptedOffsetBytes == 0,
                      transfer.openResponse.totalSizeBytes == snapshot.sizeBytes else {
                    throw ApkInstallationError.invalidResponse
                }
                await progress(.init(stage: .sending, completedBytes: 0, totalBytes: snapshot.sizeBytes))
                _ = try await AsyncUploadFileSender().send(transfer: transfer, source: source, snapshot: snapshot) { ack in
                    try Task.checkCancellation()
                    await progress(.init(stage: .sending, completedBytes: ack.nextOffsetBytes,
                                         totalBytes: snapshot.sizeBytes))
                }
                try requireActive()
                let result = try await client.listApkInstalls()
                guard let current = result.operations.first(where: { $0.id == operationID }),
                      current.sizeBytes == snapshot.sizeBytes, current.displayName == name else {
                    throw ApkInstallationError.invalidResponse
                }
                return current
            } onCancel: {
                Task { await client.close() }
            }
            await client.close(); uploadClient = nil
            await source.close()
            try requireActive()
            return operation
        } catch {
            await uploadClient?.close(); uploadClient = nil
            await source.close()
            if preparationAttempted && active {
                // Prepare may have succeeded before its response was lost. Cleanup
                // uses a fresh request; only pre-submission records are cancellable.
                // 中文：准备请求响应丢失也可能已创建会话；新连接仅清理尚未提交的记录。
                _ = await Task { try? await self.cancelInstallation(id: operationID) }.value
            }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let error = error as? ApkInstallationError { throw error }
            if let sourceError = error as? AsyncUploadFileSourceError {
                if case .sourceChanged = sourceError { throw ApkInstallationError.sourceChanged }
                throw ApkInstallationError.invalidFile
            }
            if case RpcControlClientError.remoteError(let remote) = error {
                throw ApkInstallationCodec.failure(remote.code)
            }
            throw ApkInstallationError.connectionUnavailable
        }
    }

    func invalidate() async {
        active = false
        await gate.invalidate()
        await uploadClient?.close()
        uploadClient = nil
        await cancelClient?.close()
        cancelClient = nil
    }

    private func hash(source: AsyncUploadFileSource, snapshot: UploadSourceSnapshot,
                      progress: @escaping @Sendable (ApkInstallUploadProgress) async -> Void) async throws -> Data {
        var hasher = SHA256()
        var offset: Int64 = 0
        while offset < snapshot.sizeBytes {
            try requireActive()
            let count = Int(min(1_048_576, snapshot.sizeBytes - offset))
            let bytes = try await source.read(offsetBytes: offset, byteCount: count, expectedSnapshot: snapshot)
            hasher.update(data: bytes); offset += Int64(bytes.count)
            await progress(.init(stage: .checkingFile, completedBytes: offset, totalBytes: snapshot.sizeBytes))
        }
        try await source.validate(snapshot)
        return Data(hasher.finalize())
    }

    private func requireActive() throws {
        try Task.checkCancellation()
        guard active else { throw CancellationError() }
    }
}
