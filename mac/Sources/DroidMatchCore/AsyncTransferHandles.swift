import Foundation

/// One ordered upload submission used by `AsyncUploadTransfer.sendWindow`.
/// A window is preflighted in full before its first frame reaches the wire.
public struct AsyncUploadChunk: Sendable, Equatable {
    public let offsetBytes: Int64
    public let data: Data
    public let finalChunk: Bool

    public init(offsetBytes: Int64, data: Data, finalChunk: Bool) {
        self.offsetBytes = offsetBytes
        self.data = data
        self.finalChunk = finalChunk
    }
}

public enum AsyncDownloadFileError: Error, CustomStringConvertible, Sendable, Equatable {
    case acceptedOffsetMismatch(local: Int64, remote: Int64)
    case streamEndedBeforeFinalChunk

    public var description: String {
        switch self {
        case let .acceptedOffsetMismatch(local, remote):
            return "download writer offset \(local) does not match remote accepted offset \(remote)"
        case .streamEndedBeforeFinalChunk:
            return "download stream ended before a final chunk was acknowledged"
        }
    }
}

public actor AsyncDownloadTransfer {
    public nonisolated let openResponse: Droidmatch_V1_OpenTransferResponse

    private let multiplexer: AsyncRpcMultiplexer
    private let requestID: UInt64
    private let chunkQueue: AsyncDownloadChunkQueue
    private var waitingForChunk = false
    private var fileReceiveInProgress = false

    init(
        openResponse: Droidmatch_V1_OpenTransferResponse,
        requestID: UInt64,
        chunkQueue: AsyncDownloadChunkQueue,
        multiplexer: AsyncRpcMultiplexer
    ) {
        self.openResponse = openResponse
        self.requestID = requestID
        self.chunkQueue = chunkQueue
        self.multiplexer = multiplexer
    }

    /// Returns chunks in wire-offset order. Only one outstanding `nextChunk`
    /// call is allowed per handle; multiple transfers may wait concurrently.
    public func nextChunk() async throws -> Droidmatch_V1_TransferChunk? {
        guard !fileReceiveInProgress else {
            throw RpcControlClientError.invalidTransferState(
                "manual chunk reads cannot run during atomic file receive"
            )
        }
        return try await nextQueuedChunk()
    }

    private func nextQueuedChunk() async throws -> Droidmatch_V1_TransferChunk? {
        guard !waitingForChunk else {
            throw RpcControlClientError.invalidTransferState(
                "a download transfer may have only one pending nextChunk call"
            )
        }
        waitingForChunk = true
        defer { waitingForChunk = false }
        return try await chunkQueue.next()
    }

    /// ACKs one yielded chunk. The router verifies it is the oldest unacknowledged
    /// chunk for this stream before advancing the durable receiver checkpoint.
    public func acknowledge(_ chunk: Droidmatch_V1_TransferChunk) async throws {
        guard !fileReceiveInProgress else {
            throw RpcControlClientError.invalidTransferState(
                "manual ACKs cannot run during atomic file receive"
            )
        }
        try await acknowledgeQueuedChunk(chunk)
    }

    /// Receives the complete stream into a sibling `.droidmatch-part` file and
    /// atomically replaces the destination only after the final ACK is sent.
    ///
    /// For resume, callers first query `AtomicDownloadWriter.requestedOffsetBytes`
    /// and use that value plus the saved source fingerprint when opening this
    /// transfer. This method rechecks the accepted offset before writing, keeping
    /// the destination untouched if local state changed between inspection/open.
    public func receive(
        to destinationURL: URL,
        resume: Bool = false,
        onProgress: AsyncTransferProgressObserver? = nil
    ) async throws -> DownloadResult {
        guard !fileReceiveInProgress, !waitingForChunk else {
            throw RpcControlClientError.invalidTransferState(
                "an atomic file receive is already active on this download handle"
            )
        }
        fileReceiveInProgress = true
        defer { fileReceiveInProgress = false }

        let writer: AsyncAtomicDownloadWriter
        do {
            writer = try await AsyncAtomicDownloadWriter.create(
                destinationURL: destinationURL,
                resume: resume
            )
        } catch {
            await cancelAfterLocalFileFailure()
            throw error
        }
        return try await receive(using: writer, onProgress: onProgress)
    }

    @discardableResult
    public func cancel(
        reason: String = "mac-client-cancel"
    ) async throws -> Droidmatch_V1_CancelTransferResponse {
        try await multiplexer.cancelTransfer(requestID: requestID, reason: reason)
    }

    /// Pauses at the last acknowledged boundary. A currently yielded chunk is
    /// deliberately not ACKed, so the returned offset remains resume-safe.
    public func pause() async throws -> Droidmatch_V1_PauseTransferResponse {
        try await multiplexer.pauseTransfer(requestID: requestID)
    }

    private func receive(
        using writer: AsyncAtomicDownloadWriter,
        onProgress: AsyncTransferProgressObserver?
    ) async throws -> DownloadResult {
        var finalAcknowledged = false
        do {
            guard writer.requestedOffsetBytes == openResponse.acceptedOffsetBytes else {
                throw AsyncDownloadFileError.acceptedOffsetMismatch(
                    local: writer.requestedOffsetBytes,
                    remote: openResponse.acceptedOffsetBytes
                )
            }

            // The coordinator has already stored the transfer fingerprint;
            // report its accepted offset only after this second local partial
            // inspection closes the filesystem race between snapshot and open.
            await onProgress?(AsyncTransferProgress(
                confirmedBytes: openResponse.acceptedOffsetBytes,
                totalBytes: openResponse.totalSizeBytes
            ))

            var expectedOffset = openResponse.acceptedOffsetBytes
            var chunkCount = 0
            var bytesReceived: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let chunk = try await nextQueuedChunk() else {
                    throw AsyncDownloadFileError.streamEndedBeforeFinalChunk
                }
                guard chunk.offsetBytes == expectedOffset else {
                    throw RpcControlClientError.offsetMismatch(
                        expected: expectedOffset,
                        actual: chunk.offsetBytes
                    )
                }

                try await writer.write(chunk.data)
                // Never acknowledge bytes after the owning task was cancelled.
                // Closing the session forces a later resume from actual part size.
                try Task.checkCancellation()
                try await acknowledgeQueuedChunk(chunk)

                let nextOffset = chunk.offsetBytes + Int64(chunk.data.count)
                expectedOffset = nextOffset
                chunkCount += 1
                bytesReceived += Int64(chunk.data.count)

                if chunk.finalChunk {
                    finalAcknowledged = true
                    try Task.checkCancellation()
                    try await writer.commit()
                    return DownloadResult(
                        openResponse: openResponse,
                        chunkCount: chunkCount,
                        bytesReceived: bytesReceived,
                        finalOffsetBytes: nextOffset
                    )
                }

                // Product progress must never lead the offset that a retry can
                // safely request. The final update is emitted by the coordinator
                // only after atomic commit and sidecar cleanup both succeed.
                await onProgress?(AsyncTransferProgress(
                    confirmedBytes: nextOffset,
                    totalBytes: openResponse.totalSizeBytes
                ))
            }
        } catch {
            try? await writer.close()
            if error is CancellationError {
                if Task.isCancelled {
                    await multiplexer.close()
                }
            } else if !finalAcknowledged {
                await cancelAfterLocalFileFailure()
            }
            throw error
        }
    }

    private func acknowledgeQueuedChunk(_ chunk: Droidmatch_V1_TransferChunk) async throws {
        try await multiplexer.acknowledgeDownload(requestID: requestID, chunk: chunk)
    }

    private func cancelAfterLocalFileFailure() async {
        _ = try? await multiplexer.cancelTransfer(
            requestID: requestID,
            reason: "mac-local-download-file-failure"
        )
    }
}

