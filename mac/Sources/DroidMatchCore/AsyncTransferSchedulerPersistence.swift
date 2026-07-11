import Foundation

/// Pure manifest-to-runtime conversion for the transfer scheduler.
///
/// The scheduler actor remains the sole owner of tasks, queues, continuations,
/// and persistence writes. This boundary only validates and canonicalizes data,
/// making crash-recovery policy reviewable without actor lifecycle noise.
enum AsyncTransferSchedulerPersistence {
    struct RestoredState {
        let records: [UUID: AsyncTransferSchedulerJobRecord]
        let queue: [UUID]
        let outcomes: [UUID: AsyncTransferJobOutcome]
        let nextSequence: UInt64
    }

    static func restore(_ manifest: PersistedTransferQueue) throws -> RestoredState {
        var records: [UUID: AsyncTransferSchedulerJobRecord] = [:]
        var queue: [UUID] = []
        var outcomes: [UUID: AsyncTransferJobOutcome] = [:]

        for persisted in manifest.jobs.sorted(by: { $0.sequence < $1.sequence }) {
            let request = try persisted.request.value()
            let metadata = AsyncTransferSchedulerPolicy.metadata(for: request)
            var record = AsyncTransferSchedulerJobRecord(
                id: persisted.id,
                sequence: persisted.sequence,
                request: request,
                kind: metadata.kind,
                source: metadata.source,
                destination: metadata.destination,
                supportsCheckpointPause: AsyncTransferSchedulerPolicy.supportsCheckpointPause(request)
            )
            record.attemptNumber = persisted.attemptNumber
            record.attemptBase = persisted.attemptBase
            record.resumeAttemptBase = persisted.resumeAttemptBase
            record.pauseRequiresResume = persisted.pauseRequiresResume

            switch persisted.state {
            case .queued:
                record.state = .queued
                queue.append(record.id)
            case .paused:
                if persisted.pauseRequiresResume,
                   !AsyncTransferSchedulerPolicy.hasValidResumeCheckpoint(for: request) {
                    markInterrupted(&record, outcomes: &outcomes)
                } else {
                    record.state = .paused
                }
            case .active:
                if AsyncTransferSchedulerPolicy.hasValidResumeCheckpoint(for: request) {
                    // A crash is equivalent to a checkpoint pause. The eventual
                    // user resume rebuilds the request and advances the attempt.
                    record.state = .paused
                    record.pauseRequiresResume = true
                    record.resumeAttemptBase = max(
                        persisted.resumeAttemptBase ?? 0,
                        persisted.attemptNumber
                    )
                } else {
                    markInterrupted(&record, outcomes: &outcomes)
                }
            case .interrupted:
                markInterrupted(&record, outcomes: &outcomes)
            }
            records[record.id] = record
        }

        let nextSequence = manifest.jobs.map(\.sequence).max().map { $0 + 1 } ?? 0
        return RestoredState(
            records: records,
            queue: queue,
            outcomes: outcomes,
            nextSequence: nextSequence
        )
    }

    static func manifest(
        for records: [UUID: AsyncTransferSchedulerJobRecord]
    ) throws -> PersistedTransferQueue {
        let jobs = records.values
            .sorted { $0.sequence < $1.sequence }
            .compactMap { record -> PersistedTransferJob? in
                guard let state = AsyncTransferSchedulerPolicy.persistedState(for: record.state) else {
                    return nil
                }
                return PersistedTransferJob(
                    id: record.id,
                    sequence: record.sequence,
                    request: PersistedTransferRequest(record.request),
                    state: state,
                    attemptNumber: record.attemptNumber,
                    attemptBase: record.attemptBase,
                    resumeAttemptBase: record.resumeAttemptBase,
                    pauseRequiresResume: record.pauseRequiresResume
                )
            }
        let manifest = PersistedTransferQueue(jobs: jobs)
        try manifest.validate()
        return manifest
    }

    private static func markInterrupted(
        _ record: inout AsyncTransferSchedulerJobRecord,
        outcomes: inout [UUID: AsyncTransferJobOutcome]
    ) {
        AsyncTransferSchedulerPolicy.markInterrupted(&record)
        outcomes[record.id] = .failure(
            AsyncTransferSchedulerPolicy.interruptedFailureDescription
        )
    }
}
