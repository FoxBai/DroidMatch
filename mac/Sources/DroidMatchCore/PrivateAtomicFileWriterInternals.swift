import Darwin
import Foundation

// Same-module POSIX proof helpers for PrivateAtomicFileWriter. Internal
// visibility exists only so this cohesive extension can live separately
// from the read/write/remove transaction orchestration.
extension PrivateAtomicFileWriter {
    typealias Primitives = PrivateAtomicFilePrimitives

    struct PinnedLocation {
        let directoryDescriptor: Int32
        let parentPath: String?
        let directoryIdentity: stat
        let name: String
    }

    struct OpenedEntry {
        let descriptor: Int32
        let snapshot: stat
    }

    static func acquireTransactionLock(
        at location: PinnedLocation
    ) throws -> PrivateAtomicFileTransactionLock {
        try PrivateAtomicFileTransactionLock.acquire(
            parentDescriptor: location.directoryDescriptor,
            parentIdentity: location.directoryIdentity,
            destinationName: location.name
        )
    }

    static func pinnedLocation(
        for url: URL,
        expectedDirectoryIdentity: LocalDirectoryIdentity?,
        directoryContext: LocalDownloadDirectoryContext?
    ) throws -> PinnedLocation {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".",
              url.lastPathComponent != ".." else {
            throw PrivateAtomicFileWriterError.unsafeDestination
        }
        let parentPath = directoryContext == nil
            ? url.deletingLastPathComponent().path
            : nil
        let descriptor: Int32
        if let directoryContext {
            descriptor = try directoryContext.duplicateDescriptor()
        } else {
            do {
                descriptor = try SafeDirectoryDescriptor.openAbsolute(
                    url.deletingLastPathComponent()
                )
            } catch is SafeDirectoryDescriptorError {
                throw PrivateAtomicFileWriterError.unsafeDestination
            }
        }
        var identity = stat()
        guard Darwin.fstat(descriptor, &identity) == 0,
              Primitives.isDirectory(identity) else {
            let statusError = errno
            Darwin.close(descriptor)
            if statusError == 0 {
                throw PrivateAtomicFileWriterError.unsafeDestination
            }
            throw Primitives.posixError(statusError)
        }
        guard expectedDirectoryIdentity == nil
                || LocalDirectoryIdentity(identity) == expectedDirectoryIdentity else {
            Darwin.close(descriptor)
            throw PrivateAtomicFileWriterError.unsafeDestination
        }
        return PinnedLocation(
            directoryDescriptor: descriptor,
            parentPath: parentPath,
            directoryIdentity: identity,
            name: url.lastPathComponent
        )
    }

    static func parentStillPinned(_ location: PinnedLocation) -> Bool {
        guard let parentPath = location.parentPath else {
            var current = stat()
            return Darwin.fstat(location.directoryDescriptor, &current) == 0
                && Primitives.isDirectory(current)
                && current.st_dev == location.directoryIdentity.st_dev
                && current.st_ino == location.directoryIdentity.st_ino
        }
        guard let descriptor = try? SafeDirectoryDescriptor.openAbsolute(
            URL(fileURLWithPath: parentPath, isDirectory: true)
        ) else { return false }
        defer { Darwin.close(descriptor) }
        var current = stat()
        return Darwin.fstat(descriptor, &current) == 0
            && Primitives.isDirectory(current)
            && current.st_dev == location.directoryIdentity.st_dev
            && current.st_ino == location.directoryIdentity.st_ino
    }

