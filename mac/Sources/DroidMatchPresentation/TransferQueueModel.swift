import Combine
import DroidMatchCore
import Foundation

public struct CompletedTransferRemovalResult: Equatable, Sendable {
    public let requestedCount: Int
    public let removedCount: Int

    public init(requestedCount: Int, removedCount: Int) {
        self.requestedCount = requestedCount
        self.removedCount = removedCount
    }

    public var isComplete: Bool {
        requestedCount > 0 && removedCount == requestedCount
    }
}

/// Identifies one accepted request without retaining its local or remote path.
/// The caller can reconcile its own immutable input while Presentation exposes
/// no filename-bearing batch result.
public struct TransferQueueDownloadAdmission: Equatable, Sendable {
    public let requestIndex: Int
    public let jobID: UUID
}

/// Main-actor state boundary used by the SwiftUI product transfer queue.
///
/// Observation is explicit so an owning scene/controller can align it with its
/// lifecycle. Stopping retains the last value to avoid UI flicker; restarting
/// opens a fresh full-snapshot stream. Core updates remain authoritative, so
/// actions never mutate `items` optimistically.
@MainActor
public final class TransferQueueModel: ObservableObject {
    @Published public private(set) var items: [TransferQueuePresentationItem] = []
    @Published public private(set) var isObserving = false
    @Published public private(set) var persistenceStatus:
        AsyncTransferQueuePersistenceStatus = .disabled
    @Published public private(set) var isPersistenceStatusKnown = false
    @Published public private(set) var isRetryingPersistence = false
    @Published public private(set) var pendingActionIDs = Set<UUID>()
    @Published public private(set) var isClearingCompleted = false
    @Published public private(set) var isSubmittingTransfer = false

    private let dataSource: any TransferQueueDataSource
    private var observationTask: Task<Void, Never>?
    private var observationGeneration: UInt64 = 0
    private var persistenceReadGeneration: UInt64 = 0

    public init(dataSource: any TransferQueueDataSource) {
        self.dataSource = dataSource
    }

    public convenience init(scheduler: AsyncTransferScheduler) {
        self.init(dataSource: AsyncTransferSchedulerDataSource(scheduler: scheduler))
    }

    public var completedRemovalCount: Int {
        items.lazy.filter {
            $0.state == .completed
                && $0.canRemove
                && !self.pendingActionIDs.contains($0.id)
        }.count
    }

    /// Product entry points may open long-lived native panels before enqueueing.
    /// Expose the complete control-plane admission state so they can fail before
    /// collecting user input when recovery storage is unhealthy, being repaired,
    /// or mutated by a bulk cleanup. Accepted jobs still execute independently.
    public var canSubmitTransfers: Bool {
        persistenceStatus != .writeFailed
            && !isRetryingPersistence
            && !isClearingCompleted
            && !isSubmittingTransfer
    }

    /// Native product panels stay closed until the first authoritative status
    /// read. The `.disabled` enum value is a valid process-local scheduler mode,
    /// so readiness must be tracked separately from that value.
    public var canPresentTransferSubmission: Bool {
        isPersistenceStatusKnown && canSubmitTransfers
    }

    /// Queue mutations cross the same durable recovery boundary as submission.
    /// Pause, resume, cancel, and removal therefore stay closed until the first
    /// authoritative status read and while a failed store is being repaired.
    /// A concurrent submission or an unrelated row action may still proceed.
    public var canPerformQueueActions: Bool {
        isPersistenceStatusKnown
            && persistenceStatus != .writeFailed
            && !isRetryingPersistence
    }

    public func isActionPending(_ id: UUID) -> Bool {
        pendingActionIDs.contains(id)
    }

    deinit {
        observationTask?.cancel()
    }

    /// Starts one subscription. Repeated starts are intentionally idempotent.
    public func start() {
        guard observationTask == nil else { return }
        observationGeneration &+= 1
        let generation = observationGeneration
        let dataSource = dataSource
        isObserving = true
        observationTask = Task { [weak self] in
            let updates = await dataSource.updates()
            for await snapshots in updates {
                guard !Task.isCancelled else { break }
                guard let self else { return }
                let persistenceReadGeneration = self.beginPersistenceRead()
                let persistenceStatus = await dataSource.persistenceStatus()
                self.apply(
                    snapshots,
                    persistenceStatus: persistenceStatus,
                    persistenceReadGeneration: persistenceReadGeneration,
                    generation: generation
                )
            }
            guard !Task.isCancelled else { return }
            self?.finishObservation(generation: generation)
        }
    }

