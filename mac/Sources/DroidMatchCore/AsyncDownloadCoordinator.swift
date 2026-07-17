import Foundation

public typealias AsyncRpcControlClientFactory = @Sendable (
    _ attemptIndex: Int
) async throws -> AsyncRpcControlClient

public struct AsyncDownloadCoordinatorRequest: Sendable {
    public let sourcePath: String
    public let destinationURL: URL
    public let resume: Bool
    public let freshTransferID: String
    public let preferredChunkSizeBytes: UInt32
    public let recoveryPolicy: RecoveryPolicy

    public init(
        sourcePath: String,
        destinationURL: URL,
        resume: Bool = false,
        freshTransferID: String = UUID().uuidString,
        preferredChunkSizeBytes: UInt32 = 256 * 1024,
        recoveryPolicy: RecoveryPolicy = .disabled
    ) {
        self.sourcePath = sourcePath
        self.destinationURL = destinationURL
        self.resume = resume
        self.freshTransferID = freshTransferID
        self.preferredChunkSizeBytes = preferredChunkSizeBytes
        self.recoveryPolicy = recoveryPolicy
    }
}

public struct AsyncDownloadCoordinatorResult: Sendable {
    public let download: DownloadResult
    public let attemptCount: Int
    /// True only after destination publication and checkpoint cleanup have
    /// crossed the coordinator's rollback boundary.
    let completionIsIrreversible: Bool

    public var recovered: Bool { attemptCount > 1 }

    init(
        download: DownloadResult,
        attemptCount: Int,
        completionIsIrreversible: Bool = false
    ) {
        self.download = download
        self.attemptCount = attemptCount
        self.completionIsIrreversible = completionIsIrreversible
    }
}

public enum AsyncDownloadCoordinatorError: Error, CustomStringConvertible, Sendable, Equatable {
    case missingResumeRecord(String)
    case sourcePathMismatch(expected: String, actual: String)
    case orphanedPartial(path: String, sizeBytes: Int64)
    case missingAcceptedSourceFingerprint
    case acceptedSourceFingerprintChanged
    case acceptedTotalSizeChanged(expected: Int64, actual: Int64)
    case localPartialChanged(expected: Int64, actual: Int64)
    case resumeCheckpointNotIncomplete(offsetBytes: Int64, totalSizeBytes: Int64)
    case resumeCheckpointRestoreFailed

    public var description: String {
        switch self {
        case let .missingResumeRecord(path):
            return "download resume record is missing: \(path)"
        case let .sourcePathMismatch(expected, actual):
            return "download resume source mismatch: expected \(expected), got \(actual)"
        case let .orphanedPartial(path, sizeBytes):
            return "download partial has \(sizeBytes) bytes but no resume record: \(path)"
        case .missingAcceptedSourceFingerprint:
            return "download open response did not include an accepted source fingerprint"
        case .acceptedSourceFingerprintChanged:
            return "download accepted source fingerprint changed during resume"
        case let .acceptedTotalSizeChanged(expected, actual):
            return "download total size changed during resume: expected \(expected), got \(actual)"
        case let .localPartialChanged(expected, actual):
            return "download partial changed before transfer: expected \(expected), got \(actual)"
        case let .resumeCheckpointNotIncomplete(offsetBytes, totalSizeBytes):
            return "download resume checkpoint is not incomplete: offset \(offsetBytes), total \(totalSizeBytes)"
        case .resumeCheckpointRestoreFailed:
            return "download commit rollback could not restore its resume checkpoint"
        }
    }
}

