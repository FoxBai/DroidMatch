import Foundation

public struct AsyncMixedTransferSmokeRequest: Sendable {
    public let downloadSourcePath: String
    public let downloadDestinationURL: URL
    public let uploadSourceURL: URL
    public let uploadDestinationPath: String
    public let downloadTransferID: String
    public let uploadTransferID: String
    public let preferredChunkSizeBytes: UInt32
    public let heartbeatMonotonicMillis: Int64

    public init(
        downloadSourcePath: String,
        downloadDestinationURL: URL,
        uploadSourceURL: URL,
        uploadDestinationPath: String,
        downloadTransferID: String = UUID().uuidString,
        uploadTransferID: String = UUID().uuidString,
        preferredChunkSizeBytes: UInt32 = 256 * 1024,
        heartbeatMonotonicMillis: Int64 = Int64(
            ProcessInfo.processInfo.systemUptime * 1_000
        )
    ) {
        self.downloadSourcePath = downloadSourcePath
        self.downloadDestinationURL = downloadDestinationURL
        self.uploadSourceURL = uploadSourceURL
        self.uploadDestinationPath = uploadDestinationPath
        self.downloadTransferID = downloadTransferID
        self.uploadTransferID = uploadTransferID
        self.preferredChunkSizeBytes = preferredChunkSizeBytes
        self.heartbeatMonotonicMillis = heartbeatMonotonicMillis
    }
}

public struct AsyncMixedTransferSmokeResult: Sendable {
    public let handshake: HandshakeSmokeResult
    public let download: DownloadResult
    public let upload: UploadResult
    public let heartbeatMonotonicMillis: Int64
    public let elapsedMilliseconds: Int64
}

public enum AsyncMixedTransferSmokeError: Error, CustomStringConvertible, Sendable, Equatable {
    case emptyDownloadSourcePath
    case emptyUploadDestinationPath
    case duplicateTransferID(String)
    case uploadAcceptedOffsetMismatch(expected: Int64, actual: Int64)
    case uploadTotalSizeMismatch(expected: Int64, actual: Int64)
    case heartbeatMismatch(expected: Int64, actual: Int64)
    case incompleteConcurrentResult

    public var description: String {
        switch self {
        case .emptyDownloadSourcePath:
            return "mixed transfer download source path must be non-empty"
        case .emptyUploadDestinationPath:
            return "mixed transfer upload destination path must be non-empty"
        case let .duplicateTransferID(value):
            return "mixed transfer IDs must be distinct: \(value)"
        case let .uploadAcceptedOffsetMismatch(expected, actual):
            return "mixed upload accepted offset \(actual), expected \(expected)"
        case let .uploadTotalSizeMismatch(expected, actual):
            return "mixed upload total size \(actual), expected \(expected)"
        case let .heartbeatMismatch(expected, actual):
            return "mixed transfer heartbeat \(actual), expected \(expected)"
        case .incompleteConcurrentResult:
            return "mixed transfer concurrent operation ended without both file results"
        }
    }
}

/// Real-session proof for one download, one upload, and one control request.
///
/// Both transfers open before heartbeat; neither can finish before that response.
/// The two file operations then run concurrently. The client owns and always
/// closes this smoke session.
public struct AsyncMixedTransferSmokeClient: Sendable {
    private enum ConcurrentResult: Sendable {
        case download(DownloadResult)
        case upload(UploadResult)
    }

    public init() {}

    public func run(
        host: String = "127.0.0.1",
        port: Int,
        timeoutSeconds: TimeInterval = 5,
        request: AsyncMixedTransferSmokeRequest
    ) async throws -> AsyncMixedTransferSmokeResult {
        try validate(request)
        let started = ProcessInfo.processInfo.systemUptime
        let source = AsyncUploadFileSource(sourceURL: request.uploadSourceURL)

        do {
            let snapshot = try await source.snapshot()
            let session = try await AsyncFramedTcpSession.connect(
                host: host,
                port: port,
                timeoutSeconds: timeoutSeconds
            )
            let client = AsyncRpcControlClient(
                session: session,
                requestedCapabilities: [.fileRead, .fileWrite, .diagnostics],
                requestTimeoutSeconds: timeoutSeconds
            )
            do {
                let result = try await run(
                    client: client,
                    source: source,
                    snapshot: snapshot,
                    request: request,
                    started: started
                )
                await client.close()
                await source.close()
                return result
            } catch {
                // This smoke owns the session; closing it releases both remote
                // transfer states even when one sibling failed mid-operation.
                await client.close()
                throw error
            }
        } catch {
            await source.close()
            throw error
        }
    }

