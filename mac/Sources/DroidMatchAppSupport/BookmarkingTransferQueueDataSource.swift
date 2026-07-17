@_spi(DroidMatchAppSupport) import DroidMatchCore
import DroidMatchPresentation
import Foundation

/// App-layer adapter that commits file authorization before Core can enqueue
/// work, then removes orphaned bookmark records with queue history.
public struct BookmarkingTransferQueueDataSource: TransferQueueDataSource, Sendable {
    private let scheduler: AsyncTransferScheduler
    private let store: SecurityScopedBookmarkStore?
    private let ownerID: LocalFileAccessOwnerID?
    private let operationGate: BookmarkingTransferQueueOperationGate

    init(
        scheduler: AsyncTransferScheduler,
        store: SecurityScopedBookmarkStore?,
        operationGate: BookmarkingTransferQueueOperationGate
    ) {
        self.scheduler = scheduler
        self.store = store
        self.ownerID = scheduler.localFileAccessOwnerID
        self.operationGate = operationGate
    }

    public func updates() async -> AsyncStream<[AsyncTransferJobSnapshot]> {
        guard await operationGate.acquire() else {
            return AsyncStream { $0.finish() }
        }
        if let store,
           let ownerID,
           let targets = await scheduler.authoritativeLocalFileAccessURLs() {
            try? await store.retainOnly(owner: ownerID, targetURLs: targets)
        }
        let updates = await scheduler.updates()
        await operationGate.release()
        return updates
    }

    public func persistenceStatus() async -> AsyncTransferQueuePersistenceStatus {
        guard await operationGate.acquire() else { return .writeFailed }
        let status = await persistenceStatusWhileLocked()
        await operationGate.release()
        return status
    }

    private func persistenceStatusWhileLocked() async -> AsyncTransferQueuePersistenceStatus {
        guard let store, let ownerID else { return .writeFailed }
        let requiredTargets = await requiredLocalTargetsWhileLocked()
        guard await store.isReadyForTransferExecution(
            owner: ownerID,
            targetURLs: requiredTargets
        ) else {
            return .writeFailed
        }
        return await scheduler.persistenceStatus()
    }

    private func requiredLocalTargetsWhileLocked() async -> Set<URL> {
        await scheduler.requiredLocalFileAccessURLs()
    }

    public func retryPersistence() async -> Bool {
        guard await operationGate.acquire() else { return false }
        let succeeded = await retryPersistenceWhileLocked()
        await operationGate.release()
        return succeeded
    }

    private func retryPersistenceWhileLocked() async -> Bool {
        guard let store, let ownerID else { return false }
        guard await store.retryPersistence() else { return false }
        var productRestoreRequiresRetry = false
        do {
            let preparation: BookmarkingTransferRestorePreparation?
            if let restorePlan = try await scheduler.productRestorePlanIfReloadRequired() {
                productRestoreRequiresRetry = true
                preparation = try await BookmarkingTransferRestorePreparation.prepare(
                    plan: restorePlan,
                    store: store,
                    ownerID: ownerID
                )
            } else {
                preparation = nil
            }
            defer { preparation?.release() }

            let persisted: Bool
            if let preparation {
                persisted = await scheduler.retryProductRestore(
                    preparation.plan,
                    downloadDirectoryContexts: preparation.downloadDirectoryContexts
                )
            } else {
                persisted = await scheduler.retryPersistence(startQueuedJobs: false)
            }
            guard persisted else {
                if productRestoreRequiresRetry {
                    await scheduler.requireProductRestoreRetry()
                }
                return false
            }

            let requiredTargets = await requiredLocalTargetsWhileLocked()
            guard await store.isReadyForTransferExecution(
                owner: ownerID,
                targetURLs: requiredTargets
            ) else {
                if productRestoreRequiresRetry {
                    await scheduler.requireProductRestoreRetry()
                }
                return false
            }
            // A failed removal rolls the registry back after the scheduler row
            // is already gone. Reconcile again here so a successful retry
            // cannot report healthy while retaining that orphaned authority.
            let targets = Set(await scheduler.snapshots().map(Self.localURL))
            try await store.retainOnly(owner: ownerID, targetURLs: targets)
            let activated = await scheduler.activateExecution()
            if !activated, productRestoreRequiresRetry {
                await scheduler.requireProductRestoreRetry()
            }
            return activated
        } catch {
            if productRestoreRequiresRetry {
                await scheduler.requireProductRestoreRetry()
            }
            return false
        }
    }

