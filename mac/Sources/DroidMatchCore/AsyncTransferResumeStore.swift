import Foundation

public struct DownloadResumeSnapshot: Sendable, Equatable {
    public let record: DownloadResumeRecord?
    public let requestedOffsetBytes: Int64
}

/// Serial, non-cooperative-executor boundary for tiny sidecar filesystem I/O.
/// Atomic JSON writes still complete after caller cancellation so durable state
/// is never intentionally left half-written.
public final class AsyncTransferResumeStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.droidmatch.transfer-resume-store")

    public init() {}

    public func downloadSnapshot(
        destinationURL: URL
    ) async throws -> DownloadResumeSnapshot {
        try await perform {
            let sidecarURL = DownloadResumeRecord.sidecarURL(
                forDestination: destinationURL
            )
            return DownloadResumeSnapshot(
                record: try DownloadResumeRecord.load(from: sidecarURL),
                requestedOffsetBytes: try AtomicDownloadWriter.requestedOffsetBytes(
                    for: destinationURL,
                    resume: true
                )
            )
        }
    }

    public func saveDownload(
        _ record: DownloadResumeRecord,
        destinationURL: URL
    ) async throws {
        try await perform {
            try record.save(to: DownloadResumeRecord.sidecarURL(
                forDestination: destinationURL
            ))
        }
    }

    public func removeDownload(destinationURL: URL) async throws {
        try await perform {
            try DownloadResumeRecord.remove(from: DownloadResumeRecord.sidecarURL(
                forDestination: destinationURL
            ))
        }
    }

    public func prepareFreshDownload(destinationURL: URL) async throws {
        try await perform {
            try DownloadResumeRecord.remove(from: DownloadResumeRecord.sidecarURL(
                forDestination: destinationURL
            ))
            let partialURL = AtomicDownloadWriter.partialURL(for: destinationURL)
            if FileManager.default.fileExists(atPath: partialURL.path) {
                try FileManager.default.removeItem(at: partialURL)
            }
        }
    }

    public func loadUpload(sourceURL: URL) async throws -> UploadResumeRecord? {
        try await perform {
            try UploadResumeRecord.load(from: UploadResumeRecord.sidecarURL(
                forSource: sourceURL
            ))
        }
    }

    public func saveUpload(_ record: UploadResumeRecord, sourceURL: URL) async throws {
        try await perform {
            try record.save(to: UploadResumeRecord.sidecarURL(forSource: sourceURL))
        }
    }

    public func removeUpload(sourceURL: URL) async throws {
        try await perform {
            try UploadResumeRecord.remove(from: UploadResumeRecord.sidecarURL(
                forSource: sourceURL
            ))
        }
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