/// Keeps destination rollback and checkpoint restoration in one reviewed
/// failure boundary. Checkpoint removal can fail after unlinking, so every
/// successful rollback republishes the same record before returning an error.
enum AsyncDownloadCommitFinalizer {
    static func finalize(
        removeCheckpoint: @Sendable () async throws -> Void,
        finalizeCommit: @Sendable () async throws -> Void,
        rollbackCommit: @Sendable () async throws -> Void,
        restoreCheckpoint: @Sendable () async throws -> Void,
        finalizeRollback: @Sendable () async throws -> Void
    ) async throws {
        do {
            try Task.checkCancellation()
            try await removeCheckpoint()
            try Task.checkCancellation()
            try await finalizeCommit()
        } catch {
            let completionError = error
            do {
                try await rollbackCommit()
            } catch {
                throw AtomicDownloadWriterError.commitUncertain
            }
            do {
                try await restoreCheckpoint()
            } catch {
                throw AsyncDownloadCoordinatorError.resumeCheckpointRestoreFailed
            }
            do {
                try await finalizeRollback()
            } catch {
                throw AtomicDownloadWriterError.commitUncertain
            }
            throw completionError
        }
    }
}

/// Product-level download orchestration across connection attempts.
///
/// The injected factory owns transport creation and pairing/auth configuration;
/// this coordinator owns sidecar checkpoints, open/resume parameters, atomic file
/// receive, retry policy, and client teardown for each attempt.
public struct AsyncDownloadCoordinator: Sendable {
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

    public func download(
        _ request: AsyncDownloadCoordinatorRequest,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil,
        onRetry: (@Sendable (Int, Int64, Error) -> Void)? = nil,
        onProgress: AsyncTransferProgressObserver? = nil
    ) async throws -> AsyncDownloadCoordinatorResult {
        if directoryContext == nil {
            let destination = try await UnrestrictedLocalFileAccessProvider()
                .acquireDownloadDestination(to: request.destinationURL)
            defer { destination.release() }
            guard let context = (destination as? any LocalDownloadDirectoryContextProviding)?
                .directoryContext else {
                throw AtomicDownloadWriterError.unsafeDestinationDirectory
            }
            return try await download(
                request,
                expectedDirectoryIdentity: destination.directoryIdentity,
                directoryContext: context,
                onRetry: onRetry,
                onProgress: onProgress
            )
        }
        guard !request.sourcePath.isEmpty else {
            throw RpcControlClientError.invalidTransferState(
                "download coordinator source path must be non-empty"
            )
        }

        if request.resume {
            let snapshot = try await resumeStore.downloadSnapshot(
                destinationURL: request.destinationURL,
                expectedDirectoryIdentity: expectedDirectoryIdentity,
                directoryContext: directoryContext
            )
            guard let record = snapshot.record else {
                throw AsyncDownloadCoordinatorError.missingResumeRecord(
                    DownloadResumeRecord.sidecarURL(
                        forDestination: request.destinationURL
                    ).path
                )
            }
            try validateSourcePath(record, requestedSourcePath: request.sourcePath)
            try validateIncompleteCheckpoint(snapshot, record: record)
        }

        return try await runTransferWithRecoveryAsync(
            policy: request.recoveryPolicy,
            sleeper: sleeper,
            isRetryable: retryClassifier,
            canResume: {
                let snapshot = try await resumeStore.downloadSnapshot(
                    destinationURL: request.destinationURL,
                    expectedDirectoryIdentity: expectedDirectoryIdentity,
                    directoryContext: directoryContext
                )
                if let record = snapshot.record {
                    try validateSourcePath(
                        record,
                        requestedSourcePath: request.sourcePath
                    )
                    return snapshot.requestedOffsetBytes < record.totalSizeBytes
                }
                // A connection may fail before OpenTransfer establishes a
                // sidecar. Fresh retry is safe only while no bytes exist.
                guard snapshot.requestedOffsetBytes == 0 else {
                    throw AsyncDownloadCoordinatorError.orphanedPartial(
                        path: AtomicDownloadWriter.partialURL(
                            for: request.destinationURL
                        ).path,
                        sizeBytes: snapshot.requestedOffsetBytes
                    )
                }
                return true
            },
            attempt: { attemptIndex in
                try await performAttempt(
                    request: request,
                    attemptIndex: attemptIndex,
                    expectedDirectoryIdentity: expectedDirectoryIdentity,
                    directoryContext: directoryContext,
                    onProgress: onProgress
                )
            },
            onRetry: onRetry
        )
    }

