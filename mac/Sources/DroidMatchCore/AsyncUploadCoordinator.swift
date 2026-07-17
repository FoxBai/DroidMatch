import Foundation

public struct AsyncUploadCoordinatorRequest: Sendable {
    public let sourceURL: URL
    public let destinationPath: String
    public let resume: Bool
    public let freshTransferID: String
    public let preferredChunkSizeBytes: UInt32
    public let recoveryPolicy: RecoveryPolicy
    public let resumeRecordURL: URL?
    let partialPreparationObserver: AsyncUploadPartialPreparationObserver?

    public init(
        sourceURL: URL,
        destinationPath: String,
        resume: Bool = false,
        freshTransferID: String = UUID().uuidString,
        preferredChunkSizeBytes: UInt32 = 256 * 1024,
        recoveryPolicy: RecoveryPolicy = .disabled,
        resumeRecordURL: URL? = nil
    ) {
        self.sourceURL = sourceURL
        self.destinationPath = destinationPath
        self.resume = resume
        self.freshTransferID = freshTransferID
        self.preferredChunkSizeBytes = preferredChunkSizeBytes
        self.recoveryPolicy = recoveryPolicy
        self.resumeRecordURL = resumeRecordURL
        partialPreparationObserver = nil
    }

    private init(
        copying request: Self,
        partialPreparationObserver: AsyncUploadPartialPreparationObserver?
    ) {
        sourceURL = request.sourceURL
        destinationPath = request.destinationPath
        resume = request.resume
        freshTransferID = request.freshTransferID
        preferredChunkSizeBytes = request.preferredChunkSizeBytes
        recoveryPolicy = request.recoveryPolicy
        resumeRecordURL = request.resumeRecordURL
        self.partialPreparationObserver = partialPreparationObserver
    }

    func observingPartialPreparation(
        _ observer: @escaping AsyncUploadPartialPreparationObserver
    ) -> Self {
        Self(copying: self, partialPreparationObserver: observer)
    }

    var effectiveResumeRecordURL: URL {
        resumeRecordURL ?? UploadResumeRecord.sidecarURL(forSource: sourceURL)
    }

    /// Only stable, addressable destinations can reopen an interrupted upload.
    /// MediaStore create targets are intentionally fresh-only because reopening
    /// could create a second item instead of continuing the original object.
    var destinationSupportsResume: Bool {
        destinationPath.hasPrefix("dm://app-sandbox/")
            || destinationPath.hasPrefix("dm://saf-")
    }

    var managedResumeRecordBindsTransferID: Bool {
        resumeRecordURL?.lastPathComponent == "\(freshTransferID).json"
    }
}

public struct AsyncUploadCoordinatorResult: Sendable {
    public let upload: UploadResult
    public let attemptCount: Int

    public var recovered: Bool { attemptCount > 1 }

    init(
        upload: UploadResult,
        attemptCount: Int
    ) {
        self.upload = upload
        self.attemptCount = attemptCount
    }
}

public enum AsyncUploadCoordinatorError: Error, CustomStringConvertible, Sendable, Equatable {
    case missingResumeRecord(String)
    case destinationDoesNotSupportResume(String)
    case sourcePathMismatch(expected: String, actual: String)
    case destinationPathMismatch(expected: String, actual: String)
    case sourceMetadataChanged(path: String)
    case weakResumeSourceIdentity
    case transferIDMismatch
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
        case .sourceMetadataChanged:
            return "upload source identity changed"
        case .weakResumeSourceIdentity:
            return "upload resume record lacks a strong source identity"
        case .transferIDMismatch:
            return "upload resume transfer identity changed"
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
        onRetry: (@Sendable (Int, Int64, Error) -> Void)? = nil,
        onProgress: AsyncTransferProgressObserver? = nil
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
        let resumeCapable = request.destinationSupportsResume
        if (request.resume || request.recoveryPolicy.maxAttempts > 0), !resumeCapable {
            throw AsyncUploadCoordinatorError.destinationDoesNotSupportResume(
                request.destinationPath
            )
        }