public actor AsyncUploadTransfer {
    public nonisolated let openResponse: Droidmatch_V1_OpenTransferResponse

    private let multiplexer: AsyncRpcMultiplexer
    private let requestID: UInt64
    private var operationInProgress = false

    init(
        openResponse: Droidmatch_V1_OpenTransferResponse,
        requestID: UInt64,
        multiplexer: AsyncRpcMultiplexer
    ) {
        self.openResponse = openResponse
        self.requestID = requestID
        self.multiplexer = multiplexer
    }

    /// Sends one upload chunk and waits for its matching stream ACK.
    ///
    /// Use `sendWindow` for deterministic multi-chunk windowing. Only one send
    /// operation may own a handle at a time; separate transfer handles still run
    /// concurrently on the same multiplexed session.
    /// Cancelling an admitted call closes the session because its wire ACK can no
    /// longer be correlated safely; all sibling calls are then woken with failure.
    public func sendChunk(
        offsetBytes: Int64,
        data: Data,
        finalChunk: Bool
    ) async throws -> Droidmatch_V1_TransferChunkAck {
        try beginOperation()
        defer { operationInProgress = false }
        return try await multiplexer.sendUploadChunk(
            requestID: requestID,
            offsetBytes: offsetBytes,
            data: data,
            finalChunk: finalChunk
        )
    }

    /// Sends one preflighted window in wire-offset order, then returns its ACKs
    /// in the same order. The router admits at most four chunks or 2 MiB, matching
    /// Android's receiver limits. Invalid later chunks cannot leave an earlier
    /// prefix on the wire because validation completes before sending begins.
    public func sendWindow(
        _ chunks: [AsyncUploadChunk]
    ) async throws -> [Droidmatch_V1_TransferChunkAck] {
        try await sendWindow(chunks) { _ in }
    }

    /// Sends a bounded window and reports each validated ACK in wire order.
    ///
    /// A product scheduler uses this hook to persist `nextOffsetBytes` before
    /// admitting the next source window. If checkpoint persistence fails while
    /// later chunks are already in flight, the multiplexer closes the ambiguous
    /// session so those ACKs cannot be mistaken for durable progress.
    public func sendWindow(
        _ chunks: [AsyncUploadChunk],
        didAcknowledge: @escaping @Sendable (
            Droidmatch_V1_TransferChunkAck
        ) async throws -> Void
    ) async throws -> [Droidmatch_V1_TransferChunkAck] {
        try beginOperation()
        defer { operationInProgress = false }
        return try await multiplexer.sendUploadWindow(
            requestID: requestID,
            chunks: chunks,
            didAcknowledge: didAcknowledge
        )
    }

    @discardableResult
    public func cancel(
        reason: String = "mac-client-cancel"
    ) async throws -> Droidmatch_V1_CancelTransferResponse {
        // Actor re-entrancy intentionally permits protocol cancellation while a
        // send window is suspended on ACKs. The multiplexer completes those ACK
        // waiters with CancellationError after the remote confirms cancellation.
        return try await multiplexer.cancelTransfer(requestID: requestID, reason: reason)
    }

    private func beginOperation() throws {
        guard !operationInProgress else {
            throw RpcControlClientError.invalidTransferState(
                "an upload handle may run only one send operation at a time"
            )
        }
        operationInProgress = true
    }
}