    /// Cancels the current stream but deliberately keeps the last UI snapshot.
    public func stop() {
        observationGeneration &+= 1
        observationTask?.cancel()
        observationTask = nil
        isObserving = false
    }

    /// Submits only a validated product download. The data-source boundary owns
    /// recovery policy and Core request construction, while AppKit owns the
    /// user-authorized destination URL.
    @discardableResult
    public func submitDownload(
        sourcePath: String,
        destinationURL: URL,
        authorizationURL: URL? = nil
    ) async -> UUID? {
        guard beginTransferSubmission() else { return nil }
        defer { finishTransferSubmission() }
        return await submitDownloadUncoordinated(
            sourcePath: sourcePath,
            destinationURL: destinationURL,
            authorizationURL: authorizationURL
        )
    }

    /// Submits one local file to the currently authorized Android directory.
    /// Core validates the provider path and selects a resume policy that cannot
    /// replay fresh-only MediaStore creation.
    @discardableResult
    public func submitUpload(sourceURL: URL, directoryPath: String) async -> UUID? {
        guard isValidUpload(sourceURL, directoryPath: directoryPath),
              beginTransferSubmission() else { return nil }
        defer { finishTransferSubmission() }
        return await submitUploadUncoordinated(
            sourceURL: sourceURL, directoryPath: directoryPath
        )
    }

    /// Submits a deterministic batch without inventing an all-or-nothing
    /// guarantee over independent persisted scheduler jobs.
    public func submitUploads(sourceURLs: [URL], directoryPath: String) async -> [UUID] {
        guard beginTransferSubmission() else { return [] }
        defer { finishTransferSubmission() }
        var submitted: [UUID] = []
        for sourceURL in sourceURLs where isValidUpload(sourceURL, directoryPath: directoryPath) {
            if let id = await submitUploadUncoordinated(
                sourceURL: sourceURL, directoryPath: directoryPath
            ) {
                submitted.append(id)
            }
        }
        return submitted
    }

    /// Submits independently recoverable downloads in caller-defined order.
    public func submitDownloads(
        _ requests: [(sourcePath: String, destinationURL: URL)],
        authorizationURL: URL? = nil
    ) async -> [TransferQueueDownloadAdmission] {
        guard beginTransferSubmission() else { return [] }
        defer { finishTransferSubmission() }
        var submitted: [TransferQueueDownloadAdmission] = []
        for (requestIndex, request) in requests.enumerated() {
            if let id = await submitDownloadUncoordinated(
                sourcePath: request.sourcePath,
                destinationURL: request.destinationURL,
                authorizationURL: authorizationURL
            ) {
                submitted.append(TransferQueueDownloadAdmission(
                    requestIndex: requestIndex,
                    jobID: id
                ))
            }
        }
        return submitted
    }

    @discardableResult
    public func pause(_ id: UUID) async -> Bool {
        await performAction(id) { await dataSource.pause(id) }
    }

    @discardableResult
    public func resume(_ id: UUID) async -> Bool {
        await performAction(id) { await dataSource.resume(id) }
    }

    @discardableResult
    public func cancel(_ id: UUID) async -> Bool {
        await performAction(id) { await dataSource.cancel(id) }
    }

    @discardableResult
    public func remove(_ id: UUID) async -> Bool {
        await performAction(id) { await dataSource.remove(id) }
    }