    private func run(
        client: AsyncRpcControlClient,
        source: AsyncUploadFileSource,
        snapshot: UploadSourceSnapshot,
        request: AsyncMixedTransferSmokeRequest,
        started: TimeInterval
    ) async throws -> AsyncMixedTransferSmokeResult {
        let handshake = try await client.handshake()
        let download = try await client.openDownload(
            sourcePath: request.downloadSourcePath,
            transferID: request.downloadTransferID,
            preferredChunkSizeBytes: request.preferredChunkSizeBytes
        )
        let upload = try await client.openUpload(
            // The peer does not authorize uploads from this inactive-side field.
            // Keep local paths and personal file names out of remote diagnostics.
            sourcePath: TransferWireMetadata.localUploadSource,
            destinationPath: request.uploadDestinationPath,
            transferID: request.uploadTransferID,
            expectedSizeBytes: snapshot.sizeBytes,
            preferredChunkSizeBytes: request.preferredChunkSizeBytes
        )
        guard upload.openResponse.acceptedOffsetBytes == 0 else {
            throw AsyncMixedTransferSmokeError.uploadAcceptedOffsetMismatch(
                expected: 0,
                actual: upload.openResponse.acceptedOffsetBytes
            )
        }
        guard upload.openResponse.totalSizeBytes == snapshot.sizeBytes else {
            throw AsyncMixedTransferSmokeError.uploadTotalSizeMismatch(
                expected: snapshot.sizeBytes,
                actual: upload.openResponse.totalSizeBytes
            )
        }

        // Both remote transfer states exist, but neither can be final: download
        // receive has not ACKed a chunk and upload has not sent one. Requiring the
        // control response now proves responsiveness without relying on task race
        // timing or a minimum test-file size.
        let heartbeat = try await client.heartbeat(
            monotonicMillis: request.heartbeatMonotonicMillis
        )
        guard heartbeat.monotonicMillis == request.heartbeatMonotonicMillis else {
            throw AsyncMixedTransferSmokeError.heartbeatMismatch(
                expected: request.heartbeatMonotonicMillis,
                actual: heartbeat.monotonicMillis
            )
        }

        let concurrent = try await withThrowingTaskGroup(
            of: ConcurrentResult.self,
            returning: (
                download: DownloadResult,
                upload: UploadResult
            ).self
        ) { group in
            group.addTask {
                .download(try await download.receive(
                    to: request.downloadDestinationURL
                ))
            }
            group.addTask {
                .upload(try await AsyncUploadFileSender().send(
                    transfer: upload,
                    source: source,
                    snapshot: snapshot,
                    didAcknowledge: { _ in }
                ))
            }
            var downloadResult: DownloadResult?
            var uploadResult: UploadResult?
            for try await result in group {
                switch result {
                case let .download(value): downloadResult = value
                case let .upload(value): uploadResult = value
                }
            }
            guard let downloadResult, let uploadResult else {
                throw AsyncMixedTransferSmokeError.incompleteConcurrentResult
            }
            return (downloadResult, uploadResult)
        }

        try await source.validate(snapshot)
        let elapsed = max(
            1,
            Int64((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        )
        return AsyncMixedTransferSmokeResult(
            handshake: handshake,
            download: concurrent.download,
            upload: concurrent.upload,
            heartbeatMonotonicMillis: heartbeat.monotonicMillis,
            elapsedMilliseconds: elapsed
        )
    }

    private func validate(_ request: AsyncMixedTransferSmokeRequest) throws {
        guard !request.downloadSourcePath.isEmpty else {
            throw AsyncMixedTransferSmokeError.emptyDownloadSourcePath
        }
        guard !request.uploadDestinationPath.isEmpty else {
            throw AsyncMixedTransferSmokeError.emptyUploadDestinationPath
        }
        guard request.downloadTransferID != request.uploadTransferID else {
            throw AsyncMixedTransferSmokeError.duplicateTransferID(
                request.downloadTransferID
            )
        }
    }
}
