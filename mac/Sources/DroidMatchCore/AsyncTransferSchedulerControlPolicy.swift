import Foundation

/// Runtime work the scheduler actor performs only after a control transition
/// has crossed its durable persistence boundary.
enum AsyncTransferSchedulerControlEffect: Equatable {
    case settleCancelled
    case startJobs
    case cancelRateExpiry
    case cancelExecutor
    case startCleanup
}

/// One reversible record/queue mutation plus its ordered runtime effects.
///
/// The value contains no task, continuation, store, timer, or socket. The actor
/// persists the mutated records first, rolls them back on failure, and otherwise
/// applies `effects` in order so cancellation cannot escape the write boundary.
struct AsyncTransferSchedulerControlAction {
    let jobID: UUID
    let effects: [AsyncTransferSchedulerControlEffect]
    private let previousRecord: AsyncTransferSchedulerJobRecord
    private let previousQueue: [UUID]?

    init(
        jobID: UUID,
        effects: [AsyncTransferSchedulerControlEffect],
        previousRecord: AsyncTransferSchedulerJobRecord,
        previousQueue: [UUID]?
    ) {
        self.jobID = jobID
        self.effects = effects
        self.previousRecord = previousRecord
        self.previousQueue = previousQueue
    }

    func rollback(
        records: inout [UUID: AsyncTransferSchedulerJobRecord],
        queue: inout [UUID]
    ) {
        records[jobID] = previousRecord
        if let previousQueue { queue = previousQueue }
    }
}

/// Pure pause, resume, and cancellation decisions for one scheduler record.
///
/// 中文：这里只修改记录与 FIFO，并返回有序副作用；Task、写盘和广播仍由
/// scheduler actor 唯一持有。
enum AsyncTransferSchedulerControlPolicy {
    static func preparePause(
        id: UUID,
        records: inout [UUID: AsyncTransferSchedulerJobRecord],
        queue: inout [UUID]
    ) -> AsyncTransferSchedulerControlAction? {
        guard var record = records[id] else { return nil }
        let previousRecord = record

        if record.state == .queued {
            let previousQueue = queue
            queue.removeAll { $0 == id }
            record.state = .paused
            record.pauseRequiresResume = false
            records[id] = record
            return AsyncTransferSchedulerControlAction(
                jobID: id,
                effects: [.startJobs],
                previousRecord: previousRecord,
                previousQueue: previousQueue
            )
        }

        guard record.canPause else { return nil }
        // Retrying has not entered the displayed attempt; running has.
        record.resumeAttemptBase = record.state == .retrying
            ? max(0, record.attemptNumber - 1)
            : record.attemptNumber
        record.pauseRequiresResume = true
        record.state = .pausing
        record.retryDelayMilliseconds = nil
        record.failureDescription = nil
        records[id] = record
        return AsyncTransferSchedulerControlAction(
            jobID: id,
            effects: [.cancelRateExpiry, .cancelExecutor],
            previousRecord: previousRecord,
            previousQueue: nil
        )
    }

    static func prepareResume(
        id: UUID,
        records: inout [UUID: AsyncTransferSchedulerJobRecord],
        queue: inout [UUID]
    ) -> AsyncTransferSchedulerControlAction? {
        guard var record = records[id], record.state == .paused else { return nil }
        let previousRecord = record
        let previousQueue = queue
        if record.pauseRequiresResume {
            let attemptBase = record.resumeAttemptBase ?? record.attemptNumber
            guard AsyncTransferSchedulerPolicy.hasRecoveryHeadroom(
                after: attemptBase,
                for: record.request
            ), let nextAttempt = AsyncTransferSchedulerPolicy.checkedAttemptNumber(
                attemptBase: attemptBase,
                attemptCount: 1
            ) else { return nil }
            record.request = AsyncTransferSchedulerPolicy.resumedRequest(record.request)
            record.attemptBase = attemptBase
            record.attemptNumber = nextAttempt
        }
        record.resumeAttemptBase = nil
        record.pauseRequiresResume = false
        record.state = .queued
        record.retryDelayMilliseconds = nil
        record.failureDescription = nil
        record.rateEstimator.reset()
        record.rateSampleGeneration &+= 1
        records[id] = record
        queue.append(id)
        return AsyncTransferSchedulerControlAction(
            jobID: id,
            effects: [.startJobs],
            previousRecord: previousRecord,
            previousQueue: previousQueue
        )
    }

    static func prepareCancel(
        id: UUID,
        records: inout [UUID: AsyncTransferSchedulerJobRecord],
        queue: inout [UUID]
    ) -> AsyncTransferSchedulerControlAction? {
        guard var record = records[id], !record.state.isTerminal,
              record.state != .cleaning else { return nil }
        let previousRecord = record

        if record.uploadPartialIdentity != nil {
            let previousQueue = record.state == .queued ? queue : nil
            queue.removeAll { $0 == id }
            let active = record.state == .running
                || record.state == .retrying
                || record.state == .pausing
            record.state = .cleaning
            record.retryDelayMilliseconds = nil
            record.failureDescription = nil
            record.settled = false
            records[id] = record
            var effects: [AsyncTransferSchedulerControlEffect] = [.cancelRateExpiry]
            effects.append(active ? .cancelExecutor : .startCleanup)
            if previousQueue != nil { effects.append(.startJobs) }
            return AsyncTransferSchedulerControlAction(
                jobID: id,
                effects: effects,
                previousRecord: previousRecord,
                previousQueue: previousQueue
            )
        }

        if record.state == .queued || record.state == .paused {
            let previousQueue = queue
            queue.removeAll { $0 == id }
            record.state = .cancelled
            record.retryDelayMilliseconds = nil
            record.settled = true
            records[id] = record
            return AsyncTransferSchedulerControlAction(
                jobID: id,
                effects: [.settleCancelled, .startJobs, .cancelRateExpiry],
                previousRecord: previousRecord,
                previousQueue: previousQueue
            )
        }

        record.state = .cancelled
        record.retryDelayMilliseconds = nil
        records[id] = record
        return AsyncTransferSchedulerControlAction(
            jobID: id,
            effects: [.cancelExecutor, .cancelRateExpiry],
            previousRecord: previousRecord,
            previousQueue: nil
        )
    }
}
