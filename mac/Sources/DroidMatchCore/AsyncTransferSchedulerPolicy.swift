import Foundation

/// Pure request/persistence policy extracted from the scheduler actor. It owns
/// no tasks, queues, continuations, timers, or sockets, so restore decisions can
/// be reviewed independently from runtime scheduling.
enum AsyncTransferSchedulerPolicy {
    static let maximumAttemptNumber = 1_000_000
    static let persistenceWriteFailureDescription =
        "transfer queue persistence write failed"
    static let interruptedFailureDescription =
        "persisted active transfer requires manual restart"
    static let attemptAccountingFailureDescription =
        "transfer attempt accounting exceeded its safe limit"
    static let retryPersistenceFailureDescription =
        "transfer retry could not cross its persistence boundary"
    static let duplicateDownloadDestinationFailureDescription =
        "another download already uses this local destination"
    static let restoredDuplicateDownloadDestinationFailureDescription =
        "persisted duplicate download destination requires manual restart"

    static func persistedState(
        for record: AsyncTransferSchedulerJobRecord
    ) -> PersistedTransferJobState? {
        switch record.state {
        case .queued: return .queued
        case .paused: return .paused
        case .running, .retrying, .pausing: return .active
        case .cleaning: return .cleanupPending
        case .interrupted: return .interrupted
        case .failed:
            // A terminal resumable upload remains durable until the user asks
            // to remove it and authenticated cleanup succeeds. On restore it
            // is conservatively presented as interrupted, never auto-replayed.
            return record.uploadPartialIdentity == nil ? nil : .interrupted
        case .completed, .cancelled: return nil
        }
    }

    static func markInterrupted(
        _ record: inout AsyncTransferSchedulerJobRecord,
        failureDescription: String = interruptedFailureDescription,
        settled: Bool = true
    ) {
        record.state = .interrupted
        record.retryDelayMilliseconds = nil
        record.failureDescription = failureDescription
        record.settled = settled
    }

    /// Returns a cumulative 1-based attempt number without allowing either
    /// integer overflow or a runtime value that the persistence format rejects.
    static func checkedAttemptNumber(
        attemptBase: Int,
        attemptCount: Int
    ) -> Int? {
        guard attemptBase >= 0, attemptCount > 0 else { return nil }
        let value = attemptBase.addingReportingOverflow(attemptCount)
        guard !value.overflow, value.partialValue <= maximumAttemptNumber else {
            return nil
        }
        return value.partialValue
    }

    /// A resumed coordinator receives its full configured retry policy. Do not
    /// silently trim that policy at the persistence ceiling; reject the resume
    /// before its first attempt instead.
    static func hasRecoveryHeadroom(
        after attemptBase: Int,
        for request: AsyncTransferJobRequest
    ) -> Bool {
        let retryCount = recoveryPolicy(for: request).maxAttempts
        let attemptCount = retryCount.addingReportingOverflow(1)
        guard !attemptCount.overflow else { return false }
        return checkedAttemptNumber(
            attemptBase: attemptBase,
            attemptCount: attemptCount.partialValue
        ) != nil
    }

    static func checkedRetryAttemptNumber(
        attemptBase: Int,
        retryAttempt: Int,
        for request: AsyncTransferJobRequest
    ) -> Int? {
        guard retryAttempt > 0,
              retryAttempt <= recoveryPolicy(for: request).maxAttempts else {
            return nil
        }
        let attemptCount = retryAttempt.addingReportingOverflow(1)
        guard !attemptCount.overflow else { return nil }
        return checkedAttemptNumber(
            attemptBase: attemptBase,
            attemptCount: attemptCount.partialValue
        )
    }

    static func checkedResultAttemptNumber(
        attemptBase: Int,
        attemptCount: Int,
        for request: AsyncTransferJobRequest
    ) -> Int? {
        guard attemptCount > 0,
              attemptCount - 1 <= recoveryPolicy(for: request).maxAttempts else {
            return nil
        }
        return checkedAttemptNumber(
            attemptBase: attemptBase,
            attemptCount: attemptCount
        )
    }

    static func isRuntimeFailStop(_ record: AsyncTransferSchedulerJobRecord) -> Bool {
        record.failureDescription == attemptAccountingFailureDescription
            || record.failureDescription == retryPersistenceFailureDescription
    }

    private static func recoveryPolicy(
        for request: AsyncTransferJobRequest
    ) -> RecoveryPolicy {
        switch request {
        case let .download(value): return value.recoveryPolicy
        case let .upload(value): return value.recoveryPolicy
        }
    }

