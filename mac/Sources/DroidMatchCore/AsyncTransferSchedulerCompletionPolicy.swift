/// Pure executor-unwind reconciliation for the transfer scheduler.
///
/// This policy mutates only the supplied record. It never owns tasks, queue
/// order, persistence, timers, continuations, or snapshot publication; the
/// scheduler actor applies those effects after receiving the resolution.
enum AsyncTransferSchedulerCompletionPolicy {
    enum Resolution {
        case paused
        case interrupted(AsyncTransferJobOutcome)
        case terminal(AsyncTransferJobOutcome)

        var outcomeToSettle: AsyncTransferJobOutcome? {
            switch self {
            case .paused:
                return nil
            case let .interrupted(outcome), let .terminal(outcome):
                return outcome
            }
        }
    }

    static func reconcile(
        _ proposedOutcome: AsyncTransferJobOutcome,
        with record: inout AsyncTransferSchedulerJobRecord,
        at timestamp: UInt64
    ) -> Resolution {
        // Pause is authoritative for an injected/non-cooperative executor's
        // ordinary unwind. A real download that already crossed its local
        // rollback boundary must complete instead: its checkpoint is gone and
        // presenting it as resumable would manufacture a broken paused job.
        let irreversibleDownloadCompleted: Bool
        if case let .success(.download(result)) = proposedOutcome {
            irreversibleDownloadCompleted = result.completionIsIrreversible
        } else {
            irreversibleDownloadCompleted = false
        }
        if record.state == .pausing, !irreversibleDownloadCompleted {
            record.state = .paused
            record.retryDelayMilliseconds = nil
            record.failureDescription = nil
            record.rateEstimator.reset()
            record.rateSampleGeneration &+= 1
            return .paused
        }

        // Session suspension publishes an interrupted state before cancellation
        // can finish unwinding. Preserve it for ordinary outcomes, but let a
        // download that already crossed its local rollback boundary publish the
        // only truthful result: the destination is committed and no checkpoint
        // remains to resume.
        if record.state == .interrupted,
           AsyncTransferSchedulerPolicy.isRuntimeFailStop(record)
            || !irreversibleDownloadCompleted {
            record.settled = true
            return .interrupted(.failure(
                record.failureDescription
                    ?? AsyncTransferSchedulerPolicy.interruptedFailureDescription
            ))
        }

        let outcome = AsyncTransferSchedulerPolicy.applyTerminalOutcome(
            proposedOutcome,
            to: &record,
            at: timestamp
        )
        return .terminal(outcome)
    }
}
