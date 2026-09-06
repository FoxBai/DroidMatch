import Foundation

extension AsyncRpcControlClient: MediaPlaybackClient {
    public func openMediaPlayback(
        path: String, mimeType: String
    ) async throws -> any MediaPlaybackSource {
        let prefix = "dm://media-videos/media/"
        let token = path.dropFirst(prefix.count)
        guard path.hasPrefix(prefix), !token.isEmpty,
              token.utf8.allSatisfy({ (48...57).contains($0) }),
              Int64(token) != nil, MediaPlaybackPolicy.supports(mimeType: mimeType) else {
            throw MediaPlaybackError.unsupported
        }
        try requireReady()
        try requireAuthenticatedSession()
        try requireCapability(.fileRead)
        try requireCapability(.resumableTransfer)
        try Task.checkCancellation()
        // Once an open enters the shared session, drain it before cancellation.
        // Cancelling that wire request would make other browser RPCs ambiguous.
        let operation = Task {
            try await AsyncMediaPlaybackSource.open(client: self, path: path, mimeType: mimeType)
        }
        let source = try await operation.value
        if Task.isCancelled {
            await source.close()
            throw MediaPlaybackError.closed
        }
        return source
    }
}

/// One preview owns one serial range reader on its existing authenticated client.
/// Closing invalidates publication immediately; an admitted open drains before
/// its stream is cancelled, preserving unrelated control requests on the client.
/// 中文：每个预览串行读取；关闭立即使结果失效，已准入 open 排空后再取消对应流。
actor AsyncMediaPlaybackSource: MediaPlaybackSource {
    nonisolated let content: MediaPlaybackContent
    private let client: AsyncRpcControlClient
    private let path: String
    private let fingerprint: Droidmatch_V1_TransferFingerprint
    private var closed = false
    private var reading = false
    private var transfer: AsyncDownloadTransfer?
    private var cleanup: Task<Void, Error>?

    private init(
        client: AsyncRpcControlClient, path: String, mimeType: String,
        response: Droidmatch_V1_OpenTransferResponse
    ) {
        self.client = client
        self.path = path
        fingerprint = response.acceptedSourceFingerprint
        content = MediaPlaybackContent(byteCount: response.totalSizeBytes, mimeType: mimeType)
    }

    static func open(
        client: AsyncRpcControlClient, path: String, mimeType: String
    ) async throws -> AsyncMediaPlaybackSource {
        do {
            let stream = try await client.openDownload(sourcePath: path)
            let response = stream.openResponse
            // Probe only metadata. Cancellation releases the bounded initial
            // window; no ACK advances a whole-file download in the background.
            do { _ = try await stream.cancel(reason: "video-metadata-ready") }
            catch { await client.close(); throw error }
            guard response.totalSizeBytes > 0, response.hasAcceptedSourceFingerprint,
                  response.acceptedSourceFingerprint.sizeBytes == response.totalSizeBytes,
                  !response.acceptedSourceFingerprint.providerEtag.isEmpty else {
                throw MediaPlaybackError.unsupported
            }
            return AsyncMediaPlaybackSource(
                client: client, path: path, mimeType: mimeType, response: response
            )
        } catch {
            throw normalized(error)
        }
    }

    func read(offset: Int64, length: Int) async throws -> Data {
        guard !closed else { throw MediaPlaybackError.closed }
        guard !reading else { throw MediaPlaybackError.busy }
        let count = try MediaPlaybackPolicy.readLength(
            offset: offset, requested: length, total: content.byteCount
        )
        guard count > 0 else { return Data() }
        try Task.checkCancellation()
        reading = true
        defer { reading = false }
        let operation = Task { try await readRange(offset: offset, length: count) }
        let bytes = try await operation.value
        guard !closed, !Task.isCancelled else { throw MediaPlaybackError.closed }
        return bytes
    }

    private func readRange(offset: Int64, length: Int) async throws -> Data {
        do {
            guard !closed else { throw MediaPlaybackError.closed }
            let stream = try await client.openDownload(
                sourcePath: path,
                requestedOffsetBytes: offset,
                sourceFingerprint: fingerprint
            )
            transfer = stream
            guard !closed else {
                try await finish(stream)
                throw MediaPlaybackError.closed
            }
            let response = stream.openResponse
            guard response.totalSizeBytes == content.byteCount,
                  response.hasAcceptedSourceFingerprint,
                  response.acceptedSourceFingerprint == fingerprint else {
                try await finish(stream)
                throw MediaPlaybackError.sourceChanged
            }
            var bytes = Data()
            bytes.reserveCapacity(length)
            var nextOffset = offset
            var reachedEnd = false
            while bytes.count < length {
                guard !closed else { throw MediaPlaybackError.closed }
                guard let chunk = try await stream.nextChunk(),
                      chunk.offsetBytes == nextOffset, !chunk.data.isEmpty else {
                    throw MediaPlaybackError.unavailable
                }
                // Core's router validated CRC, size, offset and window before
                // yielding this chunk. ACK only data consumed in this range.
                let needed = length - bytes.count
                bytes.append(chunk.data.prefix(needed))
                nextOffset += Int64(chunk.data.count)
                guard !closed else { throw MediaPlaybackError.closed }
                if chunk.finalChunk && chunk.data.count <= needed {
                    transfer = nil
                    try await stream.acknowledge(chunk)
                    reachedEnd = true
                } else if bytes.count < length {
                    try await stream.acknowledge(chunk)
                }
            }
            if reachedEnd { transfer = nil } else { try await finish(stream) }
            guard !closed else { throw MediaPlaybackError.closed }
            return bytes
        } catch {
            if AsyncRpcTransferValidation.isRemoteApplicationError(error) {
                // The router already retired this route. A second cancel would
                // target no stream and needlessly tear down the shared client.
                transfer = nil
            } else if let transfer { try? await finish(transfer) }
            closed = true
            throw Self.normalized(error)
        }
    }

    private func finish(_ stream: AsyncDownloadTransfer) async throws {
        if let cleanup { return try await cleanup.value }
        transfer = nil
        let task = Task {
            do {
                _ = try await stream.cancel(reason: "video-range-complete")
            } catch {
                // Failed cancellation leaves provider ownership uncertain.
                // Closing the session is the existing terminal recovery boundary.
                await client.close()
                throw error
            }
        }
        cleanup = task
        defer { cleanup = nil }
        try await task.value
    }

    func close() async {
        guard !closed else { return }
        closed = true
        if let transfer { try? await finish(transfer) }
    }

    private static func normalized(_ error: Error) -> MediaPlaybackError {
        if let failure = error as? MediaPlaybackError { return failure }
        if error is CancellationError { return .closed }
        if let failure = error as? RpcControlClientError, case let .remoteError(remote) = failure {
            switch remote.code {
            case .permissionRequired, .unauthorized: return .permissionRequired
            case .notFound, .invalidArgument: return .sourceChanged
            case .unsupportedCapability, .unsupportedVersion: return .unsupported
            default: return .unavailable
            }
        }
        return .unavailable
    }
}
