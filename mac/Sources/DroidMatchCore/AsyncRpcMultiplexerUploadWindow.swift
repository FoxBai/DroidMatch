import Foundation

/// Upload-window orchestration for `AsyncRpcMultiplexer`.
///
/// The actor remains the sole owner of route mutation, ACK waiters, and socket
/// sends. This extension only groups the producer/consumer sequencing so the
/// core multiplexer stays focused on lifecycle and inbound frame routing.
extension AsyncRpcMultiplexer {
    func sendUploadChunk(
        requestID: UInt64,
        offsetBytes: Int64,
        data: Data,
        finalChunk: Bool
    ) async throws -> Droidmatch_V1_TransferChunkAck {
        let waiter = try await submitUploadChunk(
            requestID: requestID,
            offsetBytes: offsetBytes,
            data: data,
            finalChunk: finalChunk
        )
        return try await awaitUploadAcknowledgement(waiter)
    }

    func sendUploadWindow(
        requestID: UInt64,
        chunks: [AsyncUploadChunk],
        didAcknowledge: @escaping @Sendable (
            Droidmatch_V1_TransferChunkAck
        ) async throws -> Void
    ) async throws -> [Droidmatch_V1_TransferChunkAck] {
        try AsyncRpcTransferValidation.preflightUploadWindow(
            route: uploads[requestID],
            chunks: chunks
        )

        // Submit every frame before awaiting the first ACK. This deterministic
        // producer loop fills the window without depending on sibling Task
        // scheduling or actor mailbox fairness.
        var waiters: [AsyncRpcOneShot<Droidmatch_V1_TransferChunkAck>] = []
        waiters.reserveCapacity(chunks.count)
        for chunk in chunks {
            waiters.append(try await submitUploadChunk(
                requestID: requestID,
                offsetBytes: chunk.offsetBytes,
                data: chunk.data,
                finalChunk: chunk.finalChunk
            ))
        }

        var acknowledgements: [Droidmatch_V1_TransferChunkAck] = []
        acknowledgements.reserveCapacity(waiters.count)
        for waiter in waiters {
            let acknowledgement = try await awaitUploadAcknowledgement(waiter)
            do {
                try await didAcknowledge(acknowledgement)
            } catch {
                // Later frames in this window may already have reached Android.
                // A failed durable checkpoint makes their eventual ACKs unsafe
                // to associate with another operation, so end this session.
                await terminate(with: error)
                throw error
            }
            acknowledgements.append(acknowledgement)
        }
        return acknowledgements
    }

    /// Keeps a bounded upload window full by admitting one replacement only
    /// after the oldest ACK is validated and durably observed by the caller.
    func sendRefillingUploadWindow(
        requestID: UInt64,
        initialChunks: [AsyncUploadChunk],
        nextChunk: @escaping @Sendable () async throws -> AsyncUploadChunk?,
        didAcknowledge: @escaping @Sendable (Droidmatch_V1_TransferChunkAck) async throws -> Void
    ) async throws -> [Droidmatch_V1_TransferChunkAck] {
        try AsyncRpcTransferValidation.preflightUploadWindow(
            route: uploads[requestID], chunks: initialChunks
        )
        var waiters: [AsyncRpcOneShot<Droidmatch_V1_TransferChunkAck>] = []
        for chunk in initialChunks {
            waiters.append(try await submitUploadChunk(
                requestID: requestID,
                offsetBytes: chunk.offsetBytes,
                data: chunk.data,
                finalChunk: chunk.finalChunk
            ))
        }
        var acknowledgements: [Droidmatch_V1_TransferChunkAck] = []
        while !waiters.isEmpty {
            let acknowledgement = try await awaitUploadAcknowledgement(waiters.removeFirst())
            do {
                try await didAcknowledge(acknowledgement)
                if !acknowledgement.finalAck, let chunk = try await nextChunk() {
                    waiters.append(try await submitUploadChunk(
                        requestID: requestID,
                        offsetBytes: chunk.offsetBytes,
                        data: chunk.data,
                        finalChunk: chunk.finalChunk
                    ))
                }
            } catch {
                // Other frames can still be in flight. Closing is required so
                // their ACKs cannot be associated with a non-durable checkpoint.
                await terminate(with: error)
                throw error
            }
            acknowledgements.append(acknowledgement)
        }
        return acknowledgements
    }
}
