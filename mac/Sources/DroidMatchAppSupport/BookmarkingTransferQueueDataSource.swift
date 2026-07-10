import DroidMatchCore
import DroidMatchPresentation
import Foundation

/// App-layer adapter that commits file authorization before Core can enqueue
/// work, then removes orphaned bookmark records with queue history.
public struct BookmarkingTransferQueueDataSource: TransferQueueDataSource, Sendable {
    private let scheduler: AsyncTransferScheduler
    private let store: SecurityScopedBookmarkStore?

    public init(scheduler: AsyncTransferScheduler, store: SecurityScopedBookmarkStore?) {
        self.scheduler = scheduler
        self.store = store
    }

    public func updates() async -> AsyncStream<[AsyncTransferJobSnapshot]> {
        if let store {
            let targets = Set(await scheduler.snapshots().map(Self.localURL))
            try? await store.retainOnly(targetURLs: targets)
        }
        return await scheduler.updates()
    }

    public func persistenceStatus() async -> AsyncTransferQueuePersistenceStatus {
        guard store != nil else { return .writeFailed }
        return await scheduler.persistenceStatus()
    }

    public func submitDownload(sourcePath: String, destinationURL: URL) async -> UUID? {
        guard sourcePath.hasPrefix("dm://"),
              sourcePath.count > "dm://".count,
              destinationURL.isFileURL,
              !destinationURL.path.isEmpty,
              let store else {
            return nil
        }
        do {
            try await store.register(
                targetURL: destinationURL,
                authorizationURL: destinationURL.deletingLastPathComponent()
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
        guard sourceURL.isFileURL,
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
        return await scheduler.submit(.upload(AsyncUploadCoordinatorRequest(
            sourceURL: sourceURL,
            destinationPath: destination.path,
            recoveryPolicy: destination.supportsResume ? .defaultSingleRetry : .disabled
        )))
    }

    public func pause(_ id: UUID) async -> Bool { await scheduler.pause(id) }
    public func resume(_ id: UUID) async -> Bool { await scheduler.resume(id) }
    public func cancel(_ id: UUID) async -> Bool { await scheduler.cancel(id) }

    public func remove(_ id: UUID) async -> Bool {
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

public struct UnavailableLocalFileAccessProvider: LocalFileAccessProviding {
    public init() {}

    public func acquireAccess(to url: URL) async throws -> any LocalFileAccessLease {
        _ = url
        throw SecurityScopedBookmarkStoreError.unavailable
    }
}