    /// Lexical admission reserves the final file, partial, resume sidecar, and
    /// the sidecar writer's fixed recovery entries as one namespace. Execution
    /// independently acquires a physical parent-directory reservation.
    static func downloadDestinationNamespace(
        for request: AsyncTransferJobRequest
    ) -> DownloadDestinationNamespace? {
        guard case let .download(value) = request else { return nil }
        return DownloadDestinationNamespace.lexical(for: value.destinationURL)
    }

    /// Applies a completed executor result without owning actor lifecycle work.
    /// Cancellation wins over a late failure or a non-cooperative executor's
    /// ordinary success. Only a download result explicitly produced after its
    /// local rollback boundary is authoritative: a remote upload ACK cannot
    /// revoke the user's already-visible cancellation. Successful results also
    /// calibrate the final offset because progress may race with completion.
    static func applyTerminalOutcome(
        _ proposedOutcome: AsyncTransferJobOutcome,
        to record: inout AsyncTransferSchedulerJobRecord,
        at timestamp: UInt64
    ) -> AsyncTransferJobOutcome {
        let proposedFinalOutcome: AsyncTransferJobOutcome
        if record.state == .cancelled,
           case let .success(.download(result)) = proposedOutcome,
           result.completionIsIrreversible {
            proposedFinalOutcome = proposedOutcome
        } else if record.state == .cancelled {
            proposedFinalOutcome = .cancelled
        } else {
            proposedFinalOutcome = proposedOutcome
        }
        let finalOutcome: AsyncTransferJobOutcome
        if case let .success(result) = proposedFinalOutcome {
            let attemptCount: Int
            switch result {
            case let .download(value): attemptCount = value.attemptCount
            case let .upload(value): attemptCount = value.attemptCount
            }
            guard let attemptNumber = checkedResultAttemptNumber(
                attemptBase: record.attemptBase,
                attemptCount: attemptCount,
                for: record.request
            ) else {
                finalOutcome = .failure(attemptAccountingFailureDescription)
                return applyTerminalState(finalOutcome, to: &record, at: timestamp)
            }
            record.attemptNumber = attemptNumber
            finalOutcome = proposedFinalOutcome
        } else {
            finalOutcome = proposedFinalOutcome
        }
        return applyTerminalState(finalOutcome, to: &record, at: timestamp)
    }

    private static func applyTerminalState(
        _ finalOutcome: AsyncTransferJobOutcome,
        to record: inout AsyncTransferSchedulerJobRecord,
        at timestamp: UInt64
    ) -> AsyncTransferJobOutcome {
        switch finalOutcome {
        case let .success(result):
            record.uploadPartialIdentity = nil
            record.state = .completed
            record.retryDelayMilliseconds = nil
            record.failureDescription = nil
            switch result {
            case let .download(value):
                // Coordinators normally emitted the final checkpoint already;
                // the estimator intentionally tolerates a duplicate sample.
                _ = record.rateEstimator.record(
                    confirmedBytes: value.download.finalOffsetBytes,
                    at: timestamp
                )
                record.confirmedBytes = value.download.finalOffsetBytes
                record.totalBytes = value.download.openResponse.totalSizeBytes
            case let .upload(value):
                _ = record.rateEstimator.record(
                    confirmedBytes: value.upload.finalOffsetBytes,
                    at: timestamp
                )
                record.confirmedBytes = value.upload.finalOffsetBytes
                record.totalBytes = value.upload.openResponse.totalSizeBytes
            }
        case let .failure(description):
            record.state = .failed
            record.retryDelayMilliseconds = nil
            record.failureDescription = description
        case .cancelled:
            record.state = .cancelled
            record.retryDelayMilliseconds = nil
        }
        record.settled = true
        return finalOutcome
    }

