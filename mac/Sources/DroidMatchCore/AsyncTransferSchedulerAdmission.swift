import Foundation

/// Side-effect-free admission plus the terminal compatibility projection.
/// Actor serialization remains in `AsyncTransferScheduler`; this helper owns
/// no tasks, persistence writes, clients, or filesystem access.
enum AsyncTransferSchedulerAdmission {
    static func error(
        for request: AsyncTransferJobRequest,
        acceptsSubmissions: Bool,
        records: [UUID: AsyncTransferSchedulerJobRecord]
    ) -> AsyncTransferSchedulerError? {
        guard acceptsSubmissions,
              let destination = AsyncTransferSchedulerPolicy
                  .downloadDestinationNamespace(for: request),
              records.values.contains(where: { record in
                  !record.state.isTerminal
                      && AsyncTransferSchedulerPolicy
                          .downloadDestinationNamespace(for: record.request)
                          .map { $0.conflicts(with: destination) } == true
              }) else {
            return nil
        }
        return .duplicateDownloadDestination
    }

    static func recordRejected(
        _ request: AsyncTransferJobRequest,
        error: AsyncTransferSchedulerError,
        nextSequence: inout UInt64,
        records: inout [UUID: AsyncTransferSchedulerJobRecord],
        consumerState: inout AsyncTransferSchedulerConsumerState
    ) -> UUID {
        let id = UUID()
        let metadata = AsyncTransferSchedulerPolicy.metadata(for: request)
        var record = AsyncTransferSchedulerJobRecord(
            id: id,
            sequence: nextSequence,
            request: request,
            kind: metadata.kind,
            source: metadata.source,
            destination: metadata.destination,
            supportsCheckpointPause: AsyncTransferSchedulerPolicy
                .supportsCheckpointPause(request)
        )
        nextSequence &+= 1
        record.state = .failed
        record.failureDescription = error.description
        record.settled = true
        records[id] = record
        consumerState.settle(id, with: .failure(error.description))
        consumerState.broadcast(records.values
            .sorted { $0.sequence < $1.sequence }
            .map(\.snapshot))
        return id
    }
}

extension AsyncTransferScheduler {
    /// Existing UUID consumers receive a visible terminal rejection row.
    @discardableResult
    public func submit(_ request: AsyncTransferJobRequest) -> UUID {
        do {
            return try submitValidated(request)
        } catch {
            return AsyncTransferSchedulerAdmission.recordRejected(
                request, error: error, nextSequence: &nextSequence,
                records: &records, consumerState: &consumerState
            )
        }
    }

    /// Checks admission without allocating, persisting, or starting a job.
    /// Prerequisite callers must still atomically recheck through submission.
    public func validateSubmission(
        _ request: AsyncTransferJobRequest
    ) throws(AsyncTransferSchedulerError) {
        if let error = AsyncTransferSchedulerAdmission.error(
            for: request, acceptsSubmissions: acceptsSubmissions, records: records
        ) {
            throw error
        }
    }

    /// Atomically revalidates admission and enqueues the accepted request.
    @discardableResult
    public func submitValidated(
        _ request: AsyncTransferJobRequest
    ) throws(AsyncTransferSchedulerError) -> UUID {
        try validateSubmission(request)
        return submitAdmitted(request)
    }
}
