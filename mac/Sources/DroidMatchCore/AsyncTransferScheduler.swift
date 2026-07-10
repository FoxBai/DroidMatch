import Foundation
import Dispatch

public enum AsyncTransferJobKind: String, Sendable, Equatable {
    case download
    case upload
}

public enum AsyncTransferJobRequest: Sendable {
    case download(AsyncDownloadCoordinatorRequest)
    case upload(AsyncUploadCoordinatorRequest)
}

public enum AsyncTransferJobState: String, Sendable, Equatable {
    case queued
    case running
    case retrying
    case pausing
    case paused
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

public struct AsyncTransferJobSnapshot: Sendable, Equatable {
    public let id: UUID
    public let kind: AsyncTransferJobKind
    public let state: AsyncTransferJobState
    public let source: String
    public let destination: String
    public let attemptNumber: Int
    public let confirmedBytes: Int64
    public let totalBytes: Int64?
    /// Time-weighted rate over the most recent receiver-confirmed intervals.
    /// It is nil until two valid samples exist and is reset for every retry.
    public let recentBytesPerSecond: Double?
    public let retryDelayMilliseconds: Int64?
    public let failureDescription: String?
    /// Whether the scheduler can accept a pause request in this state.
    /// A queued job is only held; a running job requires a durable checkpoint.
    public let canPause: Bool
    /// Pausing is asynchronous while the coordinator closes its private session.
    public let canResume: Bool
    /// Cancellation remains available until the job reaches a terminal state.
    public let canCancel: Bool
    /// Removal is safe only after the terminal outcome and task unwind settle.
    public let canRemove: Bool

    public init(
        id: UUID,
        kind: AsyncTransferJobKind,
        state: AsyncTransferJobState,
        source: String,
        destination: String,
        attemptNumber: Int,
        confirmedBytes: Int64,
        totalBytes: Int64?,
        recentBytesPerSecond: Double?,
        retryDelayMilliseconds: Int64?,
        failureDescription: String?,
        canPause: Bool,
        canResume: Bool,
        canCancel: Bool,
        canRemove: Bool
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.source = source
        self.destination = destination
        self.attemptNumber = attemptNumber
        self.confirmedBytes = confirmedBytes
        self.totalBytes = totalBytes
        self.recentBytesPerSecond = recentBytesPerSecond
        self.retryDelayMilliseconds = retryDelayMilliseconds
        self.failureDescription = failureDescription
        self.canPause = canPause
        self.canResume = canResume
        self.canCancel = canCancel
        self.canRemove = canRemove
    }

    /// Completion state disambiguates a valid empty transfer from a running
    /// transfer whose total is still unknown.
    public var fractionCompleted: Double? {
        if state == .completed { return 1 }
        guard let totalBytes, totalBytes > 0 else { return nil }
        return Double(confirmedBytes) / Double(totalBytes)
    }
}

public enum AsyncTransferJobResult: Sendable {
    case download(AsyncDownloadCoordinatorResult)
    case upload(AsyncUploadCoordinatorResult)
}

public enum AsyncTransferJobOutcome: Sendable {
    case success(AsyncTransferJobResult)
    case failure(String)
    case cancelled
}

public enum AsyncTransferSchedulerError: Error, CustomStringConvertible, Sendable, Equatable {
    case unknownJob(UUID)

    public var description: String {
        switch self {
        case let .unknownJob(id):
            return "transfer scheduler has no job \(id)"
        }
    }
}

public typealias AsyncTransferRetryObserver = @Sendable (
    _ retryAttempt: Int,
    _ delayMilliseconds: Int64,
    _ error: Error
) -> Void

typealias AsyncDownloadJobExecutor = @Sendable (
    AsyncDownloadCoordinatorRequest,
    AsyncTransferRetryObserver?,
    AsyncTransferProgressObserver?
) async throws -> AsyncDownloadCoordinatorResult

typealias AsyncUploadJobExecutor = @Sendable (
    AsyncUploadCoordinatorRequest,
    AsyncTransferRetryObserver?,
    AsyncTransferProgressObserver?
) async throws -> AsyncUploadCoordinatorResult

typealias AsyncTransferMonotonicNow = @Sendable () -> UInt64
typealias AsyncTransferRateExpirySleeper = @Sendable (UInt64) async throws -> Void

/// Bridges the recovery executor's synchronous retry callback into the
/// scheduler actor without allowing a later progress/final event to overtake it.
private final class AsyncTransferSchedulerRetryRelay: @unchecked Sendable {
    private let tail = LockedValue<Task<Void, Never>?>(nil)

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        tail.update { current in
            let previous = current
            current = Task {
                await previous?.value
                await operation()
            }
        }
    }

