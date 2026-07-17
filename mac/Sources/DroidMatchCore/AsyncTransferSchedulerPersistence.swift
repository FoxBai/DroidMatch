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

    static func restore(
        _ manifest: PersistedTransferQueue,
        downloadDirectoryContexts: [String: LocalDownloadDirectoryContext] = [:]
    ) throws -> RestoredState {
        try manifest.validate()
        var records: [UUID: AsyncTransferSchedulerJobRecord] = [:]
        var queue: [UUID] = []
        var outcomes: [UUID: AsyncTransferJobOutcome] = [:]
        let inputs: [(persisted: PersistedTransferJob, request: AsyncTransferJobRequest)] =
            try manifest.jobs.sorted(by: { $0.sequence < $1.sequence }).map {
                ($0, try $0.request.value())
            }
        var namespaceOwners: [String: UUID] = [:]
        var conflictingDownloadIDs: Set<UUID> = []
        for input in inputs where input.persisted.state != .interrupted {
            guard let namespace = AsyncTransferSchedulerPolicy
                .downloadDestinationNamespace(for: input.request) else { continue }
            for entryName in namespace.entryNames {
                let key = namespace.parentPath + "\0" + entryName
                if let owner = namespaceOwners[key], owner != input.persisted.id {
                    conflictingDownloadIDs.insert(owner)
                    conflictingDownloadIDs.insert(input.persisted.id)
                } else {
                    namespaceOwners[key] = input.persisted.id
                }
            }
        }

        for input in inputs {
            let persisted = input.persisted
            let request = input.request
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
            record.uploadPartialIdentity = try persisted.uploadPartialIdentity?.value(
                for: request
            )
            record.removeAfterUploadCleanup = persisted.removeAfterUploadCleanup == true

            if persisted.state != .interrupted,
               conflictingDownloadIDs.contains(persisted.id) {
                markInterrupted(
                    &record,
                    failureDescription: AsyncTransferSchedulerPolicy
                        .restoredDuplicateDownloadDestinationFailureDescription,
                    outcomes: &outcomes
                )
                records[record.id] = record
                continue
            }

            switch persisted.state {
            case .queued:
                record.state = .queued
                queue.append(record.id)
            case .paused:
                if persisted.pauseRequiresResume,
                   !AsyncTransferSchedulerPolicy.hasValidResumeCheckpoint(
                       for: request,
                       downloadDirectoryContext: Self.downloadContext(
                           for: request,
                           in: downloadDirectoryContexts
                       )
                   ) {
                    markInterrupted(&record, outcomes: &outcomes)
                } else {
                    record.state = .paused
                }
            case .active:
                let resumeBase = max(
                    persisted.resumeAttemptBase ?? 0,
                    persisted.attemptNumber
                )
                if AsyncTransferSchedulerPolicy.hasRecoveryHeadroom(
                    after: resumeBase,
                    for: request
                ), AsyncTransferSchedulerPolicy.hasValidResumeCheckpoint(
                    for: request,
                    downloadDirectoryContext: Self.downloadContext(
                        for: request,
                        in: downloadDirectoryContexts
                    )
                ) {
                    // Only a structurally valid, provably incomplete checkpoint
                    // is equivalent to a pause. A known-total final checkpoint
                    // remains interrupted because final ACK and cleanup are not
                    // one atomic persistence event.
                    record.state = .paused
                    record.pauseRequiresResume = true
                    record.resumeAttemptBase = resumeBase
                } else {
                    markInterrupted(&record, outcomes: &outcomes)
                }
            case .interrupted:
                markInterrupted(&record, outcomes: &outcomes)
            case .cleanupPending:
                record.state = .cleaning
                record.settled = false
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

    private static func downloadContext(
        for request: AsyncTransferJobRequest,
        in contexts: [String: LocalDownloadDirectoryContext]
    ) -> LocalDownloadDirectoryContext? {
        guard case let .download(download) = request else { return nil }
        return contexts[download.destinationURL.standardizedFileURL.path]
    }

    static func manifest(
        for records: [UUID: AsyncTransferSchedulerJobRecord]
    ) throws -> PersistedTransferQueue {
        let jobs = records.values
            .sorted { $0.sequence < $1.sequence }
            .compactMap { record -> PersistedTransferJob? in
                guard let state = AsyncTransferSchedulerPolicy.persistedState(for: record) else {
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
                    pauseRequiresResume: record.pauseRequiresResume,
                    uploadPartialIdentity: record.uploadPartialIdentity.map(
                        PersistedUploadPartialIdentity.init
                    ),
                    removeAfterUploadCleanup: record.removeAfterUploadCleanup
                )
            }
        let manifest = PersistedTransferQueue(jobs: jobs)
        try manifest.validate()
        return manifest
    }

    private static func markInterrupted(
        _ record: inout AsyncTransferSchedulerJobRecord,
        failureDescription: String = AsyncTransferSchedulerPolicy
            .interruptedFailureDescription,
        outcomes: inout [UUID: AsyncTransferJobOutcome]
    ) {
        AsyncTransferSchedulerPolicy.markInterrupted(
            &record,
            failureDescription: failureDescription
        )
        outcomes[record.id] = .failure(failureDescription)
    }
}
