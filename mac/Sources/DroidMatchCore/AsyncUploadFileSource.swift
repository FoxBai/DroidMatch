import Foundation

public struct UploadSourceSnapshot: Sendable, Equatable {
    public let sizeBytes: Int64
    public let modifiedUnixMillis: Int64
    public let modifiedUnixNanoseconds: Int64
    public let fileSystemNumber: UInt64
    public let fileNumber: UInt64
}

public enum AsyncUploadFileSourceError: Error, CustomStringConvertible, Sendable, Equatable {
    case notRegularFile(String)
    case invalidAttributes(String)
    case invalidRead(offsetBytes: Int64, byteCount: Int, sizeBytes: Int64)
    case sourceChanged(expected: UploadSourceSnapshot, actual: UploadSourceSnapshot)
    case shortRead(expected: Int, actual: Int, offsetBytes: Int64)

    public var description: String {
        switch self {
        case let .notRegularFile(path):
            return "upload source is not a regular file: \(path)"
        case let .invalidAttributes(path):
            return "upload source metadata is incomplete or invalid: \(path)"
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
/// The private serial queue owns the `FileHandle`. Every read validates the
/// path's size, mtime, filesystem, and inode before and after I/O so a product
/// scheduler never performs Foundation file operations on Swift's cooperative
/// executor and never silently mixes bytes from a replaced source file.
public final class AsyncUploadFileSource: @unchecked Sendable {
    public let sourceURL: URL

    private let queue = DispatchQueue(label: "app.droidmatch.async-upload-file-source")
    private var handle: FileHandle?

    public init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    public func snapshot() async throws -> UploadSourceSnapshot {
        try await perform {
            try Self.readSnapshot(sourceURL: self.sourceURL)
        }
    }

    public func validate(_ expected: UploadSourceSnapshot) async throws {
        try await perform {
            let actual = try Self.readSnapshot(sourceURL: self.sourceURL)
            guard actual == expected else {
                throw AsyncUploadFileSourceError.sourceChanged(
                    expected: expected,
                    actual: actual
                )
            }
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
            try self.requireSnapshot(expectedSnapshot)
            if byteCount == 0 {
                return Data()
            }
            let handle: FileHandle
            if let existing = self.handle {
                handle = existing
            } else {
                let opened = try FileHandle(forReadingFrom: self.sourceURL)
                self.handle = opened
                handle = opened
            }
            try handle.seek(toOffset: UInt64(offsetBytes))
            let data = try handle.read(upToCount: byteCount) ?? Data()
            guard data.count == byteCount else {
                throw AsyncUploadFileSourceError.shortRead(
                    expected: byteCount,
                    actual: data.count,
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
                try? self.handle?.close()
                self.handle = nil
                continuation.resume()
            }
        }
    }

    private func requireSnapshot(_ expected: UploadSourceSnapshot) throws {
        let actual = try Self.readSnapshot(sourceURL: sourceURL)
        guard actual == expected else {
            throw AsyncUploadFileSourceError.sourceChanged(expected: expected, actual: actual)
        }
    }

    private static func readSnapshot(sourceURL: URL) throws -> UploadSourceSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw AsyncUploadFileSourceError.notRegularFile(sourceURL.path)
        }
        guard let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let fileSystem = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else {
            throw AsyncUploadFileSourceError.invalidAttributes(sourceURL.path)
        }
        let modifiedSeconds = modified.timeIntervalSince1970
        guard size.int64Value >= 0,
              modifiedSeconds >= 0,
              modifiedSeconds <= Double(Int64.max) / 1_000_000_000 else {
            throw AsyncUploadFileSourceError.invalidAttributes(sourceURL.path)
        }
        return UploadSourceSnapshot(
            sizeBytes: size.int64Value,
            modifiedUnixMillis: Int64(modifiedSeconds * 1_000),
            modifiedUnixNanoseconds: Int64(modifiedSeconds * 1_000_000_000),
            fileSystemNumber: fileSystem.uint64Value,
            fileNumber: file.uint64Value
        )
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