    public func submitDownload(
        sourcePath: String,
        destinationURL: URL,
        authorizationURL: URL?
    ) async -> UUID? {
        guard await operationGate.acquire() else { return nil }
        let id = await submitDownloadWhileLocked(
            sourcePath: sourcePath,
            destinationURL: destinationURL,
            authorizationURL: authorizationURL
        )
        await operationGate.release()
        return id
    }

    private func submitDownloadWhileLocked(
        sourcePath: String,
        destinationURL: URL,
        authorizationURL: URL?
    ) async -> UUID? {
        guard await persistenceStatusWhileLocked() != .writeFailed,
              sourcePath.hasPrefix("dm://"),
              sourcePath.count > "dm://".count,
              destinationURL.isFileURL,
              !destinationURL.path.isEmpty,
              let store,
              let ownerID else {
            return nil
        }
        let request = AsyncTransferJobRequest.download(
            AsyncDownloadCoordinatorRequest(
                sourcePath: sourcePath,
                destinationURL: destinationURL,
                recoveryPolicy: .defaultSingleRetry
            )
        )
        do {
            // Reject known conflicts before creating bookmark bytes. The
            // atomic submit rechecks after registration; re-registering the
            // same owner/target key is idempotent if another submit wins.
            try await scheduler.validateSubmission(request)
            try await store.register(
                owner: ownerID,
                targetURL: destinationURL,
                authorizationURL: authorizationURL
                    ?? destinationURL.deletingLastPathComponent()
            )
            return try await scheduler.submitValidated(request)
        } catch {
            try? await pruneBookmarkRegistryWhileLocked(store: store, ownerID: ownerID)
            return nil
        }
    }

    private func pruneBookmarkRegistryWhileLocked(
        store: SecurityScopedBookmarkStore,
        ownerID: LocalFileAccessOwnerID
    ) async throws {
        let retained = Set(await scheduler.snapshots().map(Self.localURL))
        try await store.retainOnly(owner: ownerID, targetURLs: retained)
    }

    public func submitUpload(sourceURL: URL, directoryPath: String) async -> UUID? {
        guard await operationGate.acquire() else { return nil }
        let id = await submitUploadWhileLocked(
            sourceURL: sourceURL,
            directoryPath: directoryPath
        )
        await operationGate.release()
        return id
    }

    private func submitUploadWhileLocked(
        sourceURL: URL,
        directoryPath: String
    ) async -> UUID? {
        guard await persistenceStatusWhileLocked() != .writeFailed,
              sourceURL.isFileURL,
              !sourceURL.path.isEmpty,
              let destination = ProductUploadDestination(
                  directoryPath: directoryPath,
                  fileName: sourceURL.lastPathComponent
              ),
              let store,
              let ownerID else {
            return nil
        }
        do {
            try await store.register(
                owner: ownerID,
                targetURL: sourceURL,
                authorizationURL: sourceURL
            )
        } catch {
            return nil
        }
        let transferID = UUID().uuidString
        let resumeRecordURL = destination.supportsResume
            ? await scheduler.managedUploadResumeRecordURL(transferID: transferID)
            : nil
        return await scheduler.submit(.upload(AsyncUploadCoordinatorRequest(
            sourceURL: sourceURL,
            destinationPath: destination.path,
            freshTransferID: transferID,
            recoveryPolicy: destination.supportsResume ? .defaultSingleRetry : .disabled,
            resumeRecordURL: resumeRecordURL
        )))
    }

    public func pause(_ id: UUID) async -> Bool { await scheduler.pause(id) }

    public func resume(_ id: UUID) async -> Bool {
        guard await operationGate.acquire() else { return false }
        let succeeded: Bool
        if await persistenceStatusWhileLocked() == .writeFailed {
            succeeded = false
        } else {
            succeeded = await scheduler.resume(id)
        }
        await operationGate.release()
        return succeeded
    }

    public func cancel(_ id: UUID) async -> Bool { await scheduler.cancel(id) }

    public func remove(_ id: UUID) async -> Bool {
        guard await operationGate.acquire() else { return false }
        let succeeded = await removeWhileLocked(id)
        await operationGate.release()
        return succeeded
    }

