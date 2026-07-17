import Foundation

/// Authenticated cleanup lifecycle for provider-owned resumable upload partials.
///
/// The scheduler persists the exact identity before remote creation. Cancellation,
/// shutdown, and terminal-history removal may therefore forget that identity only
/// after Android confirms idempotent deletion and the local sidecar is removed.
extension AsyncTransferScheduler {
    func markUploadPartialPrepared(
        id: UUID,
        identity: AsyncUploadPartialIdentity
    ) throws {
        guard var record = records[id],
              record.state == .running || record.state == .retrying,
              case let .upload(request) = record.request else {
            throw CancellationError()
        }
        let identity = try identity.validated(for: request)
        let previous = record
        record.uploadPartialIdentity = identity
        record.totalBytes = identity.expectedSizeBytes
        records[id] = record
        guard persistCurrentQueue() else {
            records[id] = previous
            executionEnabled = false
            broadcastSnapshots()
            throw TransferQueuePersistenceStoreError.ioFailure
        }
        broadcastSnapshots()
    }

    func beginTerminalRemovalCleanup(
        id: UUID,
        record: AsyncTransferSchedulerJobRecord
    ) -> Bool {
        var cleaning = record
        cleaning.state = .cleaning
        cleaning.failureDescription = nil
        cleaning.retryDelayMilliseconds = nil
        cleaning.removeAfterUploadCleanup = true
        records[id] = cleaning
        guard persistCurrentQueue() else {
            records[id] = record
            broadcastSnapshots()
            return false
        }
        _ = startJobsIfPossible()
        broadcastSnapshots()
        return true
    }

    func startPendingUploadCleanups() {
        let candidates = records.values
            .filter {
                $0.state == .cleaning
                    && $0.failureDescription == nil
                    && $0.uploadPartialIdentity != nil
                    && runningTasks[$0.id] == nil
            }
            .sorted { $0.sequence < $1.sequence }
        for record in candidates where runningTasks.count < maxConcurrentJobs {
            guard case let .upload(request) = record.request,
                  let identity = record.uploadPartialIdentity else { continue }
            let id = record.id
            runningTasks[id] = Task { [weak self] in
                guard let self else { return }
                let outcome = await self.jobRunner.cleanupUploadPartial(
                    request: request,
                    identity: identity
                )
                await self.finishUploadPartialCleanup(id: id, outcome: outcome)
            }
        }
    }

    func finishUploadPartialCleanup(
        id: UUID,
        outcome: AsyncUploadPartialCleanupOutcome
    ) {
        runningTasks.removeValue(forKey: id)
        guard var record = records[id], record.state == .cleaning else {
            _ = startJobsIfPossible()
            return
        }
        switch outcome {
        case .success where record.removeAfterUploadCleanup:
            finishTerminalRemovalCleanup(id: id, record: record)
            return
        case .success:
            let previous = record
            record.uploadPartialIdentity = nil
            record.state = .cancelled
            record.failureDescription = nil
            record.settled = true
            records[id] = record
            guard persistCurrentQueue() else {
                record = previous
                record.failureDescription = AsyncTransferSchedulerPolicy
                    .persistenceWriteFailureDescription
                records[id] = record
                executionEnabled = false
                broadcastSnapshots()
                return
            }
            consumerState.settle(id, with: .cancelled)
        case let .failure(description):
            record.failureDescription = description
            records[id] = record
            if !persistCurrentQueue() { executionEnabled = false }
        case .cancelled:
            records[id] = record
            _ = persistCurrentQueue()
        }
        _ = startJobsIfPossible()
        broadcastSnapshots()
    }

    private func finishTerminalRemovalCleanup(
        id: UUID,
        record: AsyncTransferSchedulerJobRecord
    ) {
        let previousOutcome = consumerState.removeOutcome(for: id)
        records.removeValue(forKey: id)
        guard persistCurrentQueue() else {
            var restored = record
            restored.failureDescription = AsyncTransferSchedulerPolicy
                .persistenceWriteFailureDescription
            records[id] = restored
            consumerState.restoreOutcome(previousOutcome, for: id)
            executionEnabled = false
            broadcastSnapshots()
            return
        }
        _ = startJobsIfPossible()
        broadcastSnapshots()
    }
}
