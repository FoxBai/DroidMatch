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
        destinationURL: URL,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil
    ) async throws -> DownloadResumeSnapshot {
        try await perform {
            let sidecarURL = DownloadResumeRecord.sidecarURL(
                forDestination: destinationURL
            )
            return DownloadResumeSnapshot(
                record: try DownloadResumeRecord.load(
                    from: sidecarURL,
                    expectedDirectoryIdentity: expectedDirectoryIdentity,
                    directoryContext: directoryContext
                ),
                requestedOffsetBytes: try AtomicDownloadWriter.requestedOffsetBytes(
                    for: destinationURL,
                    resume: true,
                    expectedDirectoryIdentity: expectedDirectoryIdentity,
                    directoryContext: directoryContext
                )
            )
        }
    }

    public func saveDownload(
        _ record: DownloadResumeRecord,
        destinationURL: URL,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil
    ) async throws {
        try await perform {
            try record.save(
                to: DownloadResumeRecord.sidecarURL(forDestination: destinationURL),
                expectedDirectoryIdentity: expectedDirectoryIdentity,
                directoryContext: directoryContext
            )
        }
    }

    public func removeDownload(
        destinationURL: URL,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil
    ) async throws {
        try await perform {
            try DownloadResumeRecord.remove(
                from: DownloadResumeRecord.sidecarURL(forDestination: destinationURL),
                expectedDirectoryIdentity: expectedDirectoryIdentity,
                directoryContext: directoryContext
            )
        }
    }

    public func prepareFreshDownload(
        destinationURL: URL,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil
    ) async throws {
        try await perform {
            try DownloadResumeRecord.remove(
                from: DownloadResumeRecord.sidecarURL(forDestination: destinationURL),
                expectedDirectoryIdentity: expectedDirectoryIdentity,
                directoryContext: directoryContext
            )
        }
    }

    public func loadUpload(sourceURL: URL) async throws -> UploadResumeRecord? {
        try await loadUpload(recordURL: UploadResumeRecord.sidecarURL(forSource: sourceURL))
    }

    public func loadUpload(recordURL: URL) async throws -> UploadResumeRecord? {
        try await perform {
            try UploadResumeRecord.load(from: recordURL)
        }
    }

    public func saveUpload(_ record: UploadResumeRecord, sourceURL: URL) async throws {
        try await saveUpload(record, recordURL: UploadResumeRecord.sidecarURL(forSource: sourceURL))
    }

    public func saveUpload(_ record: UploadResumeRecord, recordURL: URL) async throws {
        try await perform {
            try record.save(to: recordURL)
        }
    }

    public func removeUpload(sourceURL: URL) async throws {
        try await removeUpload(recordURL: UploadResumeRecord.sidecarURL(forSource: sourceURL))
    }

    public func removeUpload(recordURL: URL) async throws {
        try await perform {
            try UploadResumeRecord.remove(from: recordURL)
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