    private func performAttempt(
        request: AsyncDownloadCoordinatorRequest,
        attemptIndex: Int,
        expectedDirectoryIdentity: LocalDirectoryIdentity?,
        directoryContext: LocalDownloadDirectoryContext?,
        onProgress: AsyncTransferProgressObserver?
    ) async throws -> AsyncDownloadCoordinatorResult {
        let writer: AsyncAtomicDownloadWriter
        let snapshot: DownloadResumeSnapshot
        if attemptIndex == 0, !request.resume {
            writer = try await AsyncAtomicDownloadWriter.create(
                destinationURL: request.destinationURL,
                resume: false,
                deferFreshReset: true,
                expectedDirectoryIdentity: expectedDirectoryIdentity,
                directoryContext: directoryContext
            )
            do {
                // Acquire the partial inode lock before retiring any old
                // checkpoint. An aliasing fresh request therefore fails busy
                // without changing the active owner's sidecar or partial.
                try await resumeStore.prepareFreshDownload(
                    destinationURL: request.destinationURL,
                    expectedDirectoryIdentity: expectedDirectoryIdentity,
                    directoryContext: directoryContext
                )
                try await writer.resetFresh()
                snapshot = try await resumeStore.downloadSnapshot(
                    destinationURL: request.destinationURL,
                    expectedDirectoryIdentity: expectedDirectoryIdentity,
                    directoryContext: directoryContext
                )
            } catch {
                try? await writer.close()
                throw error
            }
        } else {
            snapshot = try await resumeStore.downloadSnapshot(
                destinationURL: request.destinationURL,
                expectedDirectoryIdentity: expectedDirectoryIdentity,
                directoryContext: directoryContext
            )
            if let record = snapshot.record {
                try validateSourcePath(record, requestedSourcePath: request.sourcePath)
                try validateIncompleteCheckpoint(snapshot, record: record)
                writer = try await AsyncAtomicDownloadWriter.create(
                    destinationURL: request.destinationURL,
                    resume: true,
                    expectedDirectoryIdentity: expectedDirectoryIdentity,
                    directoryContext: directoryContext
                )
            } else {
                guard snapshot.requestedOffsetBytes == 0 else {
                    throw AsyncDownloadCoordinatorError.orphanedPartial(
                        path: AtomicDownloadWriter.partialURL(
                            for: request.destinationURL
                        ).path,
                        sizeBytes: snapshot.requestedOffsetBytes
                    )
                }
                writer = try await AsyncAtomicDownloadWriter.create(
                    destinationURL: request.destinationURL,
                    resume: false,
                    deferFreshReset: true,
                    expectedDirectoryIdentity: expectedDirectoryIdentity,
                    directoryContext: directoryContext
                )
                do {
                    try await writer.resetFresh()
                } catch {
                    try? await writer.close()
                    throw error
                }
            }
        }
        let record = snapshot.record
        guard writer.requestedOffsetBytes == snapshot.requestedOffsetBytes else {
            try? await writer.close()
            throw AsyncDownloadCoordinatorError.localPartialChanged(
                expected: snapshot.requestedOffsetBytes,
                actual: writer.requestedOffsetBytes
            )
        }

        let client: AsyncRpcControlClient
        do {
            client = try await clientFactory(attemptIndex)
        } catch {
            try? await writer.close()
            throw error
        }
        do {
            _ = try await client.handshake()
            let transfer = try await client.openDownload(
                sourcePath: request.sourcePath,
                transferID: record?.transferID ?? request.freshTransferID,
                requestedOffsetBytes: snapshot.requestedOffsetBytes,
                sourceFingerprint: record?.fingerprint.proto,
                preferredChunkSizeBytes: request.preferredChunkSizeBytes
            )
            let response = transfer.openResponse
            guard response.hasAcceptedSourceFingerprint else {
                _ = try? await transfer.cancel(reason: "missing-source-fingerprint")
                throw AsyncDownloadCoordinatorError.missingAcceptedSourceFingerprint
            }
            let acceptedFingerprint = TransferFingerprintRecord(
                response.acceptedSourceFingerprint
            )
            if let record {
                guard record.fingerprint == acceptedFingerprint else {
                    _ = try? await transfer.cancel(reason: "source-fingerprint-changed")
                    throw AsyncDownloadCoordinatorError.acceptedSourceFingerprintChanged
                }
                guard record.totalSizeBytes == response.totalSizeBytes else {
                    _ = try? await transfer.cancel(reason: "source-total-size-changed")
                    throw AsyncDownloadCoordinatorError.acceptedTotalSizeChanged(
                        expected: record.totalSizeBytes,
                        actual: response.totalSizeBytes
                    )
                }
            }

            let updatedRecord = DownloadResumeRecord(
                transferID: response.transferID,
                sourcePath: request.sourcePath,
                totalSizeBytes: response.totalSizeBytes,
                fingerprint: acceptedFingerprint
            )
            do {
                try await resumeStore.saveDownload(
                    updatedRecord,
                    destinationURL: request.destinationURL,
                    expectedDirectoryIdentity: expectedDirectoryIdentity,
                    directoryContext: directoryContext
                )
            } catch {
                _ = try? await transfer.cancel(reason: "download-sidecar-save-failed")
                throw error
            }

            let result = try await transfer.receive(
                using: writer,
                onProgress: onProgress
            )
            try await AsyncDownloadCommitFinalizer.finalize(
                removeCheckpoint: {
                    try await resumeStore.removeDownload(
                        destinationURL: request.destinationURL,
                        expectedDirectoryIdentity: expectedDirectoryIdentity,
                        directoryContext: directoryContext
                    )
                },
                finalizeCommit: {
                    try await writer.finalizeCommit()
                },
                rollbackCommit: {
                    try await writer.rollbackCommit(retainRecoveryMarker: true)
                },
                restoreCheckpoint: {
                    try await resumeStore.saveDownload(
                        updatedRecord,
                        destinationURL: request.destinationURL,
                        expectedDirectoryIdentity: expectedDirectoryIdentity,
                        directoryContext: directoryContext
                    )
                },
                finalizeRollback: {
                    try await writer.finalizeRollback()
                }
            )
            // A 100% download update means the destination was atomically
            // committed and its now-obsolete resume record was removed.
            await onProgress?(AsyncTransferProgress(
                confirmedBytes: result.finalOffsetBytes,
                totalBytes: response.totalSizeBytes
            ))
            await client.close()
            return AsyncDownloadCoordinatorResult(
                download: result,
                attemptCount: attemptIndex + 1,
                completionIsIrreversible: true
            )
        } catch {
            try? await writer.close()
            await client.close()
            throw error
        }
    }

    private func validateSourcePath(
        _ record: DownloadResumeRecord,
        requestedSourcePath: String
    ) throws {
        guard record.sourcePath == requestedSourcePath else {
            throw AsyncDownloadCoordinatorError.sourcePathMismatch(
                expected: record.sourcePath,
                actual: requestedSourcePath
            )
        }
    }

    private func validateIncompleteCheckpoint(
        _ snapshot: DownloadResumeSnapshot,
        record: DownloadResumeRecord
    ) throws {
        guard snapshot.requestedOffsetBytes < record.totalSizeBytes else {
            throw AsyncDownloadCoordinatorError.resumeCheckpointNotIncomplete(
                offsetBytes: snapshot.requestedOffsetBytes,
                totalSizeBytes: record.totalSizeBytes
            )
        }
    }
}