    static func openEntryIfPresent(
        at location: PinnedLocation,
        requiresPrivatePermissions: Bool
    ) throws -> OpenedEntry? {
        guard let initial = try entrySnapshot(
            at: location,
            name: location.name,
            requiresPrivatePermissions: requiresPrivatePermissions
        ) else { return nil }
        let descriptor = location.name.withCString {
            Darwin.openat(
                location.directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ELOOP || errno == ENOTDIR {
                throw PrivateAtomicFileWriterError.unsafeDestination
            }
            throw Primitives.posixError(errno)
        }
        do {
            let opened = try regularSnapshot(
                descriptor,
                requiresPrivatePermissions: requiresPrivatePermissions
            )
            let current = try entrySnapshot(
                at: location,
                name: location.name,
                requiresPrivatePermissions: requiresPrivatePermissions
            )
            guard Primitives.sameSnapshot(initial, opened),
                  current.map({ Primitives.sameSnapshot($0, opened) }) == true else {
                throw PrivateAtomicFileWriterError.unsafeDestination
            }
            return OpenedEntry(descriptor: descriptor, snapshot: opened)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func verifyUnchanged(
        _ entry: OpenedEntry?,
        at location: PinnedLocation,
        requiresPrivatePermissions: Bool
    ) throws {
        let current = try entrySnapshot(
            at: location,
            name: location.name,
            requiresPrivatePermissions: requiresPrivatePermissions
        )
        guard let entry else {
            guard current == nil else {
                throw PrivateAtomicFileWriterError.unsafeDestination
            }
            return
        }
        let descriptorSnapshot = try regularSnapshot(
            entry.descriptor,
            requiresPrivatePermissions: requiresPrivatePermissions
        )
        guard Primitives.sameSnapshot(entry.snapshot, descriptorSnapshot),
              current.map({ Primitives.sameSnapshot($0, descriptorSnapshot) }) == true else {
            throw PrivateAtomicFileWriterError.unsafeDestination
        }
    }

    @discardableResult
    static func verifyPublication(
        at location: PinnedLocation,
        pendingName: String,
        candidateDescriptor: Int32,
        previous: OpenedEntry?,
        requiresPrivatePermissions: Bool
    ) throws -> (candidate: stat, displaced: stat?) {
        let candidate = try regularSnapshot(
            candidateDescriptor,
            requiresPrivatePermissions: true
        )
        guard entryMatches(candidate, at: location, name: location.name) else {
            throw PrivateAtomicFileWriterError.unsafeDestination
        }
        guard let previous else {
            guard try entryIsAbsent(at: location, name: pendingName) else {
                throw PrivateAtomicFileWriterError.unsafeDestination
            }
            return (candidate, nil)
        }
        let displaced = try regularSnapshot(
            previous.descriptor,
            requiresPrivatePermissions: requiresPrivatePermissions
        )
        guard entryMatches(displaced, at: location, name: pendingName) else {
            throw PrivateAtomicFileWriterError.unsafeDestination
        }
        return (candidate, displaced)
    }

    static func rollbackPublication(
        at location: PinnedLocation,
        pendingName: String,
        candidateDescriptor: Int32,
        previous: OpenedEntry?,
        requiresPrivatePermissions: Bool
    ) throws {
        let candidate = try regularSnapshot(
            candidateDescriptor,
            requiresPrivatePermissions: true
        )
        guard entryMatches(candidate, at: location, name: location.name) else {
            throw PrivateAtomicFileWriterError.commitUncertain
        }
        let rollbackStatus: Int32
        if let previous {
            let displaced = try regularSnapshot(
                previous.descriptor,
                requiresPrivatePermissions: requiresPrivatePermissions
            )
            guard entryMatches(displaced, at: location, name: pendingName) else {
                throw PrivateAtomicFileWriterError.commitUncertain
            }
            rollbackStatus = pendingName.withCString { pending in
                location.name.withCString { destination in
                    Darwin.renameatx_np(
                        location.directoryDescriptor,
                        pending,
                        location.directoryDescriptor,
                        destination,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
        } else {
            rollbackStatus = location.name.withCString { destination in
                pendingName.withCString { pending in
                    Darwin.renameatx_np(
                        location.directoryDescriptor,
                        destination,
                        location.directoryDescriptor,
                        pending,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
        }
        guard rollbackStatus == 0 else {
            throw PrivateAtomicFileWriterError.commitUncertain
        }
        let rolledBackCandidate = try regularSnapshot(
            candidateDescriptor,
            requiresPrivatePermissions: true
        )
        guard entryMatches(rolledBackCandidate, at: location, name: pendingName) else {
            throw PrivateAtomicFileWriterError.commitUncertain
        }
        if let previous {
            let restored = try regularSnapshot(
                previous.descriptor,
                requiresPrivatePermissions: requiresPrivatePermissions
            )
            guard entryMatches(restored, at: location, name: location.name) else {
                throw PrivateAtomicFileWriterError.commitUncertain
            }
        } else if try entrySnapshot(
            at: location,
            name: location.name,
            requiresPrivatePermissions: requiresPrivatePermissions
        ) != nil {
            throw PrivateAtomicFileWriterError.commitUncertain
        }
        try synchronizeDirectory(location)
        guard parentStillPinned(location) else {
            throw PrivateAtomicFileWriterError.commitUncertain
        }
        try unlinkTracked(rolledBackCandidate, at: location, name: pendingName)
        try synchronizeDirectory(location)
        guard parentStillPinned(location) else {
            throw PrivateAtomicFileWriterError.commitUncertain
        }
        try requireNoRecoveryEntry(at: location)
    }

    static func rollbackRemoval(
        at location: PinnedLocation,
        removingName: String,
        descriptor: Int32,
        requiresPrivatePermissions: Bool
    ) throws {
        let moved = try regularSnapshot(
            descriptor,
            requiresPrivatePermissions: requiresPrivatePermissions
        )
        guard entryMatches(moved, at: location, name: removingName) else {
            throw PrivateAtomicFileWriterError.commitUncertain
        }
        let status = removingName.withCString { removing in
            location.name.withCString { destination in
                Darwin.renameatx_np(
                    location.directoryDescriptor,
                    removing,
                    location.directoryDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard status == 0 else {
            throw PrivateAtomicFileWriterError.commitUncertain
        }
        let restored = try regularSnapshot(
            descriptor,
            requiresPrivatePermissions: requiresPrivatePermissions
        )
        guard entryMatches(restored, at: location, name: location.name) else {
            throw PrivateAtomicFileWriterError.commitUncertain
        }
        try synchronizeDirectory(location)
        guard parentStillPinned(location) else {
            throw PrivateAtomicFileWriterError.commitUncertain
        }
        try requireNoRecoveryEntry(at: location)
    }

    static func requireNoRecoveryEntry(at location: PinnedLocation) throws {
        for suffix in ["pending", "removing"] {
            let name = recoveryName(for: location.name, suffix: suffix)
            var metadata = stat()
            let status = name.withCString {
                Darwin.fstatat(location.directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            if status == 0 {
                throw PrivateAtomicFileWriterError.commitUncertain
            }
            if errno != ENOENT {
                throw Primitives.posixError(errno)
            }
        }
    }

    static func entryIsAbsent(at location: PinnedLocation, name: String) throws -> Bool {
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(location.directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if status == 0 { return false }
        if errno == ENOENT { return true }
        throw Primitives.posixError(errno)
    }

    static func recoveryName(for name: String, suffix: String) -> String {
        ".\(name).\(suffix)"
    }

    static func entrySnapshot(
        at location: PinnedLocation,
        name: String,
        requiresPrivatePermissions: Bool
    ) throws -> stat? {
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(location.directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else {
            if errno == ENOENT { return nil }
            throw Primitives.posixError(errno)
        }
        guard Primitives.isRegularSingleLink(metadata),
              !requiresPrivatePermissions || Primitives.hasPrivatePermissions(metadata) else {
            throw PrivateAtomicFileWriterError.unsafeDestination
        }
        return metadata
    }

    static func regularSnapshot(
        _ descriptor: Int32,
        requiresPrivatePermissions: Bool
    ) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw Primitives.posixError(errno)
        }
        guard Primitives.isRegularSingleLink(metadata),
              !requiresPrivatePermissions || Primitives.hasPrivatePermissions(metadata) else {
            throw PrivateAtomicFileWriterError.unsafeDestination
        }
        return metadata
    }

    static func entryMatches(
        _ snapshot: stat,
        at location: PinnedLocation,
        name: String
    ) -> Bool {
        var current = stat()
        let status = name.withCString {
            Darwin.fstatat(location.directoryDescriptor, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        return status == 0
            && Primitives.isRegularSingleLink(current)
            && Primitives.sameSnapshot(current, snapshot)
    }

    static func unlinkTracked(
        _ snapshot: stat,
        at location: PinnedLocation,
        name: String
    ) throws {
        guard entryMatches(snapshot, at: location, name: name) else {
            throw PrivateAtomicFileWriterError.commitUncertain
        }
        let status = name.withCString {
            Darwin.unlinkat(location.directoryDescriptor, $0, 0)
        }
        guard status == 0 else { throw Primitives.posixError(errno) }
    }

    static func synchronizeDirectory(_ location: PinnedLocation) throws {
        guard Darwin.fsync(location.directoryDescriptor) == 0 else {
            throw Primitives.posixError(errno)
        }
    }

}