/// Bounded lock-backed queue used by the public download handle. The RPC actor is
/// the only producer; exactly one consumer may wait at a time.
final class AsyncDownloadChunkQueue: @unchecked Sendable {
    private enum NextAction {
        case immediate(Result<Droidmatch_V1_TransferChunk?, any Error>)
        case wait(AsyncRpcOneShot<Droidmatch_V1_TransferChunk?>)
    }

    private let lock = NSLock()
    private let capacity: Int
    private var buffered: [Droidmatch_V1_TransferChunk] = []
    private var waiter: AsyncRpcOneShot<Droidmatch_V1_TransferChunk?>?
    private var terminalResult: Result<Void, any Error>?

    init(capacity: Int) {
        self.capacity = capacity
    }

    func next() async throws -> Droidmatch_V1_TransferChunk? {
        switch prepareNext() {
        case let .immediate(result):
            return try result.get()
        case let .wait(waiter):
            return try await waiter.wait { [weak self, waiter] in
                self?.removeCancelledWaiter(waiter)
            }
        }
    }

    private func prepareNext() -> NextAction {
        lock.lock()
        if !buffered.isEmpty {
            let chunk = buffered.removeFirst()
            lock.unlock()
            return .immediate(.success(chunk))
        }
        if let terminalResult {
            lock.unlock()
            switch terminalResult {
            case .success:
                return .immediate(.success(nil))
            case let .failure(error):
                return .immediate(.failure(error))
            }
        }
        guard waiter == nil else {
            lock.unlock()
            return .immediate(.failure(RpcControlClientError.invalidTransferState(
                "download queue already has a waiting consumer"
            )))
        }
        let waiter = AsyncRpcOneShot<Droidmatch_V1_TransferChunk?>()
        self.waiter = waiter
        lock.unlock()
        return .wait(waiter)
    }

    @discardableResult
    func yield(_ chunk: Droidmatch_V1_TransferChunk) -> Bool {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return false
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resolve(.success(chunk))
            return true
        }
        guard buffered.count < capacity else {
            lock.unlock()
            return false
        }
        buffered.append(chunk)
        lock.unlock()
        return true
    }

    func finish(throwing error: (any Error)? = nil) {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = error.map(Result.failure) ?? .success(())
        buffered.removeAll(keepingCapacity: false)
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        if let error {
            waiter?.resolve(.failure(error))
        } else {
            waiter?.resolve(.success(nil))
        }
    }

    private func removeCancelledWaiter(
        _ candidate: AsyncRpcOneShot<Droidmatch_V1_TransferChunk?>
    ) {
        lock.lock()
        if waiter === candidate {
            waiter = nil
        }
        lock.unlock()
    }
}
