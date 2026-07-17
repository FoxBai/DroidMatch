import Darwin
import Foundation

// Darwin imports `struct flock` alongside the same-named C function.
@_silgen_name("flock")
private func droidMatchPrivateAtomicFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// One fixed cross-process transaction lock per pinned parent directory.
///
/// Every private atomic read, write, and remove in the parent serializes on the
/// same empty inode. The node stays permanently: unlinking it after unlock could
/// split future callers across old and replacement inodes. This bounded metadata
/// cost is one private, fixed-name, zero-byte file per used parent and contains
/// neither a destination name nor a path.
final class PrivateAtomicFileTransactionLock: @unchecked Sendable {
    static let entryName = ".droidmatch-private-atomic-lock"

    private let stateLock = NSLock()
    private var descriptor: Int32?

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { release() }

    static func acquire(
        parentDescriptor: Int32,
        parentIdentity: stat,
        destinationName: String
    ) throws -> PrivateAtomicFileTransactionLock {
        guard !isInfrastructureName(destinationName) else {
            throw PrivateAtomicFileWriterError.unsafeDestination
        }
        var descriptor: Int32 = -1
        do {
            let currentParent = try directoryMetadata(descriptor: parentDescriptor)
            guard LocalDirectoryIdentity(currentParent) == LocalDirectoryIdentity(parentIdentity) else {
                throw LockError.unsafe
            }
            let openedLock = try openLock(parentDescriptor: parentDescriptor)
            descriptor = openedLock.descriptor
            try acquireFlock(descriptor)
            if openedLock.created {
                guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
                      Darwin.fsync(descriptor) == 0,
                      Darwin.fsync(parentDescriptor) == 0 else {
                    throw LockError.unsafe
                }
            }
            let opened = try lockMetadata(descriptor: descriptor)
            guard try namedEntryMatches(
                parentDescriptor: parentDescriptor,
                opened: opened
            ) else {
                throw LockError.unsafe
            }
            let recheckedParent = try directoryMetadata(descriptor: parentDescriptor)
            guard LocalDirectoryIdentity(recheckedParent) == LocalDirectoryIdentity(parentIdentity) else {
                throw LockError.unsafe
            }
            return PrivateAtomicFileTransactionLock(descriptor: descriptor)
        } catch {
            if descriptor >= 0 {
                _ = droidMatchPrivateAtomicFlock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
            }
            throw PrivateAtomicFileWriterError.unsafeDestination
        }
    }

    func release() {
        stateLock.lock()
        let descriptor = descriptor
        self.descriptor = nil
        stateLock.unlock()

        guard let descriptor else { return }
        _ = droidMatchPrivateAtomicFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private static func isInfrastructureName(_ name: String) -> Bool {
        name.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ) == entryName
    }

    private enum LockError: Error {
        case unsafe
    }

    private struct OpenedLock {
        let descriptor: Int32
        let created: Bool
    }

    private static func openLock(parentDescriptor: Int32) throws -> OpenedLock {
        var descriptor = entryName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        let created = descriptor >= 0
        if descriptor < 0, errno == EEXIST {
            descriptor = entryName.withCString {
                Darwin.openat(parentDescriptor, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            }
        }
        guard descriptor >= 0 else { throw LockError.unsafe }
        return OpenedLock(descriptor: descriptor, created: created)
    }

    private static func acquireFlock(_ descriptor: Int32) throws {
        while droidMatchPrivateAtomicFlock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw LockError.unsafe }
        }
    }

    private static func lockMetadata(descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              isSafeLock(metadata) else {
            throw LockError.unsafe
        }
        return metadata
    }

    private static func directoryMetadata(descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              PrivateAtomicFilePrimitives.isDirectory(metadata) else {
            throw LockError.unsafe
        }
        return metadata
    }

    private static func namedEntryMatches(
        parentDescriptor: Int32,
        opened: stat
    ) throws -> Bool {
        var named = stat()
        let result = entryName.withCString {
            Darwin.fstatat(parentDescriptor, $0, &named, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { throw LockError.unsafe }
        return isSafeLock(named)
            && named.st_dev == opened.st_dev
            && named.st_ino == opened.st_ino
            && named.st_mode == opened.st_mode
            && named.st_nlink == opened.st_nlink
            && named.st_uid == opened.st_uid
            && named.st_gid == opened.st_gid
            && named.st_size == opened.st_size
    }

    private static func isSafeLock(_ metadata: stat) -> Bool {
        PrivateAtomicFilePrimitives.isRegularSingleLink(metadata)
            && metadata.st_uid == geteuid()
            && metadata.st_size == 0
            && metadata.st_mode & mode_t(0o7777) == mode_t(0o600)
    }
}
