import Foundation

/// Moves blocking Foundation file operations off Swift's cooperative executor.
/// The wrapped writer is created and used only on this private serial queue.
final class AsyncAtomicDownloadWriter: @unchecked Sendable {
    let requestedOffsetBytes: Int64

    private let queue: DispatchQueue
    private let writer: AtomicDownloadWriter

    private init(queue: DispatchQueue, writer: AtomicDownloadWriter) {
        self.queue = queue
        self.writer = writer
        self.requestedOffsetBytes = writer.requestedOffsetBytes
    }

    static func create(
        destinationURL: URL,
        resume: Bool,
        deferFreshReset: Bool = false,
        expectedDirectoryIdentity: LocalDirectoryIdentity? = nil,
        directoryContext: LocalDownloadDirectoryContext? = nil
    ) async throws -> AsyncAtomicDownloadWriter {
        let queue = DispatchQueue(
            label: "app.droidmatch.download-writer.\(UUID().uuidString)"
        )
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let writer = try AtomicDownloadWriter(
                        destinationURL: destinationURL,
                        resume: resume,
                        deferFreshReset: deferFreshReset,
                        expectedDirectoryIdentity: expectedDirectoryIdentity,
                        directoryContext: directoryContext
                    )
                    continuation.resume(returning: AsyncAtomicDownloadWriter(
                        queue: queue,
                        writer: writer
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        try await perform {
            try self.writer.write(data)
        }
    }

    func resetFresh() async throws {
        try await perform {
            try self.writer.resetFresh()
        }
    }

    func commit(retainRecoveryMarker: Bool = false) async throws {
        try await perform {
            try self.writer.commit(retainRecoveryMarker: retainRecoveryMarker)
        }
    }

    func finalizeCommit() async throws {
        try await perform {
            try self.writer.finalizeCommit()
        }
    }

    func rollbackCommit(retainRecoveryMarker: Bool = false) async throws {
        try await perform {
            try self.writer.rollbackCommit(
                retainRecoveryMarker: retainRecoveryMarker
            )
        }
    }

    func finalizeRollback() async throws {
        try await perform {
            try self.writer.finalizeRollback()
        }
    }

    func close() async throws {
        try await perform {
            try self.writer.close()
        }
    }

    private func perform(
        _ operation: @escaping @Sendable () throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try operation()
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
