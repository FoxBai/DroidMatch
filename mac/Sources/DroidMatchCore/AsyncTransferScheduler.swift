import Foundation
import Dispatch

/// Product transfer queue with opt-in, app-owned persistence.
///
/// The scheduler exposes state snapshots consumed by the product presentation
/// layer, while coordinators continue to own protocol, sidecar, and file-I/O
/// invariants. The ordinary initializer remains process-local; `restoring(...)`
/// enables a versioned manifest and gates executor start on a successful write.
public actor AsyncTransferScheduler {
    /// Opaque AppSupport routing state derived only after device proof.
    @_spi(DroidMatchAppSupport) public nonisolated let localFileAccessOwnerID:
        LocalFileAccessOwnerID?
    let maxConcurrentJobs: Int
    let jobRunner: AsyncTransferSchedulerJobRunner
    private let monotonicNow: AsyncTransferMonotonicNow

    var nextSequence: UInt64 = 0
    var records: [UUID: AsyncTransferSchedulerJobRecord] = [:]
    private var queue: [UUID] = []
    var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var rateExpiryState: AsyncTransferSchedulerRateExpiryState
    var consumerState = AsyncTransferSchedulerConsumerState()
    private var persistenceState: AsyncTransferSchedulerPersistenceState
    var executionEnabled = true
    var acceptsSubmissions = true

    public init(
        downloadCoordinator: AsyncDownloadCoordinator,
        uploadCoordinator: AsyncUploadCoordinator,
        maxConcurrentJobs: Int = 2
    ) {
        precondition(maxConcurrentJobs > 0, "maxConcurrentJobs must be positive")
        let executors = AsyncTransferSchedulerExecutors(
            downloadCoordinator: downloadCoordinator,
            uploadCoordinator: uploadCoordinator
        )
        self.maxConcurrentJobs = maxConcurrentJobs
        self.localFileAccessOwnerID = nil
        self.persistenceState = AsyncTransferSchedulerPersistenceState(store: nil)
        self.monotonicNow = { DispatchTime.now().uptimeNanoseconds }
        self.rateExpiryState = AsyncTransferSchedulerRateExpiryState()
        self.jobRunner = AsyncTransferSchedulerJobRunner(executors: executors)
    }

    init(
        maxConcurrentJobs: Int,
        downloadExecutor: @escaping AsyncDownloadJobExecutor,
        uploadExecutor: @escaping AsyncUploadJobExecutor,
        uploadCleanupExecutor: @escaping AsyncUploadPartialCleanupExecutor = { _, _ in
            throw RpcControlClientError.invalidTransferState(
                "upload partial cleanup executor is unavailable"
            )
        },
        persistenceStore: TransferQueuePersistenceStore? = nil,
        localFileAccessOwnerID: LocalFileAccessOwnerID? = nil,
        monotonicNow: @escaping AsyncTransferMonotonicNow = {
            DispatchTime.now().uptimeNanoseconds
        },
        rateExpirySleeper: @escaping AsyncTransferRateExpirySleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        precondition(maxConcurrentJobs > 0, "maxConcurrentJobs must be positive")
        self.maxConcurrentJobs = maxConcurrentJobs
        self.localFileAccessOwnerID = localFileAccessOwnerID
        self.persistenceState = AsyncTransferSchedulerPersistenceState(
            store: persistenceStore
        )
        self.jobRunner = AsyncTransferSchedulerJobRunner(
            downloadExecutor: downloadExecutor,
            uploadExecutor: uploadExecutor,
            uploadCleanupExecutor: uploadCleanupExecutor
        )
        self.monotonicNow = monotonicNow
        self.rateExpiryState = AsyncTransferSchedulerRateExpiryState(
            sleeper: rateExpirySleeper
        )
    }

    /// Rebuilds a queue from an explicitly supplied app-owned manifest.
    ///
    /// Corrupt or unknown-version data is left untouched and reported to the
    /// caller. Queued jobs may start only after the recovered manifest has been
    /// normalized and written successfully.
    public static func restoring(
        downloadCoordinator: AsyncDownloadCoordinator,
        uploadCoordinator: AsyncUploadCoordinator,
        persistenceStore: TransferQueuePersistenceStore,
        maxConcurrentJobs: Int = 2,
        startQueuedJobs: Bool = true
    ) async throws -> AsyncTransferScheduler {
        let executors = AsyncTransferSchedulerExecutors(
            downloadCoordinator: downloadCoordinator,
            uploadCoordinator: uploadCoordinator
        )
        let scheduler = AsyncTransferScheduler(
            maxConcurrentJobs: maxConcurrentJobs,
            downloadExecutor: executors.download,
            uploadExecutor: executors.upload,
            uploadCleanupExecutor: executors.uploadCleanup,
            persistenceStore: persistenceStore
        )
        await scheduler.restoreFromPersistence(startQueuedJobs: startQueuedJobs)
        return scheduler
    }

    static func restoring(
        maxConcurrentJobs: Int,
        persistenceStore: TransferQueuePersistenceStore,
        manifest: PersistedTransferQueue? = nil,
        initialPersistenceLoadFailed: Bool = false,
        downloadDirectoryContexts: [String: LocalDownloadDirectoryContext] = [:],
        downloadExecutor: @escaping AsyncDownloadJobExecutor,
        uploadExecutor: @escaping AsyncUploadJobExecutor,
        uploadCleanupExecutor: @escaping AsyncUploadPartialCleanupExecutor = { _, _ in
            throw RpcControlClientError.invalidTransferState(
                "upload partial cleanup executor is unavailable"
            )
        },
        localFileAccessOwnerID: LocalFileAccessOwnerID? = nil,
        startQueuedJobs: Bool = true
    ) async throws -> AsyncTransferScheduler {
        let scheduler = AsyncTransferScheduler(
            maxConcurrentJobs: maxConcurrentJobs,
            downloadExecutor: downloadExecutor,
            uploadExecutor: uploadExecutor,
            uploadCleanupExecutor: uploadCleanupExecutor,
            persistenceStore: persistenceStore,
            localFileAccessOwnerID: localFileAccessOwnerID
        )
        await scheduler.restoreFromPersistence(
            startQueuedJobs: startQueuedJobs,
            manifest: manifest,
            initialPersistenceLoadFailed: initialPersistenceLoadFailed,
            downloadDirectoryContexts: downloadDirectoryContexts
        )
        return scheduler
    }

    @discardableResult
    func submitAdmitted(_ request: AsyncTransferJobRequest) -> UUID {
        let id = UUID()
        let metadata = AsyncTransferSchedulerPolicy.metadata(for: request)
        records[id] = AsyncTransferSchedulerJobRecord(
            id: id,
            sequence: nextSequence,
            request: request,
            kind: metadata.kind,
            source: metadata.source,
            destination: metadata.destination,
            supportsCheckpointPause: AsyncTransferSchedulerPolicy.supportsCheckpointPause(request)
        )
        nextSequence &+= 1
        if !acceptsSubmissions {
            records[id]?.state = .cancelled
            records[id]?.settled = true
            consumerState.settle(id, with: .cancelled)
            broadcastSnapshots()
            return id
        }
        queue.append(id)
        guard persistCurrentQueue() else {
            queue.removeAll { $0 == id }
            if var record = records[id] {
                record.state = .failed
                record.failureDescription = AsyncTransferSchedulerPolicy
                    .persistenceWriteFailureDescription
                record.settled = true
                records[id] = record
            }
            consumerState.settle(
                id,
                with: .failure(
                    AsyncTransferSchedulerPolicy.persistenceWriteFailureDescription
                )
            )
            broadcastSnapshots()
            return id
        }
        _ = startJobsIfPossible()
        broadcastSnapshots()
        return id
    }

    public func snapshot(for id: UUID) throws -> AsyncTransferJobSnapshot {
        guard let record = records[id] else {
            throw AsyncTransferSchedulerError.unknownJob(id)
        }
        return record.snapshot
    }

    public func snapshots() -> [AsyncTransferJobSnapshot] { orderedSnapshots() }

    /// Private local endpoints needed by non-terminal work. AppSupport uses
    /// this set for authorization readiness; it must not enter UI or logs.
    package func requiredLocalFileAccessURLs() -> Set<URL> {
        Set(records.values.filter { !$0.state.isTerminal }.map(\.localFileAccessURL))
    }

    package func authoritativeLocalFileAccessURLs() -> Set<URL>? {
        guard executionEnabled, persistenceState.status != .writeFailed else { return nil }
        return Set(records.values.map(\.localFileAccessURL))
    }

    /// Loads only the immutable product restore plan. AppSupport must acquire
    /// every listed security scope before returning the plan to
    /// `retryProductRestore`; no canonical manifest write happens here.
    package func productRestorePlanIfReloadRequired() throws
        -> ProductTransferRestorePlan? {
        guard persistenceState.requiresReload else { return nil }
        guard acceptsSubmissions,
              !executionEnabled,
              runningTasks.isEmpty else {
            throw TransferQueuePersistenceStoreError.ioFailure
        }
        return try persistenceState.productRestorePlan()
    }

    public func persistenceStatus() -> AsyncTransferQueuePersistenceStatus {
        persistenceState.effectiveStatus(executionEnabled: executionEnabled)
    }

    public func managedUploadResumeRecordURL(transferID: String) -> URL? {
        persistenceState.managedUploadResumeRecordURL(transferID: transferID)
    }

    /// Retries the full atomic manifest write after a previous storage failure.
    /// A queued job remains stopped until its queued-to-active snapshot is also
    /// committed successfully.
    @discardableResult
    public func retryPersistence() -> Bool { retryPersistence(startQueuedJobs: true) }

    @discardableResult
    package func retryPersistence(startQueuedJobs: Bool) -> Bool {
        guard acceptsSubmissions, persistenceState.isEnabled else { return false }
        if !startQueuedJobs { executionEnabled = false }
        if persistenceState.requiresReload {
            do {
                try reloadPersistence()
            } catch {
                return holdExecutionAfterPersistenceFailure()
            }
        } else if !persistCurrentQueue() {
            return holdExecutionAfterPersistenceFailure()
        }
        guard startQueuedJobs else {
            broadcastSnapshots()
            return persistenceState.status == .healthy
        }
        return activateExecutionAfterPersistence()
    }

    /// Revalidates a repaired product manifest while execution remains held.
    /// The supplied directory capabilities must outlive this call so checkpoint
    /// inspection cannot escape the App-owned security-scope transaction.
    @discardableResult
    package func retryProductRestore(
        _ plan: ProductTransferRestorePlan,
        downloadDirectoryContexts: [String: LocalDownloadDirectoryContext]
    ) -> Bool {
        guard acceptsSubmissions,
              persistenceState.isEnabled,
              persistenceState.requiresReload,
              !executionEnabled,
              runningTasks.isEmpty else {
            return false
        }
        do {
            try reloadPersistence(
                manifest: plan.manifest,
                downloadDirectoryContexts: downloadDirectoryContexts
            )
        } catch {
            return holdExecutionAfterPersistenceFailure()
        }
        broadcastSnapshots()
        return persistenceState.status == .healthy
    }

    /// Keeps a partially prepared product restore fail-closed. A later retry
    /// must reload and revalidate the durable manifest under fresh leases.
    package func requireProductRestoreRetry() {
        executionEnabled = false
        guard persistenceState.isEnabled, runningTasks.isEmpty else {
            broadcastSnapshots()
            return
        }
        persistenceState.markReloadRequired()
        broadcastSnapshots()
    }

    @discardableResult
    package func activateExecution() -> Bool {
        guard acceptsSubmissions,
              persistenceState.isEnabled,
              !persistenceState.requiresReload,
              persistCurrentQueue() else {
            return holdExecutionAfterPersistenceFailure()
        }
        return activateExecutionAfterPersistence()
    }

    private func holdExecutionAfterPersistenceFailure() -> Bool {
        executionEnabled = false
        broadcastSnapshots()
        return false
    }

    private func activateExecutionAfterPersistence() -> Bool {
        executionEnabled = true
        let startedCleanly = startJobsIfPossible()
        if !startedCleanly { executionEnabled = false }
        broadcastSnapshots()
        return startedCleanly && persistenceState.status == .healthy
    }

    /// Emits an immediate full snapshot followed by every queue state change.
    public func updates() -> AsyncStream<[AsyncTransferJobSnapshot]> {
        let initial = orderedSnapshots()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observerID = consumerState.addSnapshotObserver(continuation)
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(observerID) }
            }
        }
    }

    /// Cancels every non-terminal job and waits for active executors to unwind.
    ///
    /// Session owners call this before releasing the transport that client
    /// factories depend on. Teardown is deliberately authoritative even when a
    /// persistence write fails: leaving a conservative active manifest for the
    /// next restore is safer than keeping network/file work alive after logout.
    public func shutdown() async {
        guard acceptsSubmissions else { return }
        acceptsSubmissions = false
        let actions = AsyncTransferSchedulerSessionEndPolicy.prepareShutdown(
            records: &records,
            queue: &queue,
            runningJobIDs: Set(runningTasks.keys)
        )
        for action in actions {
            rateExpiryState.cancel(id: action.jobID)
            if let outcome = action.immediateOutcome {
                consumerState.settle(action.jobID, with: outcome)
            }
            if action.shouldCancelExecutor {
                runningTasks[action.jobID]?.cancel()
            }
        }

        _ = persistCurrentQueue()
        broadcastSnapshots()

        // Product coordinators are cancellation-cooperative and close their
        // private RPC client in every error path. Waiting here makes forward
        // release a strict happens-after boundary for file I/O and retries.
        let tasks = actions.compactMap {
            $0.shouldCancelExecutor ? runningTasks[$0.jobID] : nil
        }
        for task in tasks {
            await task.value
        }
    }

    /// Detaches a product session without discarding recoverable queue intent.
    ///
    /// Queued work becomes paused. Active checkpoint-capable work is cancelled
    /// into a paused record that requires an explicit resume on the next
    /// authenticated session. Work without a trustworthy resume boundary is
    /// retained as interrupted and is never replayed automatically.
    public func suspendForSessionEnd() async {
        guard acceptsSubmissions else { return }
        acceptsSubmissions = false
        executionEnabled = false
        let activeTasks = runningTasks
        let actions = AsyncTransferSchedulerSessionEndPolicy.prepareSuspension(
            records: &records,
            queue: &queue
        )
        for action in actions {
            rateExpiryState.cancel(id: action.jobID)
            if let outcome = action.immediateOutcome {
                consumerState.settle(action.jobID, with: outcome)
            }
            if action.shouldCancelExecutor {
                activeTasks[action.jobID]?.cancel()
            }
        }

        _ = persistCurrentQueue()
        broadcastSnapshots()
        for task in activeTasks.values {
            await task.value
        }
    }
    public func waitForCompletion(_ id: UUID) async throws -> AsyncTransferJobOutcome {
        guard records[id] != nil else {
            throw AsyncTransferSchedulerError.unknownJob(id)
        }
        if let outcome = consumerState.outcome(for: id) {
            return outcome
        }
        return try await withCheckedThrowingContinuation { continuation in
            consumerState.addCompletionWaiter(continuation, for: id)
        }
    }

    /// Holds queued work, or closes a running coordinator after it has emitted a
    /// trusted durable checkpoint. The coordinator owns an exclusive TCP session,
    /// so cancellation tears down only this job while retaining its sidecar/partial.
    @discardableResult
    public func pause(_ id: UUID) -> Bool {
        guard acceptsSubmissions,
              let action = AsyncTransferSchedulerControlPolicy.preparePause(
                  id: id,
                  records: &records,
                  queue: &queue
              ) else { return false }
        return commitControlAction(action)
    }

    /// Requeues a paused job at the FIFO tail. A job that had started is rebuilt
    /// as an explicit resume request while preserving its transfer identity.
    @discardableResult
    public func resume(_ id: UUID) -> Bool {
        guard acceptsSubmissions,
              let action = AsyncTransferSchedulerControlPolicy.prepareResume(
                  id: id,
                  records: &records,
                  queue: &queue
              ) else { return false }
        return commitControlAction(action)
    }

    /// Cancels queued/paused work immediately or requests cancellation of an
    /// active coordinator.
    /// Returns false for unknown or already-terminal jobs.
    @discardableResult
    public func cancel(_ id: UUID) -> Bool {
        if acceptsSubmissions, var record = records[id], record.state == .cleaning,
           record.failureDescription != nil, runningTasks[id] == nil {
            let previous = record
            record.failureDescription = nil
            records[id] = record
            guard persistCurrentQueue() else {
                records[id] = previous
                broadcastSnapshots()
                return false
            }
            _ = startJobsIfPossible()
            broadcastSnapshots()
            return runningTasks[id] != nil
        }
        guard acceptsSubmissions,
              let action = AsyncTransferSchedulerControlPolicy.prepareCancel(
                  id: id,
                  records: &records,
                  queue: &queue
              ) else { return false }
        return commitControlAction(action)
    }

    private func commitControlAction(
        _ action: AsyncTransferSchedulerControlAction
    ) -> Bool {
        guard persistCurrentQueue() else {
            action.rollback(records: &records, queue: &queue)
            broadcastSnapshots()
            return false
        }
        for effect in action.effects {
            switch effect {
            case .settleCancelled:
                consumerState.settle(action.jobID, with: .cancelled)
            case .startJobs:
                _ = startJobsIfPossible()
            case .cancelRateExpiry:
                rateExpiryState.cancel(id: action.jobID)
            case .cancelExecutor:
                runningTasks[action.jobID]?.cancel()
            case .startCleanup:
                _ = startJobsIfPossible()
            }
        }
        broadcastSnapshots()
        return true
    }

    /// Removes terminal history after consumers no longer need it.
    @discardableResult
    public func remove(_ id: UUID) -> Bool {
        guard acceptsSubmissions, let record = records[id],
              record.canRemove,
              consumerState.outcome(for: id) != nil,
              runningTasks[id] == nil else {
            return false
        }
        if record.uploadPartialIdentity != nil {
            return beginTerminalRemovalCleanup(id: id, record: record)
        }
        let previousOutcome = consumerState.removeOutcome(for: id)
        records.removeValue(forKey: id)
        guard persistCurrentQueue() else {
            records[id] = record
            consumerState.restoreOutcome(previousOutcome, for: id)
            broadcastSnapshots()
            return false
        }
        rateExpiryState.cancel(id: id)
        broadcastSnapshots()
        return true
    }

    @discardableResult
    func startJobsIfPossible() -> Bool {
        guard executionEnabled, acceptsSubmissions else { return true }
        startPendingUploadCleanups()
        while runningTasks.count < maxConcurrentJobs, !queue.isEmpty {
            let id = queue.removeFirst()
            guard var record = records[id], record.state == .queued else {
                continue
            }
            record.state = .running
            records[id] = record
            guard persistCurrentQueue() else {
                record.state = .queued
                records[id] = record
                queue.insert(id, at: 0)
                return false
            }
            let request = record.request
            let task = Task { [weak self] in
                guard let self else { return }
                await self.execute(id: id, request: request)
            }
            runningTasks[id] = task
        }
        return true
    }

    private func execute(id: UUID, request: AsyncTransferJobRequest) async {
        let outcome = await jobRunner.run(
            request,
            onRetry: { [weak self] retryAttempt, delayMilliseconds, error in
                await self?.markRetry(
                    id: id,
                    retryAttempt: retryAttempt,
                    delayMilliseconds: delayMilliseconds,
                    error: error
                )
            },
            onProgress: { [weak self] progress in
                await self?.markProgress(id: id, progress: progress)
            },
            onUploadPartialPrepared: { [weak self] identity in
                guard let self else { throw CancellationError() }
                try await self.markUploadPartialPrepared(id: id, identity: identity)
            }
        )
        finish(id: id, outcome: outcome)
    }

    private func markRetry(
        id: UUID,
        retryAttempt: Int,
        delayMilliseconds: Int64,
        error: Error
    ) {
        guard var record = records[id],
              let resolution = AsyncTransferSchedulerExecutionPolicy.applyRetry(
                  retryAttempt: retryAttempt,
                  delayMilliseconds: delayMilliseconds,
                  failureDescription: AsyncTransferFailureLabel.label(for: error),
                  to: &record
              ) else {
            return
        }
        switch resolution {
        case .failStop:
            records[id] = record
            if !persistCurrentQueue() { executionEnabled = false }
            rateExpiryState.cancel(id: id)
            runningTasks[id]?.cancel()
            broadcastSnapshots()
            return
        case let .persist(previousRecord):
            records[id] = record
            guard persistCurrentQueue() else {
                AsyncTransferSchedulerExecutionPolicy.applyRetryPersistenceFailure(
                    previousRecord: previousRecord,
                    to: &record
                )
                records[id] = record
                executionEnabled = false
                rateExpiryState.cancel(id: id)
                runningTasks[id]?.cancel()
                broadcastSnapshots()
                return
            }
        }
        rateExpiryState.cancel(id: id)
        broadcastSnapshots()
    }

    private func markProgress(id: UUID, progress: AsyncTransferProgress) {
        guard var record = records[id],
              let resolution = AsyncTransferSchedulerExecutionPolicy.applyProgress(
                  progress,
                  to: &record,
                  at: monotonicNow()
              ) else {
            return
        }
        records[id] = record
        if resolution.acceptedRateSample {
            rateExpiryState.replace(
                id: id,
                when: resolution.hasRecentRate,
                onExpiry: { [weak self] in
                    await self?.expireRecentRate(
                        id: id,
                        generation: resolution.rateSampleGeneration
                    )
                }
            )
        }
        broadcastSnapshots()
    }

    private func finish(id: UUID, outcome: AsyncTransferJobOutcome) {
        runningTasks.removeValue(forKey: id)
        guard var record = records[id] else {
            _ = startJobsIfPossible()
            return
        }
        if record.state == .cleaning {
            rateExpiryState.cancel(id: id)
            _ = persistCurrentQueue()
            _ = startJobsIfPossible()
            broadcastSnapshots()
            return
        }
        let resolution = AsyncTransferSchedulerCompletionPolicy.reconcile(
            outcome,
            with: &record,
            at: monotonicNow()
        )
        records[id] = record
        _ = persistCurrentQueue()
        // Every executor unwind retires its rate timer; a terminal transition
        // freezes any still-valid rate for result/diagnostics presentation.
        rateExpiryState.cancel(id: id)
        if let finalOutcome = resolution.outcomeToSettle {
            consumerState.settle(id, with: finalOutcome)
        }
        _ = startJobsIfPossible()
        broadcastSnapshots()
    }

    private func restoreFromPersistence(
        startQueuedJobs: Bool,
        manifest: PersistedTransferQueue? = nil,
        initialPersistenceLoadFailed: Bool = false,
        downloadDirectoryContexts: [String: LocalDownloadDirectoryContext] = [:]
    ) {
        guard persistenceState.isEnabled else { return }
        precondition(records.isEmpty, "a scheduler can restore persistence only once")
        executionEnabled = startQueuedJobs
        if initialPersistenceLoadFailed {
            persistenceState.markReloadRequired()
            executionEnabled = false
            broadcastSnapshots()
            return
        }
        do {
            try reloadPersistence(
                manifest: manifest,
                downloadDirectoryContexts: downloadDirectoryContexts
            )
        } catch {
            // Do not expose partial restored state or overwrite an unreadable
            // archive. Explicit retry must reload durable state from scratch.
            records = [:]
            queue = []
            consumerState.replaceOutcomes(with: [:])
            nextSequence = 0
            broadcastSnapshots()
            return
        }
        _ = startJobsIfPossible()
        broadcastSnapshots()
    }

    private func reloadPersistence(
        manifest: PersistedTransferQueue? = nil,
        downloadDirectoryContexts: [String: LocalDownloadDirectoryContext] = [:]
    ) throws {
        let restored = try persistenceState.reload(
            manifest: manifest,
            downloadDirectoryContexts: downloadDirectoryContexts
        )
        records = restored.records
        queue = restored.queue
        consumerState.replaceOutcomes(with: restored.outcomes)
        nextSequence = restored.nextSequence
    }

    @discardableResult
    func persistCurrentQueue() -> Bool {
        persistenceState.save(records: records)
    }

    private func orderedSnapshots() -> [AsyncTransferJobSnapshot] {
        records.values
            .sorted { $0.sequence < $1.sequence }
            .map(\.snapshot)
    }

    func broadcastSnapshots() {
        consumerState.broadcast(orderedSnapshots())
    }

    private func removeObserver(_ id: UUID) {
        consumerState.removeSnapshotObserver(id)
    }

    private func expireRecentRate(id: UUID, generation: UInt64) {
        guard var record = records[id],
              AsyncTransferSchedulerExecutionPolicy.expireRecentRate(
                  generation: generation,
                  in: &record
              ) else {
            return
        }
        records[id] = record
        rateExpiryState.forget(id: id)
        broadcastSnapshots()
    }

}
