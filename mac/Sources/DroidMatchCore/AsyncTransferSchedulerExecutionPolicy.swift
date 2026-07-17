import Foundation

/// Pure execution-event transitions for one scheduler-owned job record.
///
/// The scheduler actor remains the sole owner of records, persistence, tasks,
/// timers, and snapshot delivery. This policy only validates and mutates the
/// supplied value so retry/progress ordering can be reviewed and tested without
/// creating a second concurrency or I/O owner.
enum AsyncTransferSchedulerExecutionPolicy {
    enum RetryResolution {
        /// Invalid attempt accounting is a fail-stop transition. The actor must
        /// persist the interrupted record if possible and cancel its executor.
        case failStop
        /// A valid retry must cross persistence before it becomes observable.
        /// The prior value is retained only for fail-closed rollback.
        case persist(previousRecord: AsyncTransferSchedulerJobRecord)
    }

    struct ProgressResolution: Sendable, Equatable {
        let acceptedRateSample: Bool
        let rateSampleGeneration: UInt64
        let hasRecentRate: Bool
    }

    static func applyRetry(
        retryAttempt: Int,
        delayMilliseconds: Int64,
        failureDescription: String,
        to record: inout AsyncTransferSchedulerJobRecord
    ) -> RetryResolution? {
        guard record.state == .running || record.state == .retrying else {
            return nil
        }
        guard let attemptNumber = AsyncTransferSchedulerPolicy
            .checkedRetryAttemptNumber(
                attemptBase: record.attemptBase,
                retryAttempt: retryAttempt,
                for: record.request
            ) else {
            AsyncTransferSchedulerPolicy.markInterrupted(
                &record,
                failureDescription: AsyncTransferSchedulerPolicy
                    .attemptAccountingFailureDescription,
                settled: false
            )
            return .failStop
        }

        let previousRecord = record
        record.state = .retrying
        record.attemptNumber = attemptNumber
        record.retryDelayMilliseconds = delayMilliseconds
        record.failureDescription = failureDescription
        record.rateEstimator.reset()
        record.rateSampleGeneration &+= 1
        return .persist(previousRecord: previousRecord)
    }

    static func applyRetryPersistenceFailure(
        previousRecord: AsyncTransferSchedulerJobRecord,
        to record: inout AsyncTransferSchedulerJobRecord
    ) {
        record = previousRecord
        AsyncTransferSchedulerPolicy.markInterrupted(
            &record,
            failureDescription: AsyncTransferSchedulerPolicy
                .retryPersistenceFailureDescription,
            settled: false
        )
    }

    static func applyProgress(
        _ progress: AsyncTransferProgress,
        to record: inout AsyncTransferSchedulerJobRecord,
        at timestamp: UInt64
    ) -> ProgressResolution? {
        guard record.state == .running || record.state == .retrying,
              progress.totalBytes >= 0,
              progress.confirmedBytes >= record.confirmedBytes,
              progress.confirmedBytes <= progress.totalBytes,
              record.totalBytes == nil || record.totalBytes == progress.totalBytes else {
            return nil
        }

        record.confirmedBytes = progress.confirmedBytes
        record.totalBytes = progress.totalBytes
        let acceptedRateSample = record.rateEstimator.record(
            confirmedBytes: progress.confirmedBytes,
            at: timestamp
        )
        if acceptedRateSample {
            record.rateSampleGeneration &+= 1
        }
        if record.state == .retrying {
            record.state = .running
            record.retryDelayMilliseconds = nil
            record.failureDescription = nil
        }
        return ProgressResolution(
            acceptedRateSample: acceptedRateSample,
            rateSampleGeneration: record.rateSampleGeneration,
            hasRecentRate: record.rateEstimator.bytesPerSecond != nil
        )
    }

    @discardableResult
    static func expireRecentRate(
        generation: UInt64,
        in record: inout AsyncTransferSchedulerJobRecord
    ) -> Bool {
        guard record.state == .running,
              record.rateSampleGeneration == generation,
              record.rateEstimator.bytesPerSecond != nil else {
            return false
        }
        record.rateEstimator.reset()
        record.rateSampleGeneration &+= 1
        return true
    }
}
