import Darwin
import Foundation

/// Low-level stat and byte-I/O predicates shared by private atomic mutations.
/// Keeping these primitives separate leaves the transaction type focused on
/// its recovery state machine.
enum PrivateAtomicFilePrimitives {
    static func isRegularSingleLink(_ metadata: stat) -> Bool {
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && metadata.st_nlink == 1
    }

    static func hasPrivatePermissions(_ metadata: stat) -> Bool {
        metadata.st_mode & mode_t(0o077) == 0
            && metadata.st_mode & mode_t(0o600) == mode_t(0o600)
    }

    static func isDirectory(_ metadata: stat) -> Bool {
        metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var completed = 0
            while completed < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: completed),
                    buffer.count - completed
                )
                if count > 0 {
                    completed += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw posixError(errno)
                }
            }
        }
    }

    static func posixError(_ value: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: value) ?? .EIO)
    }
}
