import Darwin
import Foundation

/// Crash-detectable namespace transaction for publishing a completed partial.
/// The marker and displaced entry use fixed names so restart never mistakes an
/// interrupted replacement for ordinary resumable bytes.
enum AtomicDownloadCommitTransaction {
    struct Publication {
        let published: stat
        let displaced: stat?
    }

    static func commitMarkerName(destinationName: String) -> String {
        ".\(destinationName).droidmatch-commit"
    }

    static func displacedDestinationName(destinationName: String) -> String {
        ".\(destinationName).droidmatch-replaced"
    }

    static func requireNoRecoveryEntries(
        directoryDescriptor: Int32,
        destinationName: String
    ) throws {
        guard try entryMetadata(
            directoryDescriptor: directoryDescriptor,
            name: commitMarkerName(destinationName: destinationName)
        ) == nil,
        try entryMetadata(
            directoryDescriptor: directoryDescriptor,
            name: displacedDestinationName(destinationName: destinationName)
        ) == nil else {
            throw AtomicDownloadWriterError.commitUncertain
        }
    }

    static func createCommitMarker(
        directoryDescriptor: Int32,
        destinationName: String
    ) throws -> stat {
        try requireNoRecoveryEntries(
            directoryDescriptor: directoryDescriptor,
            destinationName: destinationName
        )
        let markerName = commitMarkerName(destinationName: destinationName)
        let descriptor = markerName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            if errno == EEXIST { throw AtomicDownloadWriterError.commitUncertain }
            throw currentPOSIXError()
        }
        defer { Darwin.close(descriptor) }
        let marker = Data("DroidMatch download commit v1\n".utf8)
        do {
            try writeAll(marker, to: descriptor)
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
                  Darwin.fsync(descriptor) == 0 else {
                throw currentPOSIXError()
            }
            let metadata = try regularFileMetadata(descriptor: descriptor)
            guard metadata.st_nlink == 1,
                  metadata.st_mode & mode_t(0o777) == mode_t(0o600),
                  Darwin.fsync(directoryDescriptor) == 0,
                  let named = try entryMetadataAfterMutation(
                    directoryDescriptor: directoryDescriptor,
                    name: markerName
                  ), sameRenameStableSnapshot(named, metadata) else {
                throw AtomicDownloadWriterError.commitUncertain
            }
            return metadata
        } catch {
            // An incompletely published marker is itself the fail-closed state.
            throw AtomicDownloadWriterError.commitUncertain
        }
    }

    static func publish(
        directoryDescriptor: Int32,
        partialName: String,
        destinationName: String,
        lockedPartial: stat,
        initialDestination: stat?
    ) throws -> Publication {
        if let initialDestination {
            return try swapIntoDestination(
                directoryDescriptor: directoryDescriptor,
                partialName: partialName,
                destinationName: destinationName,
                lockedPartial: lockedPartial,
                initialDestination: initialDestination
            )
        }
        return Publication(
            published: try installAbsentDestination(
                directoryDescriptor: directoryDescriptor,
                partialName: partialName,
                destinationName: destinationName,
                lockedPartial: lockedPartial
            ),
            displaced: nil
        )
    }

    static func finalizeDisplacedDestination(
        directoryDescriptor: Int32,
        destinationName: String,
        publication: Publication
    ) throws {
        guard let currentDestination = try entryMetadataAfterMutation(
            directoryDescriptor: directoryDescriptor,
            name: destinationName
        ), sameOptionalEntrySnapshot(currentDestination, publication.published) else {
            throw AtomicDownloadWriterError.commitUncertain
        }
        guard let displaced = publication.displaced else { return }
        let displacedName = displacedDestinationName(destinationName: destinationName)
        guard let current = try entryMetadataAfterMutation(
            directoryDescriptor: directoryDescriptor,
            name: displacedName
        ), sameRenameStableSnapshot(current, displaced) else {
            throw AtomicDownloadWriterError.commitUncertain
        }
        let status = displacedName.withCString {
            Darwin.unlinkat(directoryDescriptor, $0, 0)
        }
        guard status == 0, Darwin.fsync(directoryDescriptor) == 0,
              let durableDestination = try entryMetadataAfterMutation(
                directoryDescriptor: directoryDescriptor,
                name: destinationName
              ), sameOptionalEntrySnapshot(
                durableDestination,
                publication.published
              ) else {
            throw AtomicDownloadWriterError.commitUncertain
        }
    }

    static func rollback(
        directoryDescriptor: Int32,
        partialName: String,
        destinationName: String,
        publication: Publication
    ) throws {
        if let displaced = publication.displaced {
            try restoreDisplacedDestination(
                directoryDescriptor: directoryDescriptor,
                displacedName: displacedDestinationName(destinationName: destinationName),
                partialName: partialName,
                destinationName: destinationName,
                displaced: displaced,
                published: publication.published
            )
        } else {
            guard let currentDestination = try entryMetadataAfterMutation(
                directoryDescriptor: directoryDescriptor,
                name: destinationName
            ), sameRenameStableSnapshot(currentDestination, publication.published),
            try entryMetadataAfterMutation(
                directoryDescriptor: directoryDescriptor,
                name: partialName
            ) == nil else {
                throw AtomicDownloadWriterError.commitUncertain
            }
            let status = destinationName.withCString { destination in
                partialName.withCString { partial in
                    Darwin.renameatx_np(
                        directoryDescriptor,
                        destination,
                        directoryDescriptor,
                        partial,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard status == 0 else {
                throw AtomicDownloadWriterError.commitUncertain
            }
        }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw AtomicDownloadWriterError.commitUncertain
        }
    }

    static func removeCommitMarker(
        directoryDescriptor: Int32,
        destinationName: String,
        expected: stat
    ) throws {
        let markerName = commitMarkerName(destinationName: destinationName)
        guard let current = try entryMetadataAfterMutation(
            directoryDescriptor: directoryDescriptor,
            name: markerName
        ), sameRenameStableSnapshot(current, expected) else {
            throw AtomicDownloadWriterError.commitUncertain
        }
        let result = markerName.withCString {
            Darwin.unlinkat(directoryDescriptor, $0, 0)
        }
        guard result == 0, Darwin.fsync(directoryDescriptor) == 0,
              try entryMetadataAfterMutation(
                directoryDescriptor: directoryDescriptor,
                name: markerName
              ) == nil else {
            throw AtomicDownloadWriterError.commitUncertain
        }
    }

    private static func installAbsentDestination(
        directoryDescriptor: Int32,
        partialName: String,
        destinationName: String,
        lockedPartial: stat
    ) throws -> stat {
        let result = partialName.withCString { partial in
            destinationName.withCString { destination in
                Darwin.renameatx_np(
                    directoryDescriptor,
                    partial,
                    directoryDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw AtomicDownloadWriterError.destinationChanged }
            throw currentPOSIXError()
        }
        guard let published = try entryMetadataAfterMutation(
            directoryDescriptor: directoryDescriptor,
            name: destinationName
        ), sameRenameStableSnapshot(published, lockedPartial) else {
            throw AtomicDownloadWriterError.commitUncertain
        }
        return published
    }

    private static func swapIntoDestination(
        directoryDescriptor: Int32,
        partialName: String,
        destinationName: String,
        lockedPartial: stat,
        initialDestination: stat
    ) throws -> Publication {
        let result = partialName.withCString { partial in
            destinationName.withCString { destination in
                Darwin.renameatx_np(
                    directoryDescriptor,
                    partial,
                    directoryDescriptor,
                    destination,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else { throw currentPOSIXError() }

        let published = try entryMetadataAfterMutation(
            directoryDescriptor: directoryDescriptor,
            name: destinationName
        )
        let displaced = try entryMetadataAfterMutation(
            directoryDescriptor: directoryDescriptor,
            name: partialName
        )
        guard let published, let displaced,
              sameRenameStableSnapshot(published, lockedPartial),
              sameRenameStableSnapshot(displaced, initialDestination) else {
            throw AtomicDownloadWriterError.commitUncertain
        }

        let displacedName = displacedDestinationName(destinationName: destinationName)
        let quarantineResult = partialName.withCString { partial in
            displacedName.withCString { quarantine in
                Darwin.renameatx_np(
                    directoryDescriptor,
                    partial,
                    directoryDescriptor,
                    quarantine,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard quarantineResult == 0 else {
            let renameError = errno
            try restoreDisplacedDestination(
                directoryDescriptor: directoryDescriptor,
                displacedName: partialName,
                partialName: partialName,
                destinationName: destinationName,
                displaced: displaced,
                published: published
            )
            throw posixError(renameError)
        }
        guard let quarantined = try entryMetadataAfterMutation(
            directoryDescriptor: directoryDescriptor,
            name: displacedName
        ), sameRenameStableSnapshot(quarantined, initialDestination),
        let finalQuarantined = try entryMetadataAfterMutation(
            directoryDescriptor: directoryDescriptor,
            name: displacedName
        ), sameOptionalEntrySnapshot(finalQuarantined, quarantined) else {
            throw AtomicDownloadWriterError.commitUncertain
        }
        return Publication(published: published, displaced: finalQuarantined)
    }

    private static func restoreDisplacedDestination(
        directoryDescriptor: Int32,
        displacedName: String,
        partialName: String,
        destinationName: String,
        displaced: stat,
        published: stat
    ) throws {
        guard let currentDisplaced = try entryMetadataAfterMutation(
            directoryDescriptor: directoryDescriptor,
            name: displacedName
        ), sameOptionalEntrySnapshot(currentDisplaced, displaced),
        let currentPublished = try entryMetadataAfterMutation(
            directoryDescriptor: directoryDescriptor,
            name: destinationName
        ), sameOptionalEntrySnapshot(currentPublished, published) else {
            throw AtomicDownloadWriterError.commitUncertain
        }
        let restored = displacedName.withCString { displacedName in
            destinationName.withCString { destinationName in
                Darwin.renameatx_np(
                    directoryDescriptor,
                    displacedName,
                    directoryDescriptor,
                    destinationName,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard restored == 0,
              let restoredDestination = try entryMetadataAfterMutation(
                directoryDescriptor: directoryDescriptor,
                name: destinationName
              ), sameRenameStableSnapshot(restoredDestination, displaced),
              let recoveredCandidate = try entryMetadataAfterMutation(
                directoryDescriptor: directoryDescriptor,
                name: displacedName
              ), sameRenameStableSnapshot(recoveredCandidate, published) else {
            throw AtomicDownloadWriterError.commitUncertain
        }
        guard displacedName != partialName else { return }
        let moved = displacedName.withCString { displacedName in
            partialName.withCString { partialName in
                Darwin.renameatx_np(
                    directoryDescriptor,
                    displacedName,
                    directoryDescriptor,
                    partialName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard moved == 0,
              let recoveredPartial = try entryMetadataAfterMutation(
                directoryDescriptor: directoryDescriptor,
                name: partialName
              ), sameRenameStableSnapshot(recoveredPartial, published) else {
            throw AtomicDownloadWriterError.commitUncertain
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    bytes.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw currentPOSIXError()
                }
            }
        }
    }

    private static func regularFileMetadata(descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw currentPOSIXError()
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_nlink == 1,
              metadata.st_size >= 0 else {
            throw AtomicDownloadWriterError.commitUncertain
        }
        return metadata
    }

    private static func entryMetadata(
        directoryDescriptor: Int32,
        name: String
    ) throws -> stat? {
        var metadata = stat()
        let result = name.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            let statusError = errno
            if statusError == ENOENT { return nil }
            throw posixError(statusError)
        }
        return metadata
    }

    private static func entryMetadataAfterMutation(
        directoryDescriptor: Int32,
        name: String
    ) throws -> stat? {
        do {
            return try entryMetadata(directoryDescriptor: directoryDescriptor, name: name)
        } catch {
            throw AtomicDownloadWriterError.commitUncertain
        }
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func sameRenameStableSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        sameFile(lhs, rhs)
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func sameOptionalEntrySnapshot(_ lhs: stat?, _ rhs: stat?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (.some(lhs), .some(rhs)):
            return sameFile(lhs, rhs)
                && lhs.st_mode == rhs.st_mode
                && lhs.st_nlink == rhs.st_nlink
                && lhs.st_uid == rhs.st_uid
                && lhs.st_gid == rhs.st_gid
                && lhs.st_size == rhs.st_size
                && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
                && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
                && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
                && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
        default:
            return false
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        posixError(errno)
    }

    private static func posixError(_ value: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: value) ?? .EIO)
    }
}
