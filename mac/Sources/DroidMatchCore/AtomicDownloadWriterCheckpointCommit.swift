import Foundation

extension AtomicDownloadWriter {
    /// Publishes while retaining the old destination until checkpoint cleanup
    /// succeeds. A failure rolls the namespace back while keeping the commit
    /// marker, republishes the checkpoint, and only then retires that marker.
    /// This is the synchronous harness equivalent of the async product finalizer.
    package func commitCoordinatingCheckpoint(
        removeCheckpoint: () throws -> Void,
        restoreCheckpoint: () throws -> Void
    ) throws {
        try commit(retainRecoveryMarker: true)
        do {
            try removeCheckpoint()
            try finalizeCommit()
        } catch {
            let completionError = error
            do {
                try rollbackCommit(retainRecoveryMarker: true)
            } catch {
                throw AtomicDownloadWriterError.commitUncertain
            }
            do {
                try restoreCheckpoint()
            } catch {
                throw AtomicDownloadWriterError.checkpointRestoreFailed
            }
            try finalizeRollback()
            throw completionError
        }
    }
}
