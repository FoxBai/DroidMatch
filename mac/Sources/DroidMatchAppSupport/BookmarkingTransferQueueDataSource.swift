import DroidMatchCore
import DroidMatchPresentation
import Foundation

/// App-layer adapter that commits file authorization before Core can enqueue
/// work, then removes orphaned bookmark records with queue history.
public struct BookmarkingTransferQueueDataSource: TransferQueueDataSource, Sendable {
    private let scheduler: AsyncTransferScheduler
    private let store: SecurityScopedBookmarkStore?
    private let operationGate = BookmarkingTransferQueueOperationGate()

    public init(scheduler: AsyncTransferScheduler, store: SecurityScopedBookmarkStore?) {
        self.scheduler = scheduler
        self.store = store
    }

    public func updates() async -> AsyncStream<[AsyncTransferJobSnapshot]> {
        guard await operationGate.acquire() else {
            return AsyncStream { $0.finish() }
        }
        if let store,
           let targets = await scheduler.authoritativeLocalFileAccessURLs() {
            try? await store.retainOnly(targetURLs: targets)
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
        guard let store else { return .writeFailed }
        let requiredTargets = await requiredLocalTargetsWhileLocked()
        guard await store.isReadyForTransferExecution(targetURLs: requiredTargets) else {
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
        guard let store else { return false }
        guard await store.retryPersistence() else { return false }
        guard await scheduler.retryPersistence(startQueuedJobs: false) else { return false }
        let requiredTargets = await requiredLocalTargetsWhileLocked()
        guard await store.isReadyForTransferExecution(targetURLs: requiredTargets) else {
            return false
        }
        do {
            // A failed removal rolls the registry back after the scheduler row
            // is already gone. Reconcile again here so a successful retry
            // cannot report healthy while retaining that orphaned authority.
            let targets = Set(await scheduler.snapshots().map(Self.localURL))
            try await store.retainOnly(targetURLs: targets)
            return await scheduler.activateExecution()
        } catch {
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
              let store else {
            return nil
        }
        do {
            try await store.register(
                targetURL: destinationURL,
                authorizationURL: authorizationURL
                    ?? destinationURL.deletingLastPathComponent()
            )
        } catch {
            return nil
        }
        return await scheduler.submit(.download(AsyncDownloadCoordinatorRequest(
            sourcePath: sourcePath,
            destinationURL: destinationURL,
            recoveryPolicy: .defaultSingleRetry
        )))
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
              let store else {
            return nil
        }
        do {
            try await store.register(targetURL: sourceURL, authorizationURL: sourceURL)
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
        guard let snapshot = try? await scheduler.snapshot(for: id),
              await scheduler.remove(id) else {
            return false
        }
        if let store {
            let target = Self.localURL(snapshot)
            let stillUsed = await scheduler.snapshots().contains {
                Self.localURL($0).standardizedFileURL == target.standardizedFileURL
            }
            if !stillUsed {
                try? await store.remove(targetURL: target)
            }
        }
        return true
    }

    private static func localURL(_ snapshot: AsyncTransferJobSnapshot) -> URL {
        URL(fileURLWithPath: snapshot.kind == .download
            ? snapshot.destination
            : snapshot.source)
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
