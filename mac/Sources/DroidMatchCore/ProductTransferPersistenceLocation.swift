import CryptoKit
import Darwin
import Foundation

/// Privacy-bounded routing for one authenticated device's queue manifest.
///
/// The manifest schema remains unchanged. Only its private Application Support
/// filename is versioned: new queues use a domain-separated digest instead of
/// exposing the authenticated device fingerprint verbatim. A pre-M1 legacy
/// filename is moved in the same directory only when the new destination is
/// absent. Ambiguous or non-regular state is preserved and rejected.
/// 中文：队列内容格式不变；新文件名使用域分离摘要。旧的原始指纹文件只在新位置
/// 不存在时同目录无覆盖迁移，冲突或非普通文件会保留现场并拒绝继续。
enum ProductTransferPersistenceLocation {
    private static let routeDomain = Data("DroidMatch transfer queue route v2\0".utf8)
    private static let currentPrefix = "queue-route-v2-"
    private static let legacyPrefix = "queue-"

    static func currentURL(directory: URL?, fingerprint: Data) -> URL? {
        guard let directory,
              isValidDirectoryURL(directory),
              fingerprint.count == PairingAuthenticator.digestLength else {
            return nil
        }
        var input = routeDomain
        input.append(fingerprint)
        let routeKey = SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(
            "\(currentPrefix)\(routeKey).json",
            isDirectory: false
        )
    }

    static func legacyURL(directory: URL?, fingerprint: Data) -> URL? {
        guard let directory,
              isValidDirectoryURL(directory),
              fingerprint.count == PairingAuthenticator.digestLength else {
            return nil
        }
        let identity = fingerprint.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(
            "\(legacyPrefix)\(identity).json",
            isDirectory: false
        )
    }

    /// Resolves the current location and performs the one-way legacy rename.
    /// `renameatx_np(..., RENAME_EXCL)` keeps migration atomic and no-clobber.
    static func resolve(directory: URL?, fingerprint: Data) throws -> URL? {
        guard let directory else { return nil }
        guard let current = currentURL(directory: directory, fingerprint: fingerprint),
              let legacy = legacyURL(directory: directory, fingerprint: fingerprint) else {
            throw TransferQueuePersistenceStoreError.invalidLocation
        }

        let currentKind = try itemKind(at: current)
        let legacyKind = try itemKind(at: legacy)
        if currentKind != .missing, legacyKind != .missing {
            // Never guess which independently present queue is authoritative.
            throw TransferQueuePersistenceStoreError.invalidLocation
        }
        if currentKind != .missing {
            guard currentKind == .regular else {
                throw TransferQueuePersistenceStoreError.invalidLocation
            }
            return current
        }
        guard legacyKind != .missing else { return current }
        guard legacyKind == .regular,
              try itemKind(at: directory) == .directory else {
            throw TransferQueuePersistenceStoreError.invalidLocation
        }

        if exclusiveRename(from: legacy, to: current) == 0 {
            guard try itemKind(at: current) == .regular else {
                throw TransferQueuePersistenceStoreError.invalidLocation
            }
            return current
        }
        let renameError = errno

        // A second coordinator may have completed the exact same migration.
        // Accept only the unambiguous post-state; every other race stays closed.
        let currentAfterFailure = try itemKind(at: current)
        let legacyAfterFailure = try itemKind(at: legacy)
        if currentAfterFailure == .regular, legacyAfterFailure == .missing {
            return current
        }
        if renameError == EEXIST || (currentAfterFailure != .missing && legacyAfterFailure != .missing) {
            throw TransferQueuePersistenceStoreError.invalidLocation
        }
        throw TransferQueuePersistenceStoreError.ioFailure
    }

    private enum ItemKind: Equatable {
        case missing
        case regular
        case directory
        case other
    }

    private static func isValidDirectoryURL(_ directory: URL) -> Bool {
        directory.isFileURL && directory.path.hasPrefix("/") && !directory.path.isEmpty
    }

    /// Uses lstat so a dangling or live symlink is never mistaken for absence.
    private static func itemKind(at url: URL) throws -> ItemKind {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        if result == 0 {
            switch metadata.st_mode & S_IFMT {
            case S_IFREG: return .regular
            case S_IFDIR: return .directory
            default: return .other
            }
        }
        if errno == ENOENT { return .missing }
        throw TransferQueuePersistenceStoreError.ioFailure
    }

    private static func exclusiveRename(from source: URL, to destination: URL) -> Int32 {
        source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return -1 }
                return renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
    }
}