    /// Removes only successful, fully settled rows in their authoritative queue
    /// order. Failed, cancelled, interrupted, and still-unwinding rows remain
    /// visible so a convenience cleanup cannot hide work that needs attention.
    /// Each data-source removal keeps its existing independent persistence and
    /// bookmark-orphan cleanup boundary; no all-or-nothing claim is made.
    @discardableResult
    public func clearCompleted() async -> CompletedTransferRemovalResult? {
        guard canPerformQueueActions,
              !isSubmittingTransfer,
              !isClearingCompleted else {
            return nil
        }
        let ids = items.compactMap { item in
            item.state == .completed
                && item.canRemove
                && !pendingActionIDs.contains(item.id)
                ? item.id
                : nil
        }
        guard !ids.isEmpty else { return nil }

        isClearingCompleted = true
        pendingActionIDs.formUnion(ids)
        defer {
            pendingActionIDs.subtract(ids)
            isClearingCompleted = false
        }

        var removedCount = 0
        for id in ids {
            if await dataSource.remove(id) {
                removedCount += 1
            }
        }
        await reloadPersistenceStatus()
        return CompletedTransferRemovalResult(
            requestedCount: ids.count,
            removedCount: removedCount
        )
    }

    /// Retries the Core-owned manifest write and then reloads authoritative
    /// health. The UI never assumes a successful write from the button tap.
    @discardableResult
    public func retryPersistence() async -> Bool {
        guard persistenceStatus == .writeFailed,
              !isSubmittingTransfer,
              !isClearingCompleted,
              !isRetryingPersistence else {
            return false
        }
        isRetryingPersistence = true
        defer { isRetryingPersistence = false }
        let succeeded = await dataSource.retryPersistence()
        await reloadPersistenceStatus()
        return succeeded
    }

    private func beginTransferSubmission() -> Bool {
        guard canSubmitTransfers else { return false }
        isSubmittingTransfer = true
        return true
    }

    private func finishTransferSubmission() {
        isSubmittingTransfer = false
    }

    private func submitDownloadUncoordinated(
        sourcePath: String,
        destinationURL: URL,
        authorizationURL: URL?
    ) async -> UUID? {
        let id = await dataSource.submitDownload(
            sourcePath: sourcePath,
            destinationURL: destinationURL,
            authorizationURL: authorizationURL
        )
        // Bookmark registration can fail before Core enqueues a job, so no
        // scheduler snapshot is guaranteed to wake the observation stream.
        // Reload health after every submission instead of hiding the retry UI.
        await reloadPersistenceStatus()
        return id
    }

    private func submitUploadUncoordinated(
        sourceURL: URL,
        directoryPath: String
    ) async -> UUID? {
        let id = await dataSource.submitUpload(
            sourceURL: sourceURL,
            directoryPath: directoryPath
        )
        await reloadPersistenceStatus()
        return id
    }

    private func isValidUpload(_ sourceURL: URL, directoryPath: String) -> Bool {
        sourceURL.isFileURL && ProductUploadDestination(
            directoryPath: directoryPath,
            fileName: sourceURL.lastPathComponent
        ) != nil
    }

    private func reloadPersistenceStatus() async {
        let generation = beginPersistenceRead()
        let status = await dataSource.persistenceStatus()
        guard generation == persistenceReadGeneration else { return }
        persistenceStatus = status
        isPersistenceStatusKnown = true
    }

    private func performAction(
        _ id: UUID,
        action: () async -> Bool
    ) async -> Bool {
        guard canPerformQueueActions,
              !pendingActionIDs.contains(id) else { return false }
        pendingActionIDs.insert(id)
        defer { pendingActionIDs.remove(id) }
        let succeeded = await action()
        // Bookmark orphan cleanup happens after Core publishes removal, and any
        // mutation can expose a manifest failure without another queue update.
        await reloadPersistenceStatus()
        return succeeded
    }

    private func beginPersistenceRead() -> UInt64 {
        persistenceReadGeneration &+= 1
        return persistenceReadGeneration
    }

    private func apply(
        _ snapshots: [AsyncTransferJobSnapshot],
        persistenceStatus: AsyncTransferQueuePersistenceStatus,
        persistenceReadGeneration: UInt64,
        generation: UInt64
    ) {
        guard generation == observationGeneration else { return }
        items = snapshots.map(TransferQueuePresentationItem.init(snapshot:))
        guard persistenceReadGeneration == self.persistenceReadGeneration else {
            return
        }
        self.persistenceStatus = persistenceStatus
        isPersistenceStatusKnown = true
    }

    private func finishObservation(generation: UInt64) {
        guard generation == observationGeneration else { return }
        observationTask = nil
        isObserving = false
    }
}
