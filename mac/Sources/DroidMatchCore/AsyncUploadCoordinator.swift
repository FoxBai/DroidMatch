import Foundation

public struct AsyncUploadCoordinatorRequest: Sendable {
    public let sourceURL: URL
    public let destinationPath: String
    public let resume: Bool
    public let freshTransferID: String
    public let preferredChunkSizeBytes: UInt32
    public let recoveryPolicy: RecoveryPolicy

    public init(
        sourceURL: URL,
        destinationPath: String,
        resume: Bool = false,
        freshTransferID: String = UUID().uuidString,
        preferredChunkSizeBytes: UInt32 = 256 * 1024,
        recoveryPolicy: RecoveryPolicy = .disabled
    ) {
        self.sourceURL = sourceURL
        self.destinationPath = destinationPath
        self.resume = resume
        self.freshTransferID = freshTransferID
        self.preferredChunkSizeBytes = preferredChunkSizeBytes
        self.recoveryPolicy = recoveryPolicy
    }
}

public struct AsyncUploadCoordinatorResult: Sendable {
    public let upload: UploadResult
    public let attemptCount: Int

    public var recovered: Bool { attemptCount > 1 }
}

public enum AsyncUploadCoordinatorError: Error, CustomStringConvertible, Sendable, Equatable {
    case missingResumeRecord(String)
    case destinationDoesNotSupportResume(String)
    case sourcePathMismatch(expected: String, actual: String)
    case destinationPathMismatch(expected: String, actual: String)
    case sourceMetadataChanged(path: String)
    case acceptedOffsetMismatch(requested: Int64, accepted: Int64)
    case acceptedTotalSizeMismatch(expected: Int64, actual: Int64)
    case emptyAcknowledgementWindow

    public var description: String {
        switch self {
        case let .missingResumeRecord(path):
            return "upload resume record is missing: \(path)"
        case let .destinationDoesNotSupportResume(path):
            return "upload destination does not support resume: \(path)"
        case let .sourcePathMismatch(expected, actual):
            return "upload resume source mismatch: expected \(expected), got \(actual)"
        case let .destinationPathMismatch(expected, actual):
            return "upload resume destination mismatch: expected \(expected), got \(actual)"
        case let .sourceMetadataChanged(path):
            return "upload source size or modification time changed: \(path)"
        case let .acceptedOffsetMismatch(requested, accepted):
            return "upload accepted offset mismatch: requested \(requested), got \(accepted)"
        case let .acceptedTotalSizeMismatch(expected, actual):
            return "upload total size mismatch: expected \(expected), got \(actual)"
        case .emptyAcknowledgementWindow:
            return "upload window completed without acknowledgements"
        }
    }
}

/// Product-level upload orchestration across source windows and connections.
///
/// The client factory owns transport and authentication. This coordinator owns
/// source-file consistency, four-chunk/two-MiB refill, per-ACK sidecar commits,
/// retry policy, and client teardown. MediaStore destinations remain fresh-only;
/// automatic resume is limited to app-sandbox and SAF providers.
public struct AsyncUploadCoordinator: Sendable {
    private let clientFactory: AsyncRpcControlClientFactory
    private let resumeStore: AsyncTransferResumeStore
    private let sleeper: AsyncRecoverySleeper
    private let retryClassifier: @Sendable (Error) -> Bool

    public init(
        clientFactory: @escaping AsyncRpcControlClientFactory,
        resumeStore: AsyncTransferResumeStore = AsyncTransferResumeStore(),
        sleeper: @escaping AsyncRecoverySleeper = defaultAsyncRecoverySleeper,
        retryClassifier: @escaping @Sendable (Error) -> Bool = isRetryableTransferError
    ) {
        self.clientFactory = clientFactory
        self.resumeStore = resumeStore
        self.sleeper = sleeper
        self.retryClassifier = retryClassifier
    }

