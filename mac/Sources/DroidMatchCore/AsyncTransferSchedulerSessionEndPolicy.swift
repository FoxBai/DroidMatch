import Foundation

/// Actor-applied effects produced by a pure session-end state transition.
///
/// This value contains no task, timer, continuation, store, or socket. The
/// scheduler actor remains responsible for applying every explicit effect
/// before it yields to executor unwind.
struct AsyncTransferSchedulerSessionEndAction {
    let jobID: UUID
    let shouldCancelExecutor: Bool
    let immediateOutcome: AsyncTransferJobOutcome?
}

/// Pure record and queue transitions for irreversible scheduler termination.
///
/// Keeping these decisions separate makes the replay-safety policy reviewable
/// without moving runtime ownership out of `AsyncTransferScheduler`.
/// 中文：这里只决定会话结束后的记录状态，不持有 Task、写盘或广播职责。
enum AsyncTransferSchedulerSessionEndPolicy {
    static func prepareShutdown(
        records: inout [UUID: AsyncTransferSchedulerJobRecord],
        queue: inout [UUID],
        runningJobIDs: Set<UUID>
    ) -> [AsyncTransferSchedulerSessionEndAction] {
        let affectedJobIDs = records.values
            .filter { !$0.state.isTerminal }
            .map(\.id)
        let affectedSet = Set(affectedJobIDs)
        queue.removeAll { affectedSet.contains($0) }

        return affectedJobIDs.compactMap { id in
            guard var record = records[id] else { return nil }
            record.state = .cancelled
            record.retryDelayMilliseconds = nil
            let hasRunningExecutor = runningJobIDs.contains(id)
            if !hasRunningExecutor {
                record.settled = true
            }
            records[id] = record
            return AsyncTransferSchedulerSessionEndAction(
                jobID: id,
                shouldCancelExecutor: hasRunningExecutor,
                immediateOutcome: hasRunningExecutor ? nil : .cancelled
            )
        }
    }

    static func prepareSuspension(
        records: inout [UUID: AsyncTransferSchedulerJobRecord],
        queue: inout [UUID]
    ) -> [AsyncTransferSchedulerSessionEndAction] {
        queue.removeAll()
        let affectedJobIDs = records.values
            .filter { !$0.state.isTerminal }
            .map(\.id)

        return affectedJobIDs.compactMap { id in
            guard var record = records[id] else { return nil }
            var shouldCancelExecutor = false
            var immediateOutcome: AsyncTransferJobOutcome?
            switch record.state {
            case .queued:
                record.state = .paused
                record.pauseRequiresResume = false
            case .running, .retrying:
                if record.canPause {
                    record.resumeAttemptBase = record.state == .retrying
                        ? max(0, record.attemptNumber - 1)
                        : record.attemptNumber
                    record.pauseRequiresResume = true
                    record.state = .pausing
                } else {
                    AsyncTransferSchedulerPolicy.markInterrupted(&record)
                    immediateOutcome = .failure(
                        AsyncTransferSchedulerPolicy.interruptedFailureDescription
                    )
                }
                shouldCancelExecutor = true
            case .pausing:
                shouldCancelExecutor = true
            case .paused, .interrupted, .completed, .failed, .cancelled:
                break
            }
            record.retryDelayMilliseconds = nil
            record.rateEstimator.reset()
            record.rateSampleGeneration &+= 1
            records[id] = record
            return AsyncTransferSchedulerSessionEndAction(
                jobID: id,
                shouldCancelExecutor: shouldCancelExecutor,
                immediateOutcome: immediateOutcome
            )
        }
    }
}
