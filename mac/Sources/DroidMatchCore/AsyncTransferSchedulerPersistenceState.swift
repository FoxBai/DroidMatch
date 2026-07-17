import Foundation

/// Actor-confined persistence I/O and coarse health for one scheduler.
///
/// This value never owns live queue records: callers pass a snapshot to save
/// and apply the immutable restored result themselves. A failed reload keeps
/// the latch closed so no later write can overwrite unreadable recovery data.
struct AsyncTransferSchedulerPersistenceState {
    private let store: TransferQueuePersistenceStore?
    private(set) var status: AsyncTransferQueuePersistenceStatus
    private(set) var requiresReload = false

    init(store: TransferQueuePersistenceStore?) {
        self.store = store
        self.status = store == nil ? .disabled : .healthy
    }

    var isEnabled: Bool { store != nil }

    func effectiveStatus(executionEnabled: Bool) -> AsyncTransferQueuePersistenceStatus {
        isEnabled && !executionEnabled ? .writeFailed : status
    }

    func managedUploadResumeRecordURL(transferID: String) -> URL? {
        store?.managedUploadResumeRecordURL(transferID: transferID)
    }

    func productRestorePlan() throws -> ProductTransferRestorePlan {
        guard let store else {
            throw TransferQueuePersistenceStoreError.ioFailure
        }
        return try store.productRestorePlan()
    }

    /// Records a manifest load failure already observed by the product restore
    /// transaction without reading the same untrusted archive a second time.
    mutating func markReloadRequired() {
        guard store != nil else { return }
        status = .writeFailed
        requiresReload = true
    }

    mutating func save(
        records: [UUID: AsyncTransferSchedulerJobRecord]
    ) -> Bool {
        guard let store else {
            status = .disabled
            return true
        }
        guard !requiresReload else {
            status = .writeFailed
            return false
        }
        do {
            let manifest = try AsyncTransferSchedulerPersistence.manifest(for: records)
            try store.save(manifest)
            status = .healthy
            return true
        } catch {
            // Store errors may contain an absolute local path. Only the stable
            // health state crosses this boundary.
            status = .writeFailed
            return false
        }
    }

    mutating func reload(
        manifest suppliedManifest: PersistedTransferQueue? = nil,
        downloadDirectoryContexts: [String: LocalDownloadDirectoryContext] = [:]
    ) throws -> AsyncTransferSchedulerPersistence.RestoredState {
        guard let store else {
            throw TransferQueuePersistenceStoreError.ioFailure
        }
        do {
            let manifest = try suppliedManifest ?? store.load()
            let restored = try AsyncTransferSchedulerPersistence.restore(
                manifest,
                downloadDirectoryContexts: downloadDirectoryContexts
            )
            // Canonicalization is durable before the actor publishes any row or
            // starts an executor, preserving the write-ahead recovery boundary.
            try store.save(try AsyncTransferSchedulerPersistence.manifest(
                for: restored.records
            ))
            status = .healthy
            requiresReload = false
            return restored
        } catch {
            status = .writeFailed
            requiresReload = true
            throw error
        }
    }
}