    public func upload(
        _ request: AsyncUploadCoordinatorRequest,
        onRetry: (@Sendable (Int, Int64, Error) -> Void)? = nil
    ) async throws -> AsyncUploadCoordinatorResult {
        guard !request.destinationPath.isEmpty else {
            throw RpcControlClientError.invalidTransferState(
                "upload coordinator destination path must be non-empty"
            )
        }
        guard !request.freshTransferID.isEmpty else {
            throw RpcControlClientError.invalidTransferState(
                "upload coordinator transfer ID must be non-empty"
            )
        }
        let resumeCapable = Self.isResumeCapable(request.destinationPath)
        if (request.resume || request.recoveryPolicy.maxAttempts > 0), !resumeCapable {
            throw AsyncUploadCoordinatorError.destinationDoesNotSupportResume(
                request.destinationPath
            )
        }

        let source = AsyncUploadFileSource(sourceURL: request.sourceURL)
        do {
            let expectedSnapshot = try await source.snapshot()
            if request.resume {
                guard let record = try await resumeStore.loadUpload(
                    sourceURL: request.sourceURL
                ) else {
                    throw AsyncUploadCoordinatorError.missingResumeRecord(
                        UploadResumeRecord.sidecarURL(forSource: request.sourceURL).path
                    )
                }
                try validateRecord(
                    record,
                    request: request,
                    snapshot: expectedSnapshot
                )
            } else {
                try await resumeStore.removeUpload(sourceURL: request.sourceURL)
            }

            let result = try await runTransferWithRecoveryAsync(
                policy: request.recoveryPolicy,
                sleeper: sleeper,
                isRetryable: retryClassifier,
                canResume: {
                    try await source.validate(expectedSnapshot)
                    if let record = try await resumeStore.loadUpload(
                        sourceURL: request.sourceURL
                    ) {
                        try validateRecord(
                            record,
                            request: request,
                            snapshot: expectedSnapshot
                        )
                    }
                    // No record means the failed attempt did not pass the open
                    // checkpoint, so another fresh attempt is still safe.
                    return true
                },
                attempt: { attemptIndex in
                    try await performAttempt(
                        request: request,
                        source: source,
                        expectedSnapshot: expectedSnapshot,
                        resumeCapable: resumeCapable,
                        attemptIndex: attemptIndex
                    )
                },
                onRetry: onRetry
            )
            await source.close()
            return result
        } catch {
            await source.close()
            throw error
        }
    }

    private func performAttempt(
        request: AsyncUploadCoordinatorRequest,
        source: AsyncUploadFileSource,
        expectedSnapshot: UploadSourceSnapshot,
        resumeCapable: Bool,
        attemptIndex: Int
    ) async throws -> AsyncUploadCoordinatorResult {
        try await source.validate(expectedSnapshot)
        let record = try await resumeStore.loadUpload(sourceURL: request.sourceURL)
        if let record {
            try validateRecord(record, request: request, snapshot: expectedSnapshot)
        }
        let requestedOffset = record?.nextOffsetBytes ?? 0

        let client = try await clientFactory(attemptIndex)
        do {
            _ = try await client.handshake()
            let transfer = try await client.openUpload(
                sourcePath: request.sourceURL.path,
                destinationPath: request.destinationPath,
                transferID: record?.transferID ?? request.freshTransferID,
                requestedOffsetBytes: requestedOffset,
                expectedSizeBytes: expectedSnapshot.sizeBytes,
                preferredChunkSizeBytes: request.preferredChunkSizeBytes
            )
            let response = transfer.openResponse
            guard response.acceptedOffsetBytes == requestedOffset else {
                try? await transfer.cancel(reason: "upload-offset-mismatch")
                throw AsyncUploadCoordinatorError.acceptedOffsetMismatch(
                    requested: requestedOffset,
                    accepted: response.acceptedOffsetBytes
                )
            }
            guard response.totalSizeBytes == expectedSnapshot.sizeBytes else {
                try? await transfer.cancel(reason: "upload-total-size-mismatch")
                throw AsyncUploadCoordinatorError.acceptedTotalSizeMismatch(
                    expected: expectedSnapshot.sizeBytes,
                    actual: response.totalSizeBytes
                )
            }

            let checkpoint = UploadResumeRecord(
                transferID: response.transferID,
                sourcePath: request.sourceURL.path,
                destinationPath: request.destinationPath,
                totalSizeBytes: expectedSnapshot.sizeBytes,
                sourceModifiedUnixMillis: expectedSnapshot.modifiedUnixMillis,
                nextOffsetBytes: requestedOffset
            )
            if resumeCapable {
                do {
                    try await resumeStore.saveUpload(
                        checkpoint,
                        sourceURL: request.sourceURL
                    )
                } catch {
                    try? await transfer.cancel(reason: "upload-sidecar-save-failed")
                    throw error
                }
            }

            let result: UploadResult
            do {
                result = try await sendFile(
                    transfer: transfer,
                    source: source,
                    expectedSnapshot: expectedSnapshot,
                    checkpoint: checkpoint,
                    persistCheckpoints: resumeCapable,
                    sourceURL: request.sourceURL
                )
            } catch {
                if !(error is CancellationError) {
                    try? await transfer.cancel(reason: "local-upload-source-or-checkpoint-failure")
                }
                throw error
            }
            try await source.validate(expectedSnapshot)
            if resumeCapable {
                try await resumeStore.removeUpload(sourceURL: request.sourceURL)
            }
            await client.close()
            return AsyncUploadCoordinatorResult(
                upload: result,
                attemptCount: attemptIndex + 1
            )
        } catch {
            await client.close()
            throw error
        }
    }

