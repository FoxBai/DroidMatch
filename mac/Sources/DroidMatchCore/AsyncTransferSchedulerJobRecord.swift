import Foundation

/// Mutable scheduler-owned state kept separate from wire/coordinator models.
struct AsyncTransferSchedulerJobRecord {
    let id: UUID
    let sequence: UInt64
    var request: AsyncTransferJobRequest
    let kind: AsyncTransferJobKind
    let source: String
    let destination: String
    let supportsCheckpointPause: Bool
    var state: AsyncTransferJobState = .queued
    var attemptNumber = 1
    var attemptBase = 0
    var resumeAttemptBase: Int?
    var pauseRequiresResume = false
    var confirmedBytes: Int64 = 0
    var totalBytes: Int64?
    var rateEstimator = AsyncTransferRateEstimator()
    var rateSampleGeneration: UInt64 = 0
    var retryDelayMilliseconds: Int64?
    var failureDescription: String?
    /// Terminal cancellation can be visible before its executor unwinds.
    var settled = false

    var canPause: Bool {
        if state == .queued { return true }
        guard (state == .running || state == .retrying),
              supportsCheckpointPause,
              let totalBytes else {
            return false
        }
        // A 100% checkpoint has already committed and removed its sidecar.
        return confirmedBytes < totalBytes
    }

    var canRemove: Bool {
        state.isTerminal && settled
    }

    var snapshot: AsyncTransferJobSnapshot {
        AsyncTransferJobSnapshot(
            id: id,
            kind: kind,
            state: state,
            source: source,
            destination: destination,
            attemptNumber: attemptNumber,
            confirmedBytes: confirmedBytes,
            totalBytes: totalBytes,
            recentBytesPerSecond: rateEstimator.bytesPerSecond,
            retryDelayMilliseconds: retryDelayMilliseconds,
            failureDescription: failureDescription,
            canPause: canPause,
            canResume: state == .paused,
            canCancel: !state.isTerminal,
            canRemove: canRemove
        )
    }
}
