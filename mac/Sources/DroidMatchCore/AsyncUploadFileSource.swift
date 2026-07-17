import Darwin
import Foundation

public struct UploadSourceSnapshot: Sendable, Equatable {
    public let sizeBytes: Int64
    public let modifiedUnixMillis: Int64
    public let modifiedUnixNanoseconds: Int64
    public let changedUnixNanoseconds: Int64
    public let fileSystemNumber: UInt64
    public let fileNumber: UInt64
}

public enum AsyncUploadFileSourceError: Error, CustomStringConvertible, Sendable, Equatable {
    case unavailable
    case notRegularFile(String)
    case invalidAttributes(String)
    case invalidRead(offsetBytes: Int64, byteCount: Int, sizeBytes: Int64)
    case sourceChanged(expected: UploadSourceSnapshot, actual: UploadSourceSnapshot)
    case shortRead(expected: Int, actual: Int, offsetBytes: Int64)

    public var description: String {
        switch self {
        case .unavailable:
            return "upload source is unavailable"
        case .notRegularFile:
            return "upload source is not a regular file"
        case .invalidAttributes:
            return "upload source metadata is incomplete or invalid"
        case let .invalidRead(offsetBytes, byteCount, sizeBytes):
            return "upload source read is outside the file: offset \(offsetBytes), count \(byteCount), size \(sizeBytes)"
        case .sourceChanged:
            return "upload source changed after its transfer snapshot was captured"
        case let .shortRead(expected, actual, offsetBytes):
            return "upload source returned \(actual) bytes at offset \(offsetBytes); expected \(expected)"
        }
    }
}

/// Single-owner boundary for blocking upload source reads.
///
/// `snapshot()` opens one no-follow descriptor and that descriptor remains the
/// only byte source for the transfer. Every validation compares both its
/// `fstat` identity and the current path's `lstat` identity with the accepted
/// snapshot. This closes the path/open swap window without allowing a resumed
/// upload to splice bytes from a replacement path into an older remote prefix.
public final class AsyncUploadFileSource: @unchecked Sendable {
    public let sourceURL: URL

    private let queue = DispatchQueue(label: "app.droidmatch.async-upload-file-source")
    private var descriptor: Int32 = -1

    public init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    public func snapshot() async throws -> UploadSourceSnapshot {
        try await perform {
            let descriptor = try self.openDescriptorIfNeeded()
            let snapshot = try Self.readDescriptorSnapshot(descriptor)
            try self.requirePathSnapshot(snapshot)
            return snapshot
        }
    }

    public func validate(_ expected: UploadSourceSnapshot) async throws {
        try await perform {
            try self.requireSnapshot(expected)
        }
    }

    public func read(
        offsetBytes: Int64,
        byteCount: Int,
        expectedSnapshot: UploadSourceSnapshot
    ) async throws -> Data {
        try await perform {
            guard offsetBytes >= 0,
                  byteCount >= 0,
                  offsetBytes <= expectedSnapshot.sizeBytes,
                  Int64(byteCount) <= expectedSnapshot.sizeBytes - offsetBytes else {
                throw AsyncUploadFileSourceError.invalidRead(
                    offsetBytes: offsetBytes,
                    byteCount: byteCount,
                    sizeBytes: expectedSnapshot.sizeBytes
                )
            }
            let descriptor = try self.openDescriptorIfNeeded()
            try self.requireSnapshot(expectedSnapshot)
            if byteCount == 0 {
                return Data()
            }

            var data = Data(count: byteCount)
            let actualCount = try data.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                var completed = 0
                while completed < byteCount {
                    let result = Darwin.pread(
                        descriptor,
                        baseAddress.advanced(by: completed),
                        byteCount - completed,
                        off_t(offsetBytes + Int64(completed))
                    )
                    if result > 0 {
                        completed += result
                    } else if result == 0 {
                        break
                    } else if errno != EINTR {
                        throw AsyncUploadFileSourceError.unavailable
                    }
                }
                return completed
            }
            guard actualCount == byteCount else {
                throw AsyncUploadFileSourceError.shortRead(
                    expected: byteCount,
                    actual: actualCount,
                    offsetBytes: offsetBytes
                )
            }
            try self.requireSnapshot(expectedSnapshot)
            return data
        }
    }

    public func close() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.descriptor >= 0 {
                    Darwin.close(self.descriptor)
                    self.descriptor = -1
                }
                continuation.resume()
            }
        }
    }

    private func openDescriptorIfNeeded() throws -> Int32 {
        if descriptor >= 0 { return descriptor }
        guard sourceURL.isFileURL else {
            throw AsyncUploadFileSourceError.unavailable
        }
        let opened = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard opened >= 0 else {
            if errno == ELOOP || errno == EISDIR {
                throw AsyncUploadFileSourceError.notRegularFile(
                    TransferWireMetadata.localUploadSource
                )
            }
            throw AsyncUploadFileSourceError.unavailable
        }
        do {
            _ = try Self.readDescriptorSnapshot(opened)
        } catch {
            Darwin.close(opened)
            throw error
        }
        descriptor = opened
        return opened
    }

    private func requireSnapshot(_ expected: UploadSourceSnapshot) throws {
        let descriptor = try openDescriptorIfNeeded()
        let descriptorSnapshot = try Self.readDescriptorSnapshot(descriptor)
        guard descriptorSnapshot == expected else {
            throw AsyncUploadFileSourceError.sourceChanged(
                expected: expected,
                actual: descriptorSnapshot
            )
        }
        try requirePathSnapshot(expected)
    }

    private func requirePathSnapshot(_ expected: UploadSourceSnapshot) throws {
        var metadata = stat()
        guard Darwin.lstat(sourceURL.path, &metadata) == 0 else {
            throw AsyncUploadFileSourceError.unavailable
        }
        let actual = try Self.snapshot(metadata)
        guard actual == expected else {
            throw AsyncUploadFileSourceError.sourceChanged(expected: expected, actual: actual)
        }
    }

    private static func readDescriptorSnapshot(_ descriptor: Int32) throws -> UploadSourceSnapshot {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw AsyncUploadFileSourceError.unavailable
        }
        return try snapshot(metadata)
    }

    private static func snapshot(_ metadata: stat) throws -> UploadSourceSnapshot {
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw AsyncUploadFileSourceError.notRegularFile(
                TransferWireMetadata.localUploadSource
            )
        }
        guard metadata.st_size >= 0 else {
            throw AsyncUploadFileSourceError.invalidAttributes(
                TransferWireMetadata.localUploadSource
            )
        }
        let modified = try unixNanoseconds(metadata.st_mtimespec)
        let changed = try unixNanoseconds(metadata.st_ctimespec)
        return UploadSourceSnapshot(
            sizeBytes: Int64(metadata.st_size),
            modifiedUnixMillis: modified / 1_000_000,
            modifiedUnixNanoseconds: modified,
            changedUnixNanoseconds: changed,
            fileSystemNumber: UInt64(metadata.st_dev),
            fileNumber: UInt64(metadata.st_ino)
        )
    }

    private static func unixNanoseconds(_ value: timespec) throws -> Int64 {
        let seconds = Int64(value.tv_sec)
        let nanoseconds = Int64(value.tv_nsec)
        guard seconds >= 0,
              nanoseconds >= 0,
              nanoseconds < 1_000_000_000,
              seconds <= (Int64.max - nanoseconds) / 1_000_000_000 else {
            throw AsyncUploadFileSourceError.invalidAttributes(
                TransferWireMetadata.localUploadSource
            )
        }
        return seconds * 1_000_000_000 + nanoseconds
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