    func drain() async {
        await tail.value()?.value
    }
}

/// Process-local product transfer queue.
///
/// The scheduler exposes state snapshots suitable for a future SwiftUI/AppKit
/// binding, while coordinators continue to own protocol, sidecar, and file-I/O
/// invariants. It deliberately does not persist queued intent across app restarts.
public actor AsyncTransferScheduler {
    private struct JobRecord {
        let id: UUID
        let sequence: UInt64
        var request: AsyncTransferJobRequest
        let kind: AsyncTransferJobKind
        let source: String
        let destination: String
        let supportsCheckpointPause: Bool
        var state: AsyncTransferJobState = .queued
        var attemptNumber = 1
        /// Attempts completed or started before the current coordinator invocation.
        var attemptBase = 0
        var resumeAttemptBase: Int?
        var pauseRequiresResume = false
        var confirmedBytes: Int64 = 0
        var totalBytes: Int64?
        var rateEstimator = AsyncTransferRateEstimator()
        var rateSampleGeneration: UInt64 = 0
        var retryDelayMilliseconds: Int64?
        var failureDescription: String?
        /// A terminal state can become visible before a cancelled task finishes
        /// unwinding. Keep removal disabled until its outcome is authoritative.
        var settled = false

        var canPause: Bool {
            if state == .queued { return true }
            guard (state == .running || state == .retrying),
                  supportsCheckpointPause,
                  let totalBytes else {
                return false
            }
            // Coordinators emit 100% only after final validation, commit, and
            // sidecar cleanup. That narrow pre-finish window is no longer resumable.
            return confirmedBytes < totalBytes
        }

        var canRemove: Bool {
            state.isTerminal && settled
        }

        var snapshot: AsyncTransferJobSnapshot {
            AsyncTransferJobSnapshot(
                id: id,
                kind: kind,
                state: state,
                source: source,
                destination: destination,
                attemptNumber: attemptNumber,
                confirmedBytes: confirmedBytes,
                totalBytes: totalBytes,
                recentBytesPerSecond: rateEstimator.bytesPerSecond,
                retryDelayMilliseconds: retryDelayMilliseconds,
                failureDescription: failureDescription,
                canPause: canPause,
                canResume: state == .paused,
                canCancel: !state.isTerminal,
                canRemove: canRemove
            )
        }
    }

    private let maxConcurrentJobs: Int
    private let downloadExecutor: AsyncDownloadJobExecutor
    private let uploadExecutor: AsyncUploadJobExecutor
    private let monotonicNow: AsyncTransferMonotonicNow
    private let rateExpirySleeper: AsyncTransferRateExpirySleeper

    private var nextSequence: UInt64 = 0
    private var records: [UUID: JobRecord] = [:]
    private var queue: [UUID] = []
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var rateExpiryTasks: [UUID: Task<Void, Never>] = [:]
    private var outcomes: [UUID: AsyncTransferJobOutcome] = [:]
    private var waiters: [UUID: [CheckedContinuation<AsyncTransferJobOutcome, Error>]] = [:]
    private var observers: [UUID: AsyncStream<[AsyncTransferJobSnapshot]>.Continuation] = [:]

    public init(
        downloadCoordinator: AsyncDownloadCoordinator,
        uploadCoordinator: AsyncUploadCoordinator,
        maxConcurrentJobs: Int = 2
    ) {
        precondition(maxConcurrentJobs > 0, "maxConcurrentJobs must be positive")
        self.maxConcurrentJobs = maxConcurrentJobs
        self.monotonicNow = { DispatchTime.now().uptimeNanoseconds }
        self.rateExpirySleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
        self.downloadExecutor = { request, retryObserver, progressObserver in
            try await downloadCoordinator.download(
                request,
                onRetry: retryObserver,
                onProgress: progressObserver
            )
        }
        self.uploadExecutor = { request, retryObserver, progressObserver in
            try await uploadCoordinator.upload(
                request,
                onRetry: retryObserver,
                onProgress: progressObserver
            )
        }
    }

    init(
        maxConcurrentJobs: Int,
        downloadExecutor: @escaping AsyncDownloadJobExecutor,
        uploadExecutor: @escaping AsyncUploadJobExecutor,
        monotonicNow: @escaping AsyncTransferMonotonicNow = {
            DispatchTime.now().uptimeNanoseconds
        },
        rateExpirySleeper: @escaping AsyncTransferRateExpirySleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        precondition(maxConcurrentJobs > 0, "maxConcurrentJobs must be positive")
        self.maxConcurrentJobs = maxConcurrentJobs
        self.downloadExecutor = downloadExecutor
        self.uploadExecutor = uploadExecutor
        self.monotonicNow = monotonicNow
        self.rateExpirySleeper = rateExpirySleeper
    }

    @discardableResult
    public func submit(_ request: AsyncTransferJobRequest) -> UUID {
        let id = UUID()
        let metadata = Self.metadata(for: request)
        records[id] = JobRecord(
            id: id,
            sequence: nextSequence,
            request: request,
            kind: metadata.kind,
            source: metadata.source,
            destination: metadata.destination,
            supportsCheckpointPause: Self.supportsCheckpointPause(request)
        )
        nextSequence &+= 1
        queue.append(id)
        startJobsIfPossible()
        broadcastSnapshots()
        return id
    }

    public func snapshot(for id: UUID) throws -> AsyncTransferJobSnapshot {
        guard let record = records[id] else {
            throw AsyncTransferSchedulerError.unknownJob(id)
        }
        return record.snapshot
    }

    public func snapshots() -> [AsyncTransferJobSnapshot] {
        orderedSnapshots()
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
        guard var record = records[id] else { return false }

        if record.state == .queued {
            queue.removeAll { $0 == id }
            record.state = .paused
            record.pauseRequiresResume = false
            records[id] = record
            startJobsIfPossible()
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
        stopRateExpiry(id: id)
        runningTasks[id]?.cancel()
        broadcastSnapshots()
        return true
    }

    /// Requeues a paused job at the FIFO tail. A job that had started is rebuilt
    /// as an explicit resume request while preserving its transfer identity.
    @discardableResult
    public func resume(_ id: UUID) -> Bool {
        guard var record = records[id], record.state == .paused else {
            return false
        }
        if record.pauseRequiresResume {
            record.request = Self.resumedRequest(record.request)
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
        startJobsIfPossible()
        broadcastSnapshots()
        return true
    }

    /// Cancels queued/paused work immediately or requests cancellation of an
    /// active coordinator.
    /// Returns false for unknown or already-terminal jobs.
    @discardableResult
    public func cancel(_ id: UUID) -> Bool {
        guard var record = records[id], !record.state.isTerminal else {
            return false
        }
        if record.state == .queued || record.state == .paused {
            queue.removeAll { $0 == id }
            record.state = .cancelled
            record.retryDelayMilliseconds = nil
            record.settled = true
            records[id] = record
            finishWaiters(id: id, outcome: .cancelled)
            startJobsIfPossible()
        } else {
            record.state = .cancelled
            record.retryDelayMilliseconds = nil
            records[id] = record
            runningTasks[id]?.cancel()
        }
        stopRateExpiry(id: id)
        broadcastSnapshots()
        return true
    }

    /// Removes terminal history after consumers no longer need it.
    @discardableResult
    public func remove(_ id: UUID) -> Bool {
        guard let record = records[id],
              record.canRemove,
              outcomes[id] != nil,
              runningTasks[id] == nil else {
            return false
        }
        records.removeValue(forKey: id)
        outcomes.removeValue(forKey: id)
        waiters.removeValue(forKey: id)
        stopRateExpiry(id: id)
        broadcastSnapshots()
        return true
    }

    private func startJobsIfPossible() {
        while runningTasks.count < maxConcurrentJobs, !queue.isEmpty {
            let id = queue.removeFirst()
            guard var record = records[id], record.state == .queued else {
                continue
            }
            record.state = .running
            records[id] = record
            let request = record.request
            let task = Task { [weak self] in
                guard let self else { return }
                await self.execute(id: id, request: request)
            }
            runningTasks[id] = task
        }
    }

    private func execute(id: UUID, request: AsyncTransferJobRequest) async {
        let retryRelay = AsyncTransferSchedulerRetryRelay()
        let retryObserver: AsyncTransferRetryObserver = { [weak self] retry, delay, error in
            guard let scheduler = self else { return }
            retryRelay.enqueue { [weak scheduler] in
                await scheduler?.markRetry(
                    id: id,
                    retryAttempt: retry,
                    delayMilliseconds: delay,
                    error: error
                )
            }
        }
        let progressObserver: AsyncTransferProgressObserver = { [weak self] progress in
            await retryRelay.drain()
            await self?.markProgress(id: id, progress: progress)
        }

        do {
            let result: AsyncTransferJobResult
            switch request {
            case let .download(downloadRequest):
                result = .download(try await downloadExecutor(
                    downloadRequest,
                    retryObserver,
                    progressObserver
                ))
            case let .upload(uploadRequest):
                result = .upload(try await uploadExecutor(
                    uploadRequest,
                    retryObserver,
                    progressObserver
                ))
            }
            await retryRelay.drain()
            finish(id: id, outcome: .success(result))
        } catch is CancellationError {
            await retryRelay.drain()
            finish(id: id, outcome: .cancelled)
        } catch {
            await retryRelay.drain()
            finish(id: id, outcome: .failure(String(describing: error)))
        }
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
        record.failureDescription = String(describing: error)
        record.rateEstimator.reset()
        record.rateSampleGeneration &+= 1
        records[id] = record
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
            startJobsIfPossible()
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
            stopRateExpiry(id: id)
            startJobsIfPossible()
            broadcastSnapshots()
            return
        }
        // Cancellation is authoritative even if an injected/non-cooperative
        // executor returns success while unwinding after Task.cancel().
        let finalOutcome: AsyncTransferJobOutcome = record.state == .cancelled
            ? .cancelled
            : outcome
        switch finalOutcome {
        case let .success(result):
            record.state = .completed
            record.retryDelayMilliseconds = nil
            record.failureDescription = nil
            switch result {
            case let .download(value):
                record.attemptNumber = record.attemptBase + value.attemptCount
                // Coordinators normally emitted the final checkpoint already;
                // this result calibration intentionally tolerates a duplicate.
                _ = record.rateEstimator.record(
                    confirmedBytes: value.download.finalOffsetBytes,
                    at: monotonicNow()
                )
                record.confirmedBytes = value.download.finalOffsetBytes
                record.totalBytes = value.download.openResponse.totalSizeBytes
            case let .upload(value):
                record.attemptNumber = record.attemptBase + value.attemptCount
                _ = record.rateEstimator.record(
                    confirmedBytes: value.upload.finalOffsetBytes,
                    at: monotonicNow()
                )
                record.confirmedBytes = value.upload.finalOffsetBytes
                record.totalBytes = value.upload.openResponse.totalSizeBytes
            }
        case let .failure(description):
            record.state = .failed
            record.retryDelayMilliseconds = nil
            record.failureDescription = description
        case .cancelled:
            record.state = .cancelled
            record.retryDelayMilliseconds = nil
        }
        record.settled = true
        records[id] = record
        // Running samples expire automatically, but a terminal transition
        // freezes any still-valid value for result/diagnostics presentation.
        stopRateExpiry(id: id)
        finishWaiters(id: id, outcome: finalOutcome)
        startJobsIfPossible()
        broadcastSnapshots()
    }

    private func finishWaiters(id: UUID, outcome: AsyncTransferJobOutcome) {
        outcomes[id] = outcome
        let continuations = waiters.removeValue(forKey: id) ?? []
        for continuation in continuations {
            continuation.resume(returning: outcome)
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

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

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

    private func stopRateExpiry(id: UUID) {
        rateExpiryTasks.removeValue(forKey: id)?.cancel()
    }

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

    private static func metadata(
        for request: AsyncTransferJobRequest
    ) -> (kind: AsyncTransferJobKind, source: String, destination: String) {
        switch request {
        case let .download(value):
            return (.download, value.sourcePath, value.destinationURL.path)
        case let .upload(value):
            return (.upload, value.sourceURL.path, value.destinationPath)
        }
    }

    private static func supportsCheckpointPause(
        _ request: AsyncTransferJobRequest
    ) -> Bool {
        switch request {
        case .download:
            return true
        case let .upload(value):
            return value.destinationSupportsResume
        }
    }

    private static func resumedRequest(
        _ request: AsyncTransferJobRequest
    ) -> AsyncTransferJobRequest {
        switch request {
        case let .download(value):
            return .download(AsyncDownloadCoordinatorRequest(
                sourcePath: value.sourcePath,
                destinationURL: value.destinationURL,
                resume: true,
                freshTransferID: value.freshTransferID,
                preferredChunkSizeBytes: value.preferredChunkSizeBytes,
                recoveryPolicy: value.recoveryPolicy
            ))
        case let .upload(value):
            return .upload(AsyncUploadCoordinatorRequest(
                sourceURL: value.sourceURL,
                destinationPath: value.destinationPath,
                resume: true,
                freshTransferID: value.freshTransferID,
                preferredChunkSizeBytes: value.preferredChunkSizeBytes,
                recoveryPolicy: value.recoveryPolicy
            ))
        }
    }
}
