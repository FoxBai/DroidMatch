import DroidMatchCore
import Foundation

/// Testable action and snapshot seam between native presentation state and Core.
///
/// Snapshot values contain Core-owned paths. Consumers should bind UI through
/// `TransferQueueModel`, whose item mapping removes Mac absolute paths.
public protocol TransferQueueDataSource: Sendable {
    func updates() async -> AsyncStream<[AsyncTransferJobSnapshot]>
    func persistenceStatus() async -> AsyncTransferQueuePersistenceStatus
    func retryPersistence() async -> Bool
    func submitDownload(
        sourcePath: String,
        destinationURL: URL,
        authorizationURL: URL?
    ) async -> UUID?
    func submitUpload(sourceURL: URL, directoryPath: String) async -> UUID?
    func pause(_ id: UUID) async -> Bool
    func resume(_ id: UUID) async -> Bool
    func cancel(_ id: UUID) async -> Bool
    func remove(_ id: UUID) async -> Bool
}

/// Thin adapter that preserves `AsyncTransferScheduler` as the only authority
/// for ordering, lifecycle transitions, retry state, and action admission.
public struct AsyncTransferSchedulerDataSource: TransferQueueDataSource, Sendable {
    private let scheduler: AsyncTransferScheduler

    public init(scheduler: AsyncTransferScheduler) {
        self.scheduler = scheduler
    }

    public func updates() async -> AsyncStream<[AsyncTransferJobSnapshot]> {
        await scheduler.updates()
    }

    public func persistenceStatus() async -> AsyncTransferQueuePersistenceStatus {
        await scheduler.persistenceStatus()
    }

    public func retryPersistence() async -> Bool {
        await scheduler.retryPersistence()
    }

    public func submitDownload(
        sourcePath: String,
        destinationURL: URL,
        authorizationURL: URL?
    ) async -> UUID? {
        _ = authorizationURL
        guard sourcePath.hasPrefix("dm://"),
              sourcePath.count > "dm://".count,
              destinationURL.isFileURL,
              !destinationURL.path.isEmpty else {
            return nil
        }
        return await scheduler.submit(.download(AsyncDownloadCoordinatorRequest(
            sourcePath: sourcePath,
            destinationURL: destinationURL,
            recoveryPolicy: .defaultSingleRetry
        )))
    }

    public func submitUpload(sourceURL: URL, directoryPath: String) async -> UUID? {
        guard sourceURL.isFileURL,
              !sourceURL.path.isEmpty,
              let destination = ProductUploadDestination(
                  directoryPath: directoryPath,
                  fileName: sourceURL.lastPathComponent
              ) else {
            return nil
        }
        return await scheduler.submit(.upload(AsyncUploadCoordinatorRequest(
            sourceURL: sourceURL,
            destinationPath: destination.path,
            recoveryPolicy: destination.supportsResume
                ? .defaultSingleRetry
                : .disabled
        )))
    }

    public func pause(_ id: UUID) async -> Bool {
        await scheduler.pause(id)
    }

    public func resume(_ id: UUID) async -> Bool {
        await scheduler.resume(id)
    }

    public func cancel(_ id: UUID) async -> Bool {
        await scheduler.cancel(id)
    }

    public func remove(_ id: UUID) async -> Bool {
        await scheduler.remove(id)
    }
}
