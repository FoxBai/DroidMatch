import Darwin
import Foundation

/// Atomic I/O for App-owned recovery data and transfer sidecars.
///
/// Every mutation is relative to a pinned, non-symlink parent. Fixed `.pending`
/// and `.removing` names make an interrupted operation discoverable: a later
/// operation fails closed instead of overwriting or silently abandoning it.
package enum PrivateAtomicFileWriter {
    package static func readRegularSingleLinkIfPresent(
        at sourceURL: URL,
        maximumBytes: Int = 16 * 1024 * 1024,
        requiresPrivatePermissions: Bool = true,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil
    ) throws -> Data? {
        guard maximumBytes >= 0 else {
            throw PrivateAtomicFileWriterError.unsafeDestination
        }
        let location: PinnedLocation
        do {
            location = try pinnedLocation(
                for: sourceURL,
                expectedDirectoryIdentity: expectedDirectoryIdentity,
                directoryContext: directoryContext
            )
        } catch let error as POSIXError where error.code == .ENOENT {
            guard expectedDirectoryIdentity == nil else {
                throw PrivateAtomicFileWriterError.unsafeDestination
            }
            return nil
        }
        defer { Darwin.close(location.directoryDescriptor) }
        let transactionLock = try acquireTransactionLock(at: location)
        defer { transactionLock.release() }
        try requireNoRecoveryEntry(at: location)

        let descriptor = location.name.withCString {
            Darwin.openat(
                location.directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            let openError = errno
            if openError == ENOENT {
                guard parentStillPinned(location) else {
                    throw PrivateAtomicFileWriterError.unsafeDestination
                }
                try requireNoRecoveryEntry(at: location)
                return nil
            }
            if openError == ELOOP || openError == ENOTDIR {
                throw PrivateAtomicFileWriterError.unsafeDestination
            }
            throw Primitives.posixError(openError)
        }
        defer { Darwin.close(descriptor) }

        let before = try regularSnapshot(
            descriptor,
            requiresPrivatePermissions: requiresPrivatePermissions
        )
        guard before.st_size >= 0, before.st_size <= Int64(maximumBytes) else {
            throw PrivateAtomicFileWriterError.unsafeDestination
        }
        var data = Data(count: Int(before.st_size))
        let actualCount = try data.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            var completed = 0
            while completed < buffer.count {
                let result = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: completed),
                    buffer.count - completed,
                    off_t(completed)
                )
                if result > 0 {
                    completed += result
                } else if result == 0 {
                    break
                } else if errno != EINTR {
                    throw Primitives.posixError(errno)
                }
            }
            return completed
        }
        let after = try regularSnapshot(
            descriptor,
            requiresPrivatePermissions: requiresPrivatePermissions
        )
        let current = try entrySnapshot(
            at: location,
            name: location.name,
            requiresPrivatePermissions: requiresPrivatePermissions
        )
        guard actualCount == data.count,
              Primitives.sameSnapshot(before, after),
              current.map({ Primitives.sameSnapshot($0, after) }) == true,
              parentStillPinned(location) else {
            throw PrivateAtomicFileWriterError.unsafeDestination
        }
        try requireNoRecoveryEntry(at: location)
        return data
    }

    package static func write(
        _ data: Data,
        to destinationURL: URL,
        fileManager _: FileManager = .default,
        requiresPrivatePermissions: Bool = true,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil
    ) throws {
        let location = try pinnedLocation(
            for: destinationURL,
            expectedDirectoryIdentity: expectedDirectoryIdentity,
            directoryContext: directoryContext
        )
        defer { Darwin.close(location.directoryDescriptor) }
        let transactionLock = try acquireTransactionLock(at: location)
        defer { transactionLock.release() }
        try requireNoRecoveryEntry(at: location)
        guard parentStillPinned(location) else {
            throw PrivateAtomicFileWriterError.unsafeDestination
        }

        let previous = try openEntryIfPresent(
            at: location,
            requiresPrivatePermissions: requiresPrivatePermissions
        )
        defer {
            if let previous { Darwin.close(previous.descriptor) }
        }

        let pendingName = recoveryName(for: location.name, suffix: "pending")
        let candidateDescriptor = pendingName.withCString {
            Darwin.openat(
                location.directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard candidateDescriptor >= 0 else {
            if errno == EEXIST {
                throw PrivateAtomicFileWriterError.commitUncertain
            }
            throw Primitives.posixError(errno)
        }
        defer { Darwin.close(candidateDescriptor) }
        var pendingContainsCandidate = true

        do {
            guard Darwin.fchmod(candidateDescriptor, mode_t(0o600)) == 0 else {
                throw Primitives.posixError(errno)
            }
            try Primitives.writeAll(data, to: candidateDescriptor)
            guard Darwin.fsync(candidateDescriptor) == 0 else {
                throw Primitives.posixError(errno)
            }
            _ = try regularSnapshot(
                candidateDescriptor,
                requiresPrivatePermissions: true
            )
            try verifyUnchanged(previous, at: location, requiresPrivatePermissions: requiresPrivatePermissions)
            guard parentStillPinned(location) else {
                throw PrivateAtomicFileWriterError.unsafeDestination
            }

            let renameStatus = pendingName.withCString { pending in
                location.name.withCString { destination in
                    Darwin.renameatx_np(
                        location.directoryDescriptor,
                        pending,
                        location.directoryDescriptor,
                        destination,
                        UInt32(previous == nil ? RENAME_EXCL : RENAME_SWAP)
                    )
                }
            }
            guard renameStatus == 0 else {
                let renameError = errno
                if renameError == EEXIST || renameError == EISDIR || renameError == ENOTDIR {
                    throw PrivateAtomicFileWriterError.unsafeDestination
                }
                throw Primitives.posixError(renameError)
            }
            pendingContainsCandidate = false

            do {
                _ = try verifyPublication(
                    at: location,
                    pendingName: pendingName,
                    candidateDescriptor: candidateDescriptor,
                    previous: previous,
                    requiresPrivatePermissions: requiresPrivatePermissions
                )
                try synchronizeDirectory(location)
                guard parentStillPinned(location) else {
                    throw PrivateAtomicFileWriterError.unsafeDestination
                }
                _ = try verifyPublication(
                    at: location,
                    pendingName: pendingName,
                    candidateDescriptor: candidateDescriptor,
                    previous: previous,
                    requiresPrivatePermissions: requiresPrivatePermissions
                )
            } catch {
                do {
                    try rollbackPublication(
                        at: location,
                        pendingName: pendingName,
                        candidateDescriptor: candidateDescriptor,
                        previous: previous,
                        requiresPrivatePermissions: requiresPrivatePermissions
                    )
                } catch {
                    throw PrivateAtomicFileWriterError.commitUncertain
                }
                throw error
            }

            if let previous {
                let displaced = try regularSnapshot(
                    previous.descriptor,
                    requiresPrivatePermissions: requiresPrivatePermissions
                )
                do {
                    try unlinkTracked(displaced, at: location, name: pendingName)
                    try synchronizeDirectory(location)
                    guard parentStillPinned(location) else {
                        throw PrivateAtomicFileWriterError.commitUncertain
                    }
                } catch {
                    throw PrivateAtomicFileWriterError.commitUncertain
                }
            }
            do {
                try requireNoRecoveryEntry(at: location)
            } catch {
                throw PrivateAtomicFileWriterError.commitUncertain
            }
        } catch {
            if pendingContainsCandidate {
                do {
                    let candidate = try regularSnapshot(
                        candidateDescriptor,
                        requiresPrivatePermissions: true
                    )
                    try unlinkTracked(candidate, at: location, name: pendingName)
                    try synchronizeDirectory(location)
                    guard parentStillPinned(location) else {
                        throw PrivateAtomicFileWriterError.commitUncertain
                    }
                    try requireNoRecoveryEntry(at: location)
                } catch {
                    throw PrivateAtomicFileWriterError.commitUncertain
                }
            }
            throw error
        }
    }

    package static func removeRegularSingleLinkIfPresent(
        at destinationURL: URL,
        requiresPrivatePermissions: Bool = true,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil
    ) throws {
        let location: PinnedLocation
        do {
            location = try pinnedLocation(
                for: destinationURL,
                expectedDirectoryIdentity: expectedDirectoryIdentity,
                directoryContext: directoryContext
            )
        } catch let error as POSIXError where error.code == .ENOENT {
            guard expectedDirectoryIdentity == nil else {
                throw PrivateAtomicFileWriterError.unsafeDestination
            }
            return
        }
        defer { Darwin.close(location.directoryDescriptor) }
        let transactionLock = try acquireTransactionLock(at: location)
        defer { transactionLock.release() }
        try requireNoRecoveryEntry(at: location)
        guard parentStillPinned(location) else {
            throw PrivateAtomicFileWriterError.unsafeDestination
        }
        let openedEntry = try openEntryIfPresent(
            at: location,
            requiresPrivatePermissions: requiresPrivatePermissions
        )
        guard let entry = openedEntry else {
            guard parentStillPinned(location) else {
                throw PrivateAtomicFileWriterError.unsafeDestination
            }
            try requireNoRecoveryEntry(at: location)
            return
        }
        defer { Darwin.close(entry.descriptor) }

        let removingName = recoveryName(for: location.name, suffix: "removing")
        let moveStatus = location.name.withCString { source in
            removingName.withCString { removing in
                Darwin.renameatx_np(
                    location.directoryDescriptor,
                    source,
                    location.directoryDescriptor,
                    removing,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard moveStatus == 0 else {
            if errno == EEXIST {
                throw PrivateAtomicFileWriterError.commitUncertain
            }
            if errno == EISDIR || errno == ENOTDIR {
                throw PrivateAtomicFileWriterError.unsafeDestination
            }
            throw Primitives.posixError(errno)
        }

        do {
            let moved = try regularSnapshot(
                entry.descriptor,
                requiresPrivatePermissions: requiresPrivatePermissions
            )
            guard entryMatches(moved, at: location, name: removingName) else {
                throw PrivateAtomicFileWriterError.unsafeDestination
            }
            try synchronizeDirectory(location)
            guard parentStillPinned(location),
                  entryMatches(moved, at: location, name: removingName) else {
                throw PrivateAtomicFileWriterError.unsafeDestination
            }
        } catch {
            do {
                try rollbackRemoval(
                    at: location,
                    removingName: removingName,
                    descriptor: entry.descriptor,
                    requiresPrivatePermissions: requiresPrivatePermissions
                )
            } catch {
                throw PrivateAtomicFileWriterError.commitUncertain
            }
            throw error
        }

        do {
            let moved = try regularSnapshot(
                entry.descriptor,
                requiresPrivatePermissions: requiresPrivatePermissions
            )
            try unlinkTracked(moved, at: location, name: removingName)
            try synchronizeDirectory(location)
            guard parentStillPinned(location) else {
                throw PrivateAtomicFileWriterError.commitUncertain
            }
            try requireNoRecoveryEntry(at: location)
        } catch {
            throw PrivateAtomicFileWriterError.commitUncertain
        }
    }

}