        let source = AsyncUploadFileSource(sourceURL: request.sourceURL)
        do {
            let expectedSnapshot = try await source.snapshot()
            let existingRecord: UploadResumeRecord?
            if request.resume {
                guard let record = try await resumeStore.loadUpload(
                    recordURL: request.effectiveResumeRecordURL
                ) else {
                    throw AsyncUploadCoordinatorError.missingResumeRecord(
                        request.effectiveResumeRecordURL.path
                    )
                }
                try validateRecord(
                    record,
                    request: request,
                    snapshot: expectedSnapshot
                )
                existingRecord = record
            } else {
                try await resumeStore.removeUpload(
                    recordURL: request.effectiveResumeRecordURL
                )
                existingRecord = nil
            }

            if resumeCapable {
                let writeAheadRecord = existingRecord ?? UploadResumeRecord(
                    transferID: request.freshTransferID,
                    sourcePath: request.sourceURL.path,
                    destinationPath: request.destinationPath,
                    sourceIdentity: UploadSourceIdentityRecord(expectedSnapshot),
                    nextOffsetBytes: 0
                )
                let createdWriteAheadRecord = existingRecord == nil
                if createdWriteAheadRecord {
                    try await resumeStore.saveUpload(
                        writeAheadRecord,
                        recordURL: request.effectiveResumeRecordURL
                    )
                }
                let identity = AsyncUploadPartialIdentity(
                    transferID: writeAheadRecord.transferID,
                    destinationPath: writeAheadRecord.destinationPath,
                    expectedSizeBytes: writeAheadRecord.totalSizeBytes
                )
                do {
                    try await request.partialPreparationObserver?(identity)
                } catch {
                    if createdWriteAheadRecord {
                        try? await resumeStore.removeUpload(
                            recordURL: request.effectiveResumeRecordURL
                        )
                    }
                    throw error
                }
            }

            let result = try await runTransferWithRecoveryAsync(
                policy: request.recoveryPolicy,
                sleeper: sleeper,
                isRetryable: retryClassifier,
                canResume: {
                    try await source.validate(expectedSnapshot)
                    if let record = try await resumeStore.loadUpload(
                        recordURL: request.effectiveResumeRecordURL
                    ) {
                        try validateRecord(
                            record,
                            request: request,
                            snapshot: expectedSnapshot
                        )
                        return true
                    }
                    // Resumable opens are admitted only after a write-ahead
                    // checkpoint. Losing it makes the remote partial identity
                    // ambiguous, so retry must fail closed.
                    return !resumeCapable
                },
                attempt: { attemptIndex in
                    try await performAttempt(
                        request: request,
                        source: source,
                        expectedSnapshot: expectedSnapshot,
                        resumeCapable: resumeCapable,
                        attemptIndex: attemptIndex,
                        onProgress: onProgress
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
        attemptIndex: Int,
        onProgress: AsyncTransferProgressObserver?
    ) async throws -> AsyncUploadCoordinatorResult {
        try await source.validate(expectedSnapshot)
        let record = try await resumeStore.loadUpload(
            recordURL: request.effectiveResumeRecordURL
        )
        if let record {
            try validateRecord(record, request: request, snapshot: expectedSnapshot)
        }
        let requestedOffset = record?.nextOffsetBytes ?? 0

        let client = try await clientFactory(attemptIndex)
        do {
            _ = try await client.handshake()
            let transfer = try await client.openUpload(
                sourcePath: TransferWireMetadata.localUploadSource,
                destinationPath: request.destinationPath,
                transferID: record?.transferID ?? request.freshTransferID,
                requestedOffsetBytes: requestedOffset,
                expectedSizeBytes: expectedSnapshot.sizeBytes,
                preferredChunkSizeBytes: request.preferredChunkSizeBytes
            )
            let response = transfer.openResponse
            guard response.acceptedOffsetBytes == requestedOffset else {
                _ = try? await transfer.cancel(reason: "upload-offset-mismatch")
                throw AsyncUploadCoordinatorError.acceptedOffsetMismatch(
                    requested: requestedOffset,
                    accepted: response.acceptedOffsetBytes
                )
            }
            guard response.totalSizeBytes == expectedSnapshot.sizeBytes else {
                _ = try? await transfer.cancel(reason: "upload-total-size-mismatch")
                throw AsyncUploadCoordinatorError.acceptedTotalSizeMismatch(
                    expected: expectedSnapshot.sizeBytes,
                    actual: response.totalSizeBytes
                )
            }

            let checkpoint = record ?? UploadResumeRecord(
                transferID: response.transferID,
                sourcePath: request.sourceURL.path,
                destinationPath: request.destinationPath,
                sourceIdentity: UploadSourceIdentityRecord(expectedSnapshot),
                nextOffsetBytes: requestedOffset
            )
            if resumeCapable {
                guard record != nil else {
                    _ = try? await transfer.cancel(reason: "upload-sidecar-missing")
                    throw AsyncUploadCoordinatorError.missingResumeRecord(
                        request.effectiveResumeRecordURL.path
                    )
                }
            }

            // For resumable providers the initial update follows the sidecar
            // write; for fresh-only providers the accepted remote offset is the
            // only checkpoint and is always zero.
            await onProgress?(AsyncTransferProgress(
                confirmedBytes: requestedOffset,
                totalBytes: expectedSnapshot.sizeBytes
            ))

            let result: UploadResult
            do {
                result = try await AsyncUploadFileSender().send(
                    transfer: transfer,
                    source: source,
                    snapshot: expectedSnapshot,
                    didAcknowledge: { acknowledgement in
                        if resumeCapable {
                            try await resumeStore.saveUpload(
                                UploadResumeRecord(
                                    transferID: checkpoint.transferID,
                                    sourcePath: checkpoint.sourcePath,
                                    destinationPath: checkpoint.destinationPath,
                                    sourceIdentity: UploadSourceIdentityRecord(
                                        expectedSnapshot
                                    ),
                                    nextOffsetBytes: acknowledgement.nextOffsetBytes
                                ),
                                recordURL: request.effectiveResumeRecordURL
                            )
                        }
                        if !acknowledgement.finalAck {
                            await onProgress?(AsyncTransferProgress(
                                confirmedBytes: acknowledgement.nextOffsetBytes,
                                totalBytes: expectedSnapshot.sizeBytes
                            ))
                        }
                    }
                )
            } catch {
                if !(error is CancellationError) {
                    _ = try? await transfer.cancel(reason: "local-upload-source-or-checkpoint-failure")
                }
                throw error
            }
            try await source.validate(expectedSnapshot)
            if resumeCapable {
                try await resumeStore.removeUpload(
                    recordURL: request.effectiveResumeRecordURL
                )
            }
            // A final update follows source revalidation and checkpoint cleanup,
            // so 100% never hides a late local consistency failure.
            await onProgress?(AsyncTransferProgress(
                confirmedBytes: result.finalOffsetBytes,
                totalBytes: expectedSnapshot.sizeBytes
            ))
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

    private func validateRecord(
        _ record: UploadResumeRecord,
        request: AsyncUploadCoordinatorRequest,
        snapshot: UploadSourceSnapshot
    ) throws {
        guard !request.managedResumeRecordBindsTransferID
                || record.transferID == request.freshTransferID else {
            throw AsyncUploadCoordinatorError.transferIDMismatch
        }
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
        if let sourceIdentity = record.sourceIdentity {
            guard record.formatVersion == UploadResumeRecord.currentFormatVersion,
                  sourceIdentity.matches(snapshot) else {
                throw AsyncUploadCoordinatorError.sourceMetadataChanged(
                    path: request.sourceURL.path
                )
            }
            return
        }
        guard record.nextOffsetBytes == 0 else {
            throw AsyncUploadCoordinatorError.weakResumeSourceIdentity
        }
        guard record.totalSizeBytes == snapshot.sizeBytes,
              record.sourceModifiedUnixMillis == snapshot.modifiedUnixMillis else {
            throw AsyncUploadCoordinatorError.sourceMetadataChanged(
                path: request.sourceURL.path
            )
        }
    }

    func discardPreparedPartial(
        _ identity: AsyncUploadPartialIdentity,
        for request: AsyncUploadCoordinatorRequest
    ) async throws {
        let identity = try identity.validated(for: request)
        _ = try await runTransferWithRecoveryAsync(
            policy: request.recoveryPolicy,
            sleeper: sleeper,
            isRetryable: retryClassifier,
            canResume: { true },
            attempt: { attemptIndex in
                let client = try await clientFactory(attemptIndex)
                do {
                    _ = try await client.handshake()
                    _ = try await client.discardUploadPartial(
                        transferID: identity.transferID,
                        destinationPath: identity.destinationPath,
                        expectedSizeBytes: identity.expectedSizeBytes
                    )
                    await client.close()
                    return true
                } catch {
                    await client.close()
                    throw error
                }
            }
        )
        try await resumeStore.removeUpload(recordURL: request.effectiveResumeRecordURL)
    }

}
