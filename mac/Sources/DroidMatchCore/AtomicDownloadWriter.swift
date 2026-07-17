import Darwin
import Foundation

public final class AtomicDownloadWriter {
    public let destinationURL: URL
    public let partialURL: URL
    public let requestedOffsetBytes: Int64

    private let destinationName: String
    private let partialName: String
    private let expectedDirectoryIdentity: LocalDirectoryIdentity?
    private let directoryContext: LocalDownloadDirectoryContext?
    private var initialDestinationMetadata: stat?
    private var directoryDescriptor: Int32?
    /// A dup of the output's open-file description retains `flock` after the
    /// output handle closes and until the atomic rename has completed.
    private var lockDescriptor: Int32?
    private var output: FileHandle?
    private var freshResetRequired: Bool
    private var commitMarkerMetadata: stat?
    private var commitPublication: AtomicDownloadCommitTransaction.Publication?
    private var awaitingCommitFinalization = false
    private var awaitingRollbackFinalization = false

    package convenience init(
        destinationURL: URL,
        resume: Bool,
        fileManager: FileManager = .default
    ) throws {
        try self.init(
            destinationURL: destinationURL,
            resume: resume,
            deferFreshReset: false,
            expectedDirectoryIdentity: nil,
            directoryContext: nil,
            fileManager: fileManager
        )
    }

