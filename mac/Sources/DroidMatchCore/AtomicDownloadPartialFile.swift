import Darwin
import Foundation

// Darwin also imports `struct flock`, which shadows the same-named C function
// in Swift. Bind the advisory-lock function explicitly to its stable C symbol.
@_silgen_name("flock")
private func droidMatchPartialFileFlock(
    _ descriptor: Int32,
    _ operation: Int32
) -> Int32

/// Stateless POSIX boundary for a download writer's pinned directory and
/// single-link partial file.
///
/// The writer retains all descriptors and transaction state. This helper only
/// opens, locks, inspects, and compares filesystem objects without following a
/// user-controlled symbolic link.
enum AtomicDownloadPartialFile {
    typealias Descriptors = (output: Int32, lock: Int32)

    static func openDirectory(
        _ directoryURL: URL,
        createIntermediateDirectories: Bool,
        expectedIdentity: LocalDirectoryIdentity?,
        directoryContext: LocalDownloadDirectoryContext?
    ) throws -> Int32 {
        let descriptor: Int32
        if let directoryContext {
            descriptor = try directoryContext.duplicateDescriptor()
        } else {
            do {
                descriptor = try SafeDirectoryDescriptor.openAbsolute(
                    directoryURL,
                    createIntermediateDirectories: createIntermediateDirectories
                )
            } catch is SafeDirectoryDescriptorError {
                throw AtomicDownloadWriterError.unsafeDestinationDirectory
            }
        }
        do {
            if let expectedIdentity {
                var metadata = stat()
                guard Darwin.fstat(descriptor, &metadata) == 0,
                      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                      LocalDirectoryIdentity(metadata) == expectedIdentity else {
                    throw AtomicDownloadWriterError.destinationChanged
                }
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func open(
        directoryDescriptor: Int32,
        partialName: String
    ) throws -> Descriptors {
        let existing = try metadata(
            directoryDescriptor: directoryDescriptor,
            name: partialName
        )
        if let existing, !isSafeRegularPartial(existing) {
            throw AtomicDownloadWriterError.unsafePartialFile
        }

        if existing != nil {
            let descriptor = try openExisting(
                directoryDescriptor: directoryDescriptor,
                partialName: partialName
            )
            let openedMetadata: stat
            let locked: Descriptors
            do {
                openedMetadata = try regularFileMetadata(descriptor: descriptor)
                locked = try lockedDescriptors(output: descriptor)
            } catch {
                Darwin.close(descriptor)
                throw error
            }

            do {
                // Recheck the name after locking. Otherwise a replacement
                // between fstatat and openat could select an unlocked inode.
                guard let current = try metadata(
                    directoryDescriptor: directoryDescriptor,
                    name: partialName
                ), sameFile(current, openedMetadata) else {
                    throw AtomicDownloadWriterError.destinationBusy
                }
                guard isSafeRegularPartial(current) else {
                    throw AtomicDownloadWriterError.unsafePartialFile
                }
                return locked
            } catch {
                Darwin.close(locked.output)
                Darwin.close(locked.lock)
                throw error
            }
        }
        return try createLocked(
            directoryDescriptor: directoryDescriptor,
            partialName: partialName
        )
    }

    static func regularFileSize(descriptor: Int32) throws -> Int64 {
        try regularFileMetadata(descriptor: descriptor).st_size
    }

    static func regularFileMetadata(descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw currentPOSIXError()
        }
        guard isSafeRegularPartial(metadata) else {
            throw AtomicDownloadWriterError.unsafePartialFile
        }
        return metadata
    }

    static func metadata(
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

    static func isSafeRegularPartial(_ metadata: stat) -> Bool {
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && metadata.st_nlink == 1
            && metadata.st_size >= 0
    }

    static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    static func sameOptionalEntrySnapshot(_ lhs: stat?, _ rhs: stat?) -> Bool {
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

    static func unlockAndClose(_ descriptor: Int32) {
        _ = droidMatchPartialFileFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    static func currentPOSIXError() -> POSIXError {
        posixError(errno)
    }

    private static func openExisting(
        directoryDescriptor: Int32,
        partialName: String
    ) throws -> Int32 {
        let descriptor = partialName.withCString { partialName in
            Darwin.openat(
                directoryDescriptor,
                partialName,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw AtomicDownloadWriterError.destinationBusy
            }
            if errno == ELOOP || errno == ENOTDIR || errno == EISDIR {
                throw AtomicDownloadWriterError.unsafePartialFile
            }
            throw currentPOSIXError()
        }
        do {
            _ = try regularFileSize(descriptor: descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func createLocked(
        directoryDescriptor: Int32,
        partialName: String
    ) throws -> Descriptors {
        let descriptor = partialName.withCString { partialName in
            Darwin.openat(
                directoryDescriptor,
                partialName,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_CREAT | O_EXCL,
                mode_t(0o666)
            )
        }
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw AtomicDownloadWriterError.destinationBusy
            }
            if errno == ELOOP || errno == ENOTDIR || errno == EISDIR {
                throw AtomicDownloadWriterError.unsafePartialFile
            }
            throw currentPOSIXError()
        }
        let locked: Descriptors
        do {
            locked = try lockedDescriptors(output: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        do {
            let opened = try regularFileMetadata(descriptor: descriptor)
            guard let current = try metadata(
                directoryDescriptor: directoryDescriptor,
                name: partialName
            ), sameFile(current, opened) else {
                throw AtomicDownloadWriterError.destinationBusy
            }
            return locked
        } catch {
            Darwin.close(locked.output)
            Darwin.close(locked.lock)
            throw error
        }
    }

    private static func lockedDescriptors(
        output descriptor: Int32
    ) throws -> Descriptors {
        guard droidMatchPartialFileFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw AtomicDownloadWriterError.destinationBusy
            }
            throw posixError(lockError)
        }
        let lockDescriptor = Darwin.dup(descriptor)
        guard lockDescriptor >= 0 else { throw currentPOSIXError() }
        guard Darwin.fcntl(lockDescriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let duplicationError = currentPOSIXError()
            Darwin.close(lockDescriptor)
            throw duplicationError
        }
        return (descriptor, lockDescriptor)
    }

    private static func posixError(_ value: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: value) ?? .EIO)
    }
}
