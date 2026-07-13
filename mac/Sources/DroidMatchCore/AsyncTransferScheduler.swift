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
    private let maxConcurrentJobs: Int
    private let jobRunner: AsyncTransferSchedulerJobRunner
    private let monotonicNow: AsyncTransferMonotonicNow
    private let rateExpirySleeper: AsyncTransferRateExpirySleeper
    private let persistenceStore: TransferQueuePersistenceStore?

    private var nextSequence: UInt64 = 0
    private var records: [UUID: AsyncTransferSchedulerJobRecord] = [:]
    private var queue: [UUID] = []
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var rateExpiryTasks: [UUID: Task<Void, Never>] = [:]
    private var outcomes: [UUID: AsyncTransferJobOutcome] = [:]
    private var waiters: [UUID: [CheckedContinuation<AsyncTransferJobOutcome, Error>]] = [:]
    private var observers: [UUID: AsyncStream<[AsyncTransferJobSnapshot]>.Continuation] = [:]
    private var currentPersistenceStatus: AsyncTransferQueuePersistenceStatus
    private var requiresPersistenceReload = false
    private var executionEnabled = true
    private var acceptsSubmissions = true

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
        self.persistenceStore = nil
        self.currentPersistenceStatus = .disabled
        self.monotonicNow = { DispatchTime.now().uptimeNanoseconds }
        self.rateExpirySleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
        self.jobRunner = AsyncTransferSchedulerJobRunner(executors: executors)
    }

    init(
        maxConcurrentJobs: Int,
        downloadExecutor: @escaping AsyncDownloadJobExecutor,
        uploadExecutor: @escaping AsyncUploadJobExecutor,
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
        self.persistenceStore = persistenceStore
        self.currentPersistenceStatus = persistenceStore == nil ? .disabled : .healthy
        self.jobRunner = AsyncTransferSchedulerJobRunner(
            downloadExecutor: downloadExecutor,
            uploadExecutor: uploadExecutor
        )
        self.monotonicNow = monotonicNow
        self.rateExpirySleeper = rateExpirySleeper
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
            persistenceStore: persistenceStore
        )
        await scheduler.restoreFromPersistence(startQueuedJobs: startQueuedJobs)
        return scheduler
    }

    static func restoring(
        maxConcurrentJobs: Int,
        persistenceStore: TransferQueuePersistenceStore,
        downloadExecutor: @escaping AsyncDownloadJobExecutor,
        uploadExecutor: @escaping AsyncUploadJobExecutor,
        localFileAccessOwnerID: LocalFileAccessOwnerID? = nil,
        startQueuedJobs: Bool = true
    ) async throws -> AsyncTransferScheduler {
        let scheduler = AsyncTransferScheduler(
            maxConcurrentJobs: maxConcurrentJobs,
            downloadExecutor: downloadExecutor,
            uploadExecutor: uploadExecutor,
            persistenceStore: persistenceStore,
            localFileAccessOwnerID: localFileAccessOwnerID
        )
        await scheduler.restoreFromPersistence(startQueuedJobs: startQueuedJobs)
        return scheduler
    }

    @discardableResult
    public func submit(_ request: AsyncTransferJobRequest) -> UUID {
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
            outcomes[id] = .cancelled
            broadcastSnapshots()
            return id
        }
        queue.append(id)
        guard persistCurrentQueue() else {
            queue.removeAll { $0 == id }
            if var record = records[id] {
                record.state = .failed
                record.failureDescription = "transfer queue persistence write failed"
                record.settled = true
                records[id] = record
            }
            outcomes[id] = .failure("transfer queue persistence write failed")
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
        guard executionEnabled, currentPersistenceStatus != .writeFailed else { return nil }
        return Set(records.values.map(\.localFileAccessURL))
    }

    public func persistenceStatus() -> AsyncTransferQueuePersistenceStatus {
        persistenceStore != nil && !executionEnabled ? .writeFailed : currentPersistenceStatus
    }

    public func managedUploadResumeRecordURL(transferID: String) -> URL? {
        persistenceStore?.managedUploadResumeRecordURL(transferID: transferID)
    }

    /// Retries the full atomic manifest write after a previous storage failure.
    /// A queued job remains stopped until its queued-to-active snapshot is also
    /// committed successfully.
    @discardableResult
    public func retryPersistence() -> Bool { retryPersistence(startQueuedJobs: true) }

    @discardableResult
    package func retryPersistence(startQueuedJobs: Bool) -> Bool {
        guard acceptsSubmissions, persistenceStore != nil else { return false }
        if !startQueuedJobs { executionEnabled = false }
        if requiresPersistenceReload {
            do {
                try reloadPersistence()
                requiresPersistenceReload = false
                currentPersistenceStatus = .healthy
            } catch {
                currentPersistenceStatus = .writeFailed
                return holdExecutionAfterPersistenceFailure()
            }
        } else if !persistCurrentQueue() {
            return holdExecutionAfterPersistenceFailure()
        }
        guard startQueuedJobs else {
            broadcastSnapshots()
            return currentPersistenceStatus == .healthy
        }
        return activateExecutionAfterPersistence()
    }

    @discardableResult
    package func activateExecution() -> Bool {
        guard acceptsSubmissions, persistenceStore != nil, !requiresPersistenceReload, persistCurrentQueue() else {
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
        return startedCleanly && currentPersistenceStatus == .healthy
    }

    /// Emits an immediate full snapshot followed by every queue state change.
    public func updates() -> AsyncStream<[AsyncTransferJobSnapshot]> {
        let observerID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[observerID] = continuation
            continuation.yield(orderedSnapshots())
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
        let activeIDs = records.values
            .filter { !$0.state.isTerminal }
            .map(\.id)
        for id in activeIDs {
            guard var record = records[id] else { continue }
            queue.removeAll { $0 == id }
            record.state = .cancelled
            record.retryDelayMilliseconds = nil
            records[id] = record
            stopRateExpiry(id: id)

            if let task = runningTasks[id] {
                task.cancel()
            } else {
                record.settled = true
                records[id] = record
                finishWaiters(id: id, outcome: .cancelled)
            }
        }

        _ = persistCurrentQueue()
        broadcastSnapshots()

        // Product coordinators are cancellation-cooperative and close their
        // private RPC client in every error path. Waiting here makes forward
        // release a strict happens-after boundary for file I/O and retries.
        let tasks = activeIDs.compactMap { runningTasks[$0] }
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
        queue.removeAll()
        let activeTasks = runningTasks
        for id in Array(records.keys) {
            guard var record = records[id], !record.state.isTerminal else { continue }
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
                    let outcome = AsyncTransferJobOutcome.failure(
                        AsyncTransferSchedulerPolicy.interruptedFailureDescription
                    )
                    outcomes[id] = outcome
                    finishWaiters(id: id, outcome: outcome)
                }
                activeTasks[id]?.cancel()
            case .pausing:
                activeTasks[id]?.cancel()
            case .paused, .interrupted, .completed, .failed, .cancelled:
                break
            }
            record.retryDelayMilliseconds = nil
            record.rateEstimator.reset()
            record.rateSampleGeneration &+= 1
            records[id] = record
            stopRateExpiry(id: id)
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
        if let outcome = outcomes[id] {
            return outcome
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
    }

    /// Holds queued work, or closes a running coordinator after it has emitted a
    /// trusted durable checkpoint. The coordinator owns an exclusive TCP session,
    /// so cancellation tears down only this job while retaining its sidecar/partial.
    @discardableResult
    public func pause(_ id: UUID) -> Bool {
        guard acceptsSubmissions, var record = records[id] else { return false }
        let previousRecord = record

        if record.state == .queued {
            let previousQueue = queue
            queue.removeAll { $0 == id }
            record.state = .paused
            record.pauseRequiresResume = false
            records[id] = record
            guard persistCurrentQueue() else {
                records[id] = previousRecord
                queue = previousQueue
                broadcastSnapshots()
                return false
            }
            _ = startJobsIfPossible()
            broadcastSnapshots()
            return true
        }

        guard record.canPause else {
            return false
        }
        // retrying means the displayed attempt has not started yet; running means
        // the current attempt has already consumed its attempt number.
        record.resumeAttemptBase = record.state == .retrying
            ? max(0, record.attemptNumber - 1)
            : record.attemptNumber
        record.pauseRequiresResume = true
        record.state = .pausing
        record.retryDelayMilliseconds = nil
        record.failureDescription = nil
        records[id] = record
        guard persistCurrentQueue() else {
            records[id] = previousRecord
            broadcastSnapshots()
            return false
        }
        stopRateExpiry(id: id)
        runningTasks[id]?.cancel()
        broadcastSnapshots()
        return true
    }

    /// Requeues a paused job at the FIFO tail. A job that had started is rebuilt
    /// as an explicit resume request while preserving its transfer identity.
    @discardableResult
    public func resume(_ id: UUID) -> Bool {
        guard acceptsSubmissions, var record = records[id], record.state == .paused else {
            return false
        }
        let previousRecord = record
        let previousQueue = queue
        if record.pauseRequiresResume {
            record.request = AsyncTransferSchedulerPolicy.resumedRequest(record.request)
            record.attemptBase = record.resumeAttemptBase ?? record.attemptNumber
            record.attemptNumber = record.attemptBase + 1
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
        guard persistCurrentQueue() else {
            records[id] = previousRecord
            queue = previousQueue
            broadcastSnapshots()
            return false
        }
        _ = startJobsIfPossible()
        broadcastSnapshots()
        return true
    }

    /// Cancels queued/paused work immediately or requests cancellation of an
    /// active coordinator.
    /// Returns false for unknown or already-terminal jobs.
    @discardableResult
    public func cancel(_ id: UUID) -> Bool {
        guard acceptsSubmissions, var record = records[id], !record.state.isTerminal else {
            return false
        }
        let previousRecord = record
        let previousQueue = queue
        if record.state == .queued || record.state == .paused {
            queue.removeAll { $0 == id }
            record.state = .cancelled
            record.retryDelayMilliseconds = nil
            record.settled = true
            records[id] = record
            guard persistCurrentQueue() else {
                records[id] = previousRecord
                queue = previousQueue
                broadcastSnapshots()
                return false
            }
            finishWaiters(id: id, outcome: .cancelled)
            _ = startJobsIfPossible()
        } else {
            record.state = .cancelled
            record.retryDelayMilliseconds = nil
            records[id] = record
            guard persistCurrentQueue() else {
                records[id] = previousRecord
                broadcastSnapshots()
                return false
            }
            runningTasks[id]?.cancel()
        }
        stopRateExpiry(id: id)
        broadcastSnapshots()
        return true
    }

    /// Removes terminal history after consumers no longer need it.
    @discardableResult
    public func remove(_ id: UUID) -> Bool {
        guard acceptsSubmissions, let record = records[id],
              record.canRemove,
              outcomes[id] != nil,
              runningTasks[id] == nil else {
            return false
        }
        let previousOutcome = outcomes[id]
        assert(waiters[id]?.isEmpty ?? true, "settled jobs cannot retain waiters")
        records.removeValue(forKey: id)
        outcomes.removeValue(forKey: id)
        waiters.removeValue(forKey: id)
        guard persistCurrentQueue() else {
            records[id] = record
            outcomes[id] = previousOutcome
            broadcastSnapshots()
            return false
        }
        stopRateExpiry(id: id)
        broadcastSnapshots()
        return true
    }

    @discardableResult
    private func startJobsIfPossible() -> Bool {
        guard executionEnabled else { return true }
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
              record.state == .running || record.state == .retrying else {
            return
        }
        record.state = .retrying
        record.attemptNumber = record.attemptBase + retryAttempt + 1
        record.retryDelayMilliseconds = delayMilliseconds
        record.failureDescription = AsyncTransferFailureLabel.label(for: error)
        record.rateEstimator.reset()
        record.rateSampleGeneration &+= 1
        records[id] = record
        _ = persistCurrentQueue()
        stopRateExpiry(id: id)
        broadcastSnapshots()
    }

    private func markProgress(id: UUID, progress: AsyncTransferProgress) {
        guard var record = records[id],
              record.state == .running || record.state == .retrying,
              progress.totalBytes >= 0,
              progress.confirmedBytes >= record.confirmedBytes,
              progress.confirmedBytes <= progress.totalBytes,
              record.totalBytes == nil || record.totalBytes == progress.totalBytes else {
            return
        }
        record.confirmedBytes = progress.confirmedBytes
        record.totalBytes = progress.totalBytes
        let acceptedRateSample = record.rateEstimator.record(
            confirmedBytes: progress.confirmedBytes,
            at: monotonicNow()
        )
        if acceptedRateSample {
            record.rateSampleGeneration &+= 1
        }
        if record.state == .retrying {
            record.state = .running
            record.retryDelayMilliseconds = nil
            record.failureDescription = nil
        }
        let rateGeneration = record.rateSampleGeneration
        let hasRecentRate = record.rateEstimator.bytesPerSecond != nil
        records[id] = record
        if acceptedRateSample {
            updateRateExpiry(
                id: id,
                generation: rateGeneration,
                hasRecentRate: hasRecentRate
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
        // Pause is authoritative even if an injected/non-cooperative executor
        // returns a result after Task.cancel(). Completion waiters deliberately
        // remain pending across the pause/resume boundary.
        if record.state == .pausing {
            record.state = .paused
            record.retryDelayMilliseconds = nil
            record.failureDescription = nil
            record.rateEstimator.reset()
            record.rateSampleGeneration &+= 1
            records[id] = record
            _ = persistCurrentQueue()
            stopRateExpiry(id: id)
            _ = startJobsIfPossible()
            broadcastSnapshots()
            return
        }
        // Session suspension already published and persisted this conservative
        // terminal state. A cancelled executor must not erase it while unwinding.
        if record.state == .interrupted {
            _ = persistCurrentQueue()
            _ = startJobsIfPossible()
            broadcastSnapshots()
            return
        }
        let finalOutcome = AsyncTransferSchedulerPolicy.applyTerminalOutcome(
            outcome,
            to: &record,
            at: monotonicNow()
        )
        records[id] = record
        _ = persistCurrentQueue()
        // Running samples expire automatically, but a terminal transition
        // freezes any still-valid value for result/diagnostics presentation.
        stopRateExpiry(id: id)
        finishWaiters(id: id, outcome: finalOutcome)
        _ = startJobsIfPossible()
        broadcastSnapshots()
    }

    private func finishWaiters(id: UUID, outcome: AsyncTransferJobOutcome) {
        outcomes[id] = outcome
        let continuations = waiters.removeValue(forKey: id) ?? []
        for continuation in continuations {
            continuation.resume(returning: outcome)
        }
    }

    private func restoreFromPersistence(startQueuedJobs: Bool) {
        guard persistenceStore != nil else { return }
        precondition(records.isEmpty, "a scheduler can restore persistence only once")
        executionEnabled = startQueuedJobs
        do {
            try reloadPersistence()
            currentPersistenceStatus = .healthy
        } catch {
            // Do not expose partial restored state or overwrite an unreadable
            // archive. Explicit retry must reload durable state from scratch.
            records = [:]
            queue = []
            outcomes = [:]
            nextSequence = 0
            currentPersistenceStatus = .writeFailed
            requiresPersistenceReload = true
            broadcastSnapshots()
            return
        }
        _ = startJobsIfPossible()
        broadcastSnapshots()
    }

    private func reloadPersistence() throws {
        guard let persistenceStore else { return }
        let manifest = try persistenceStore.load()
        let restored = try AsyncTransferSchedulerPersistence.restore(manifest)
        // Canonicalize active records before any queued executor is allowed to
        // start, and publish only after that durable write succeeds.
        try persistenceStore.save(
            try AsyncTransferSchedulerPersistence.manifest(for: restored.records)
        )
        records = restored.records
        queue = restored.queue
        outcomes = restored.outcomes
        nextSequence = restored.nextSequence
    }

    @discardableResult
    private func persistCurrentQueue() -> Bool {
        guard let persistenceStore else {
            currentPersistenceStatus = .disabled
            return true
        }
        guard !requiresPersistenceReload else {
            currentPersistenceStatus = .writeFailed
            return false
        }
        do {
            try persistenceStore.save(try AsyncTransferSchedulerPersistence.manifest(for: records))
            currentPersistenceStatus = .healthy
            return true
        } catch {
            // Store errors are deliberately reduced to a stable status. The
            // underlying message may contain an absolute local path.
            currentPersistenceStatus = .writeFailed
            return false
        }
    }

    private func orderedSnapshots() -> [AsyncTransferJobSnapshot] {
        records.values
            .sorted { $0.sequence < $1.sequence }
            .map(\.snapshot)
    }

    private func broadcastSnapshots() {
        let current = orderedSnapshots()
        for continuation in observers.values {
            continuation.yield(current)
        }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func updateRateExpiry(
        id: UUID,
        generation: UInt64,
        hasRecentRate: Bool
    ) {
        stopRateExpiry(id: id)
        guard hasRecentRate else { return }
        let sleeper = rateExpirySleeper
        rateExpiryTasks[id] = Task { [weak self] in
            do {
                try await sleeper(AsyncTransferRateEstimator.defaultWindowNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.expireRecentRate(id: id, generation: generation)
        }
    }

    private func stopRateExpiry(id: UUID) { rateExpiryTasks.removeValue(forKey: id)?.cancel() }

    private func expireRecentRate(id: UUID, generation: UInt64) {
        guard var record = records[id],
              record.state == .running,
              record.rateSampleGeneration == generation,
              record.rateEstimator.bytesPerSecond != nil else {
            return
        }
        record.rateEstimator.reset()
        record.rateSampleGeneration &+= 1
        records[id] = record
        rateExpiryTasks.removeValue(forKey: id)
        broadcastSnapshots()
    }

}