    static func hasValidResumeCheckpoint(
        for request: AsyncTransferJobRequest,
        downloadDirectoryContext: LocalDownloadDirectoryContext? = nil
    ) -> Bool {
        do {
            switch request {
            case let .download(value):
                let sidecarURL = DownloadResumeRecord.sidecarURL(
                    forDestination: value.destinationURL
                )
                guard let record = try DownloadResumeRecord.load(
                    from: sidecarURL,
                    expectedDirectoryIdentity: downloadDirectoryContext?.directoryIdentity,
                    directoryContext: downloadDirectoryContext
                ),
                      record.sourcePath == value.sourcePath,
                      downloadTotalsAgree(record) else {
                    return false
                }
                let offset = try AtomicDownloadWriter.requestedOffsetBytes(
                    for: value.destinationURL,
                    resume: true,
                    expectedDirectoryIdentity: downloadDirectoryContext?.directoryIdentity,
                    directoryContext: downloadDirectoryContext
                )
                return isStrictlyIncompleteCheckpoint(
                    offsetBytes: offset,
                    knownTotalSizeBytes: knownDownloadTotalSize(record)
                )
            case let .upload(value):
                guard value.destinationSupportsResume,
                      let record = try UploadResumeRecord.load(
                          from: value.effectiveResumeRecordURL
                      ) else {
                    return false
                }
                // Restore deliberately checks only durable artifact structure and
                // path binding. Exact upload-source identity needs the product's
                // security-scoped access lease and is revalidated by the upload
                // coordinator immediately before it creates a client.
                return record.sourcePath == value.sourceURL.path
                    && record.destinationPath == value.destinationPath
                    && isStrictlyIncompleteCheckpoint(
                        offsetBytes: record.nextOffsetBytes,
                        knownTotalSizeBytes: record.totalSizeBytes
                    )
                    && (record.nextOffsetBytes == 0
                        || (record.formatVersion == UploadResumeRecord.currentFormatVersion
                            && record.sourceIdentity != nil))
            }
        } catch {
            // One corrupt sidecar interrupts only its own job; it does not make
            // an otherwise valid queue manifest unreadable.
            return false
        }
    }

    /// A checkpoint at its known total may have been captured after the final
    /// ACK but before local cleanup. Reopening it could repeat an already
    /// committed transfer, so restore must keep it interrupted. The strict
    /// comparison also resolves the ambiguous zero-byte `0 / 0` case
    /// conservatively. An unknown total cannot prove the checkpoint incomplete
    /// and therefore also remains interrupted.
    private static func isStrictlyIncompleteCheckpoint(
        offsetBytes: Int64,
        knownTotalSizeBytes: Int64?
    ) -> Bool {
        guard offsetBytes >= 0, let knownTotalSizeBytes else { return false }
        return offsetBytes < knownTotalSizeBytes
    }

    private static func knownDownloadTotalSize(
        _ record: DownloadResumeRecord
    ) -> Int64? {
        let recordTotal = record.totalSizeBytes >= 0 ? record.totalSizeBytes : nil
        let fingerprintTotal = record.fingerprint.sizeBytes >= 0
            ? record.fingerprint.sizeBytes
            : nil
        return recordTotal ?? fingerprintTotal
    }

    private static func downloadTotalsAgree(_ record: DownloadResumeRecord) -> Bool {
        guard record.totalSizeBytes >= 0, record.fingerprint.sizeBytes >= 0 else {
            return true
        }
        return record.totalSizeBytes == record.fingerprint.sizeBytes
    }

    static func metadata(
        for request: AsyncTransferJobRequest
    ) -> (kind: AsyncTransferJobKind, source: String, destination: String) {
        switch request {
        case let .download(value):
            return (.download, value.sourcePath, value.destinationURL.path)
        case let .upload(value):
            return (.upload, value.sourceURL.path, value.destinationPath)
        }
    }

    static func supportsCheckpointPause(_ request: AsyncTransferJobRequest) -> Bool {
        switch request {
        case .download: return true
        case let .upload(value): return value.destinationSupportsResume
        }
    }

    static func resumedRequest(_ request: AsyncTransferJobRequest) -> AsyncTransferJobRequest {
        switch request {
        case let .download(value):
            return .download(AsyncDownloadCoordinatorRequest(
                sourcePath: value.sourcePath,
                destinationURL: value.destinationURL,
                resume: true,
                freshTransferID: value.freshTransferID,
                preferredChunkSizeBytes: value.preferredChunkSizeBytes,
                recoveryPolicy: value.recoveryPolicy
            ))
        case let .upload(value):
            return .upload(AsyncUploadCoordinatorRequest(
                sourceURL: value.sourceURL,
                destinationPath: value.destinationPath,
                resume: true,
                freshTransferID: value.freshTransferID,
                preferredChunkSizeBytes: value.preferredChunkSizeBytes,
                recoveryPolicy: value.recoveryPolicy,
                resumeRecordURL: value.resumeRecordURL
            ))
        }
    }
}