    private func sendFile(
        transfer: AsyncUploadTransfer,
        source: AsyncUploadFileSource,
        expectedSnapshot: UploadSourceSnapshot,
        checkpoint: UploadResumeRecord,
        persistCheckpoints: Bool,
        sourceURL: URL
    ) async throws -> UploadResult {
        let chunkSize = Int(transfer.openResponse.chunkSizeBytes)
        var nextOffset = transfer.openResponse.acceptedOffsetBytes
        var bytesSent: Int64 = 0
        var chunkCount = 0

        while true {
            try Task.checkCancellation()
            let chunks = try await readWindow(
                source: source,
                snapshot: expectedSnapshot,
                startingOffset: nextOffset,
                chunkSize: chunkSize
            )
            let acknowledgements = try await transfer.sendWindow(chunks) { acknowledgement in
                guard persistCheckpoints else { return }
                try await resumeStore.saveUpload(
                    UploadResumeRecord(
                        transferID: checkpoint.transferID,
                        sourcePath: checkpoint.sourcePath,
                        destinationPath: checkpoint.destinationPath,
                        totalSizeBytes: checkpoint.totalSizeBytes,
                        sourceModifiedUnixMillis: checkpoint.sourceModifiedUnixMillis,
                        nextOffsetBytes: acknowledgement.nextOffsetBytes
                    ),
                    sourceURL: sourceURL
                )
            }
            guard let last = acknowledgements.last else {
                throw AsyncUploadCoordinatorError.emptyAcknowledgementWindow
            }
            bytesSent += chunks.reduce(0) { $0 + Int64($1.data.count) }
            chunkCount += chunks.count
            nextOffset = last.nextOffsetBytes
            if last.finalAck {
                return UploadResult(
                    openResponse: transfer.openResponse,
                    chunkCount: chunkCount,
                    bytesSent: bytesSent,
                    finalOffsetBytes: nextOffset
                )
            }
        }
    }

    private func readWindow(
        source: AsyncUploadFileSource,
        snapshot: UploadSourceSnapshot,
        startingOffset: Int64,
        chunkSize: Int
    ) async throws -> [AsyncUploadChunk] {
        var window = UploadWindow(startingOffsetBytes: startingOffset)
        var chunks: [AsyncUploadChunk] = []
        chunks.reserveCapacity(UploadWindow.maxInFlightChunks)
        while window.canSendMore(
            chunkSizeBytes: chunkSize,
            remainingBytes: snapshot.sizeBytes - window.nextSendOffsetBytes
        ) {
            let offset = window.nextSendOffsetBytes
            let byteCount = Int(min(Int64(chunkSize), snapshot.sizeBytes - offset))
            let data = try await source.read(
                offsetBytes: offset,
                byteCount: byteCount,
                expectedSnapshot: snapshot
            )
            let final = offset + Int64(data.count) == snapshot.sizeBytes
            let chunk = AsyncUploadChunk(
                offsetBytes: offset,
                data: data,
                finalChunk: final
            )
            chunks.append(chunk)
            window.recordSent(
                offsetBytes: offset,
                dataLength: data.count,
                finalChunk: final
            )
            if final { break }
        }
        return chunks
    }

    private func validateRecord(
        _ record: UploadResumeRecord,
        request: AsyncUploadCoordinatorRequest,
        snapshot: UploadSourceSnapshot
    ) throws {
        guard record.sourcePath == request.sourceURL.path else {
            throw AsyncUploadCoordinatorError.sourcePathMismatch(
                expected: record.sourcePath,
                actual: request.sourceURL.path
            )
        }
        guard record.destinationPath == request.destinationPath else {
            throw AsyncUploadCoordinatorError.destinationPathMismatch(
                expected: record.destinationPath,
                actual: request.destinationPath
            )
        }
        guard record.totalSizeBytes == snapshot.sizeBytes,
              record.sourceModifiedUnixMillis == snapshot.modifiedUnixMillis else {
            throw AsyncUploadCoordinatorError.sourceMetadataChanged(
                path: request.sourceURL.path
            )
        }
    }

    private static func isResumeCapable(_ destinationPath: String) -> Bool {
        destinationPath.hasPrefix("dm://app-sandbox/")
            || destinationPath.hasPrefix("dm://saf-")
    }
}