    package init(
        destinationURL: URL,
        resume: Bool,
        deferFreshReset: Bool,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil,
        fileManager _: FileManager = .default
    ) throws {
        self.destinationURL = destinationURL
        self.partialURL = Self.partialURL(for: destinationURL)
        self.destinationName = destinationURL.lastPathComponent
        self.partialName = self.partialURL.lastPathComponent
        self.expectedDirectoryIdentity = expectedDirectoryIdentity
        self.directoryContext = directoryContext
        self.freshResetRequired = !resume

        guard !destinationName.isEmpty,
              destinationName != ".",
              destinationName != "..",
              !partialName.isEmpty else {
            throw AtomicDownloadWriterError.invalidDestination
        }

        // Pin the authorized directory for the writer lifetime. `openat` and
        // `renameat` below cannot be redirected by replacing its path while a
        // transfer is active. 中文：用目录描述符固定已授权目录，避免传输期间路径被替换。
        let directoryDescriptor = try AtomicDownloadPartialFile.openDirectory(
            destinationURL.deletingLastPathComponent(),
            createIntermediateDirectories: true,
            expectedIdentity: expectedDirectoryIdentity,
            directoryContext: directoryContext
        )
        do {
            try AtomicDownloadCommitTransaction.requireNoRecoveryEntries(
                directoryDescriptor: directoryDescriptor,
                destinationName: destinationName
            )
            let destinationMetadata = try AtomicDownloadPartialFile.metadata(
                directoryDescriptor: directoryDescriptor,
                name: destinationName
            )
            if let destinationMetadata,
               destinationMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                throw AtomicDownloadWriterError.invalidDestination
            }
            initialDestinationMetadata = destinationMetadata
            let partialDescriptors = try AtomicDownloadPartialFile.open(
                directoryDescriptor: directoryDescriptor,
                partialName: partialName
            )
            let output = FileHandle(
                fileDescriptor: partialDescriptors.output,
                closeOnDealloc: true
            )
            do {
                let sizeBytes = try AtomicDownloadPartialFile.regularFileSize(
                    descriptor: partialDescriptors.output
                )
                let requestedOffsetBytes = resume ? sizeBytes : 0
                try output.seek(toOffset: UInt64(requestedOffsetBytes))

                self.requestedOffsetBytes = requestedOffsetBytes
                self.directoryDescriptor = directoryDescriptor
                self.lockDescriptor = partialDescriptors.lock
                self.output = output
                if !resume, !deferFreshReset {
                    try resetFresh()
                }
            } catch {
                try? output.close()
                Darwin.close(partialDescriptors.lock)
                throw error
            }
        } catch {
            Darwin.close(directoryDescriptor)
            throw error
        }
    }

    deinit {
        try? close()
    }

    package func write(_ data: Data) throws {
        guard let output, !freshResetRequired else {
            throw AtomicDownloadWriterError.closed
        }
        try output.write(contentsOf: data)
    }

    package func commit() throws {
        try commit(retainRecoveryMarker: false)
    }

    package func commit(retainRecoveryMarker: Bool) throws {
        guard let output, let lockDescriptor,
              let directoryDescriptor, !freshResetRequired else {
            throw AtomicDownloadWriterError.closed
        }
        do {
            // Sync the complete partial before making its name visible as the
            // destination. The directory-entry swap itself remains atomic.
            try output.synchronize()
            try closeOutput()
            let lockedPartial = try AtomicDownloadPartialFile.regularFileMetadata(
                descriptor: lockDescriptor
            )
            guard let namedPartial = try AtomicDownloadPartialFile.metadata(
                directoryDescriptor: directoryDescriptor,
                name: partialName
            ), AtomicDownloadPartialFile.sameFile(namedPartial, lockedPartial) else {
                throw AtomicDownloadWriterError.destinationBusy
            }
            let currentDestination = try AtomicDownloadPartialFile.metadata(
                directoryDescriptor: directoryDescriptor,
                name: destinationName
            )
            guard AtomicDownloadPartialFile.sameOptionalEntrySnapshot(
                currentDestination,
                initialDestinationMetadata
            ) else {
                throw AtomicDownloadWriterError.destinationChanged
            }
            // Path-based callers recheck after the potentially long file sync.
            // Capability-backed product calls intentionally keep targeting the
            // same authorized directory object if Finder renames it.
            try validateCurrentDirectoryIdentity()

            commitMarkerMetadata = try AtomicDownloadCommitTransaction.createCommitMarker(
                directoryDescriptor: directoryDescriptor,
                destinationName: destinationName
            )
            commitPublication = try AtomicDownloadCommitTransaction.publish(
                directoryDescriptor: directoryDescriptor,
                partialName: partialName,
                destinationName: destinationName,
                lockedPartial: lockedPartial,
                initialDestination: initialDestinationMetadata
            )
            // Publication has already committed once the verified rename/swap
            // returns. A late directory-sync failure cannot be reported as an
            // ordinary retryable failure because the destination is visible.
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw AtomicDownloadWriterError.commitUncertain
            }
            if retainRecoveryMarker {
                awaitingCommitFinalization = true
            } else {
                try finalizeCommitPublication()
            }
        } catch {
            let finalError: Error
            if commitPublication != nil {
                do {
                    try rollbackCommitPublication()
                    finalError = error
                } catch {
                    finalError = AtomicDownloadWriterError.commitUncertain
                }
            } else if commitMarkerMetadata != nil,
                      error as? AtomicDownloadWriterError != .commitUncertain {
                do {
                    try removeCommitMarker()
                    finalError = error
                } catch {
                    finalError = AtomicDownloadWriterError.commitUncertain
                }
            } else {
                finalError = error
            }
            try? closeOutput()
            closeLock()
            closeDirectory()
            throw finalError
        }
    }

    /// Retires the durable commit marker only after the coordinator has
    /// removed the matching resume sidecar. Until then, a process crash must
    /// restore this job as interrupted instead of treating the displaced old
    /// destination as resumable bytes.
    package func finalizeCommit() throws {
        guard awaitingCommitFinalization else {
            throw AtomicDownloadWriterError.closed
        }
        do {
            try finalizeCommitPublication()
        } catch {
            closeLock()
            closeDirectory()
            throw error
        }
    }

    /// Restores the pre-transfer destination and moves the fully received
    /// candidate back to the partial name. This remains possible until final
    /// sidecar cleanup authorizes deletion of the displaced old destination.
    package func rollbackCommit(retainRecoveryMarker: Bool = false) throws {
        guard awaitingCommitFinalization else {
            throw AtomicDownloadWriterError.closed
        }
        do {
            try rollbackCommitPublication(
                retainRecoveryMarker: retainRecoveryMarker
            )
        } catch {
            closeLock()
            closeDirectory()
            throw error
        }
    }

    /// Retires a marker kept across rollback only after its checkpoint is
    /// durable again. A crash before this call therefore remains an explicit
    /// interrupted transaction instead of an unmarked orphan partial.
    package func finalizeRollback() throws {
        guard awaitingRollbackFinalization else {
            throw AtomicDownloadWriterError.closed
        }
        do {
            try removeCommitMarker()
            awaitingRollbackFinalization = false
            closeLock()
            closeDirectory()
        } catch {
            closeLock()
            closeDirectory()
            throw AtomicDownloadWriterError.commitUncertain
        }
    }

    /// Aborts this writer while preserving its partial for a later resume.
    /// Output, inode lock, and pinned-directory descriptors are all released.
    package func close() throws {
        defer {
            closeLock()
            closeDirectory()
        }
        try closeOutput()
    }

    /// Clears a fresh transfer only after its owner has safely retired the old
    /// sidecar. Deferred reset lets the coordinator acquire the partial inode
    /// lock before any recovery artifact is mutated.
    package func resetFresh() throws {
        guard freshResetRequired, let output, let lockDescriptor,
              let directoryDescriptor else {
            throw AtomicDownloadWriterError.closed
        }
        try validateCurrentDirectoryIdentity()
        let locked = try AtomicDownloadPartialFile.regularFileMetadata(
            descriptor: lockDescriptor
        )
        guard let current = try AtomicDownloadPartialFile.metadata(
            directoryDescriptor: directoryDescriptor,
            name: partialName
        ), AtomicDownloadPartialFile.sameFile(current, locked) else {
            throw AtomicDownloadWriterError.destinationBusy
        }
        guard Darwin.ftruncate(lockDescriptor, 0) == 0 else {
            throw AtomicDownloadPartialFile.currentPOSIXError()
        }
        try output.seek(toOffset: 0)
        guard let truncated = try AtomicDownloadPartialFile.metadata(
            directoryDescriptor: directoryDescriptor,
            name: partialName
        ), AtomicDownloadPartialFile.sameFile(truncated, locked),
              truncated.st_size == 0 else {
            throw AtomicDownloadWriterError.destinationBusy
        }
        freshResetRequired = false
    }

    private func closeOutput() throws {
        guard let output else {
            return
        }
        self.output = nil
        try output.close()
    }

    public static func partialURL(for destinationURL: URL) -> URL {
        URL(fileURLWithPath: destinationURL.path + ".droidmatch-part")
    }

    static func commitMarkerURL(for destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent().appendingPathComponent(
            AtomicDownloadCommitTransaction.commitMarkerName(
                destinationName: destinationURL.lastPathComponent
            )
        )
    }

    /// Returns the local resume boundary without mutating either destination.
    /// The product scheduler uses this value in `OpenTransferRequest`, while the
    /// eventual writer validates the accepted offset again before writing.
    public static func requestedOffsetBytes(
        for destinationURL: URL,
        resume: Bool,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil,
        fileManager _: FileManager = .default
    ) throws -> Int64 {
        guard resume else {
            return 0
        }
        return try existingRegularFileSize(
            for: destinationURL,
            expectedDirectoryIdentity: expectedDirectoryIdentity,
            directoryContext: directoryContext
        )
    }

    private static func existingRegularFileSize(
        for destinationURL: URL,
        expectedDirectoryIdentity: LocalDirectoryIdentity?,
        directoryContext: LocalDownloadDirectoryContext?
    ) throws -> Int64 {
        let url = partialURL(for: destinationURL)
        guard !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".",
              url.lastPathComponent != ".." else {
            throw AtomicDownloadWriterError.invalidDestination
        }
        let directoryURL = url.deletingLastPathComponent()
        let directoryDescriptor: Int32
        do {
            directoryDescriptor = try AtomicDownloadPartialFile.openDirectory(
                directoryURL,
                createIntermediateDirectories: false,
                expectedIdentity: expectedDirectoryIdentity,
                directoryContext: directoryContext
            )
        } catch let error as POSIXError where error.code == .ENOENT {
            guard expectedDirectoryIdentity == nil, directoryContext == nil else {
                throw AtomicDownloadWriterError.destinationChanged
            }
            return 0
        }
        defer { Darwin.close(directoryDescriptor) }

        try AtomicDownloadCommitTransaction.requireNoRecoveryEntries(
            directoryDescriptor: directoryDescriptor,
            destinationName: destinationURL.lastPathComponent
        )

        guard let metadata = try AtomicDownloadPartialFile.metadata(
            directoryDescriptor: directoryDescriptor,
            name: url.lastPathComponent
        ) else {
            return 0
        }
        guard AtomicDownloadPartialFile.isSafeRegularPartial(metadata) else {
            throw AtomicDownloadWriterError.unsafePartialFile
        }
        return metadata.st_size
    }

    private func validateCurrentDirectoryIdentity() throws {
        guard let expectedDirectoryIdentity else { return }
        if let directoryContext {
            guard directoryContext.directoryIdentity == expectedDirectoryIdentity else {
                throw AtomicDownloadWriterError.destinationChanged
            }
            return
        }
        let descriptor = try AtomicDownloadPartialFile.openDirectory(
            destinationURL.deletingLastPathComponent(),
            createIntermediateDirectories: false,
            expectedIdentity: expectedDirectoryIdentity,
            directoryContext: nil
        )
        Darwin.close(descriptor)
    }

    private func finalizeCommitPublication() throws {
        guard let directoryDescriptor, let commitPublication else {
            throw AtomicDownloadWriterError.commitUncertain
        }
        try AtomicDownloadCommitTransaction.finalizeDisplacedDestination(
            directoryDescriptor: directoryDescriptor,
            destinationName: destinationName,
            publication: commitPublication
        )
        try removeCommitMarker()
        self.commitPublication = nil
        awaitingCommitFinalization = false
        closeLock()
        closeDirectory()
    }

    private func rollbackCommitPublication(
        retainRecoveryMarker: Bool = false
    ) throws {
        guard let directoryDescriptor, let commitPublication else {
            throw AtomicDownloadWriterError.commitUncertain
        }
        try AtomicDownloadCommitTransaction.rollback(
            directoryDescriptor: directoryDescriptor,
            partialName: partialName,
            destinationName: destinationName,
            publication: commitPublication
        )
        self.commitPublication = nil
        awaitingCommitFinalization = false
        if retainRecoveryMarker {
            awaitingRollbackFinalization = true
        } else {
            try removeCommitMarker()
            closeLock()
            closeDirectory()
        }
    }

    private func removeCommitMarker() throws {
        guard let directoryDescriptor, let commitMarkerMetadata else {
            throw AtomicDownloadWriterError.commitUncertain
        }
        try AtomicDownloadCommitTransaction.removeCommitMarker(
            directoryDescriptor: directoryDescriptor,
            destinationName: destinationName,
            expected: commitMarkerMetadata
        )
        self.commitMarkerMetadata = nil
    }

    private func closeLock() {
        guard let lockDescriptor else { return }
        self.lockDescriptor = nil
        AtomicDownloadPartialFile.unlockAndClose(lockDescriptor)
    }

    private func closeDirectory() {
        guard let directoryDescriptor else {
            return
        }
        self.directoryDescriptor = nil
        Darwin.close(directoryDescriptor)
    }

}
