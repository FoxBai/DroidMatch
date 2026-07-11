import Foundation

/// Pure request/persistence policy extracted from the scheduler actor. It owns
/// no tasks, queues, continuations, timers, or sockets, so restore decisions can
/// be reviewed independently from runtime scheduling.
enum AsyncTransferSchedulerPolicy {
    static let interruptedFailureDescription =
        "persisted active transfer requires manual restart"

    static func persistedState(
        for state: AsyncTransferJobState
    ) -> PersistedTransferJobState? {
        switch state {
        case .queued: return .queued
        case .paused: return .paused
        case .running, .retrying, .pausing: return .active
        case .interrupted: return .interrupted
        case .completed, .failed, .cancelled: return nil
        }
    }

    static func markInterrupted(_ record: inout AsyncTransferSchedulerJobRecord) {
        record.state = .interrupted
        record.retryDelayMilliseconds = nil
        record.failureDescription = interruptedFailureDescription
        record.settled = true
    }

    static func hasValidResumeCheckpoint(for request: AsyncTransferJobRequest) -> Bool {
        do {
            switch request {
            case let .download(value):
                let sidecarURL = DownloadResumeRecord.sidecarURL(
                    forDestination: value.destinationURL
                )
                guard let record = try DownloadResumeRecord.load(from: sidecarURL),
                      record.sourcePath == value.sourcePath else {
                    return false
                }
                let offset = try AtomicDownloadWriter.requestedOffsetBytes(
                    for: value.destinationURL,
                    resume: true
                )
                return offset >= 0
                    && (record.totalSizeBytes < 0 || offset <= record.totalSizeBytes)
            case let .upload(value):
                guard value.destinationSupportsResume,
                      let record = try UploadResumeRecord.load(
                          from: value.effectiveResumeRecordURL
                      ) else {
                    return false
                }
                return record.sourcePath == value.sourceURL.path
                    && record.destinationPath == value.destinationPath
            }
        } catch {
            // One corrupt sidecar interrupts only its own job; it does not make
            // an otherwise valid queue manifest unreadable.
            return false
        }
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