    private func removeWhileLocked(_ id: UUID) async -> Bool {
        guard let store,
              let ownerID,
              let snapshot = try? await scheduler.snapshot(for: id),
              await scheduler.remove(id) else {
            return false
        }
        let target = Self.localURL(snapshot)
        let stillUsed = await scheduler.snapshots().contains {
            Self.localURL($0).standardizedFileURL == target.standardizedFileURL
        }
        if stillUsed {
            watchForDeferredRemoval(id: id, target: target, store: store, ownerID: ownerID)
        } else {
            try? await store.remove(owner: ownerID, targetURL: target)
        }
        return true
    }

    /// Remote partial cleanup may make a terminal removal asynchronous. Keep
    /// the source bookmark until Core forgets the row, then prune it under the
    /// same cross-queue gate used by ordinary registration and removal.
    private func watchForDeferredRemoval(
        id: UUID,
        target: URL,
        store: SecurityScopedBookmarkStore,
        ownerID: LocalFileAccessOwnerID
    ) {
        Task {
            let updates = await scheduler.updates()
            for await snapshots in updates {
                guard snapshots.allSatisfy({ $0.id != id }) else { continue }
                guard await operationGate.acquire() else { return }
                let stillUsed = await scheduler.snapshots().contains {
                    Self.localURL($0).standardizedFileURL
                        == target.standardizedFileURL
                }
                if !stillUsed {
                    try? await store.remove(owner: ownerID, targetURL: target)
                }
                await operationGate.release()
                return
            }
        }
    }

    private static func localURL(_ snapshot: AsyncTransferJobSnapshot) -> URL {
        URL(fileURLWithPath: snapshot.kind == .download
            ? snapshot.destination
            : snapshot.source)
    }
}

private struct BookmarkingTransferRestorePreparation: Sendable {
    let plan: ProductTransferRestorePlan
    let downloadDirectoryContexts: [String: LocalDownloadDirectoryContext]
    private let accessLeases: [any LocalFileAccessLease]

    static func prepare(
        plan: ProductTransferRestorePlan,
        store: SecurityScopedBookmarkStore,
        ownerID: LocalFileAccessOwnerID
    ) async throws -> Self {
        var leases: [any LocalFileAccessLease] = []
        var contexts: [String: LocalDownloadDirectoryContext] = [:]
        do {
            for target in plan.checkpointAccessTargets.sorted(by: targetSortsBefore) {
                let lease = try await store.acquireAccess(owner: ownerID, to: target.url)
                leases.append(lease)
                if case let .download(destinationURL) = target {
                    contexts[destinationURL.standardizedFileURL.path] = try
                        DownloadDestinationReservation.contextForRestore(
                            destinationURL: destinationURL,
                            accessLease: lease
                        )
                }
            }
            return Self(
                plan: plan,
                downloadDirectoryContexts: contexts,
                accessLeases: leases
            )
        } catch {
            for lease in leases.reversed() { lease.release() }
            throw error
        }
    }

    func release() {
        for lease in accessLeases.reversed() { lease.release() }
    }

    private static func targetSortsBefore(
        _ lhs: TransferRestoreAccessTarget,
        _ rhs: TransferRestoreAccessTarget
    ) -> Bool {
        let lhsPath = lhs.url.standardizedFileURL.path
        let rhsPath = rhs.url.standardizedFileURL.path
        if lhsPath != rhsPath { return lhsPath < rhsPath }
        if case .download = lhs, case .upload = rhs { return true }
        return false
    }
}

/// Serializes only bookmark/manifest consistency transitions, not transfer I/O.
///
/// Actor methods are otherwise reentrant at each cross-actor await. Holding this
/// logical FIFO permit closes the register-before-enqueue window so retry pruning
/// cannot remove authority belonging to a submission that is still in flight.
actor BookmarkingTransferQueueOperationGate {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isHeld = false
    private var nextWaiterID: UInt64 = 0
    private var waiters: [Waiter] = []

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if !isHeld {
            isHeld = true
            return true
        }
        let id = nextWaiterID
        nextWaiterID &+= 1
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
        if acquired, Task.isCancelled {
            release()
            return false
        }
        return acquired
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

public struct UnavailableLocalFileAccessProvider: LocalFileAccessProviding {
    public init() {}

    public func isReadyForTransferExecution() async -> Bool { false }

    public func acquireAccess(to url: URL) async throws -> any LocalFileAccessLease {
        _ = url
        throw SecurityScopedBookmarkStoreError.unavailable
    }
}
