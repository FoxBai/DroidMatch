import Foundation

/// Shared windowed file-to-transfer pump.
///
/// Connection/session ownership stays with the caller. The recovery coordinator
/// supplies a durable-ACK callback, while mixed-stream smoke can use the same
/// source validation and 4-chunk / 2 MiB window rules without duplicating them.
public struct AsyncUploadFileSender: Sendable {
    public init() {}

    public func send(
        transfer: AsyncUploadTransfer,
        source: AsyncUploadFileSource,
        snapshot: UploadSourceSnapshot,
        sendLimitBytes: Int64? = nil,
        didAcknowledge: @escaping @Sendable (
            Droidmatch_V1_TransferChunkAck
        ) async throws -> Void
    ) async throws -> UploadResult {
        let effectiveLimit = min(sendLimitBytes ?? snapshot.sizeBytes, snapshot.sizeBytes)
        guard effectiveLimit >= transfer.openResponse.acceptedOffsetBytes else {
            throw RpcControlClientError.invalidTransferState(
                "upload send limit precedes the accepted offset"
            )
        }
        let chunkSize = Int(transfer.openResponse.chunkSizeBytes)
        let reader = RefillingUploadChunkReader(
            source: source,
            snapshot: snapshot,
            startingOffset: transfer.openResponse.acceptedOffsetBytes,
            chunkSize: chunkSize,
            sendLimitBytes: effectiveLimit
        )
        let initialChunks = try await reader.initialWindow()
        let acknowledgements = try await transfer.sendRefillingWindow(
            initialChunks: initialChunks,
            nextChunk: { try await reader.nextChunk() },
            didAcknowledge: didAcknowledge
        )
        guard let last = acknowledgements.last, last.finalAck else {
            throw AsyncUploadCoordinatorError.emptyAcknowledgementWindow
        }
        return UploadResult(
            openResponse: transfer.openResponse,
            chunkCount: acknowledgements.count,
            bytesSent: last.nextOffsetBytes - transfer.openResponse.acceptedOffsetBytes,
            finalOffsetBytes: last.nextOffsetBytes
        )
    }

    private func readWindow(
        source: AsyncUploadFileSource,
        snapshot: UploadSourceSnapshot,
        startingOffset: Int64,
        chunkSize: Int,
        sendLimitBytes: Int64
    ) async throws -> [AsyncUploadChunk] {
        var window = UploadWindow(startingOffsetBytes: startingOffset)
        var chunks: [AsyncUploadChunk] = []
        chunks.reserveCapacity(UploadWindow.maxInFlightChunks)
        while window.canSendMore(
            chunkSizeBytes: chunkSize,
            remainingBytes: sendLimitBytes - window.nextSendOffsetBytes
        ) {
            let offset = window.nextSendOffsetBytes
            let byteCount = Int(min(Int64(chunkSize), sendLimitBytes - offset))
            let data = try await source.read(
                offsetBytes: offset,
                byteCount: byteCount,
                expectedSnapshot: snapshot
            )
            let final = offset + Int64(data.count) == snapshot.sizeBytes
            let chunk = AsyncUploadChunk(
                offsetBytes: offset,
                data: data,
                finalChunk: final
            )
            chunks.append(chunk)
            window.recordSent(
                offsetBytes: offset,
                dataLength: data.count,
                finalChunk: final
            )
            if final { break }
        }
        return chunks
    }
}

/// Serial source cursor used by the RPC actor's ACK-driven refill loop.
/// It never reads ahead beyond the negotiated 4-chunk / 2 MiB initial window.
actor RefillingUploadChunkReader {
    let source: AsyncUploadFileSource
    let snapshot: UploadSourceSnapshot
    let chunkSize: Int
    let sendLimitBytes: Int64
    var nextOffset: Int64
    var emittedEmptyFinal = false

    init(
        source: AsyncUploadFileSource,
        snapshot: UploadSourceSnapshot,
        startingOffset: Int64,
        chunkSize: Int,
        sendLimitBytes: Int64
    ) {
        self.source = source
        self.snapshot = snapshot
        self.nextOffset = startingOffset
        self.chunkSize = chunkSize
        self.sendLimitBytes = sendLimitBytes
    }

    func initialWindow() async throws -> [AsyncUploadChunk] {
        var window = UploadWindow(startingOffsetBytes: nextOffset)
        var chunks: [AsyncUploadChunk] = []
        while window.canSendMore(
            chunkSizeBytes: chunkSize,
            remainingBytes: sendLimitBytes - window.nextSendOffsetBytes
        ) {
            guard let chunk = try await nextChunk() else { break }
            chunks.append(chunk)
            window.recordSent(
                offsetBytes: chunk.offsetBytes,
                dataLength: chunk.data.count,
                finalChunk: chunk.finalChunk
            )
            if chunk.finalChunk { break }
        }
        return chunks
    }

    func nextChunk() async throws -> AsyncUploadChunk? {
        try Task.checkCancellation()
        if nextOffset >= sendLimitBytes {
            guard snapshot.sizeBytes == 0, !emittedEmptyFinal else { return nil }
            emittedEmptyFinal = true
            return AsyncUploadChunk(offsetBytes: 0, data: Data(), finalChunk: true)
        }
        let byteCount = Int(min(Int64(chunkSize), sendLimitBytes - nextOffset))
        let data = try await source.read(
            offsetBytes: nextOffset,
            byteCount: byteCount,
            expectedSnapshot: snapshot
        )
        let chunk = AsyncUploadChunk(
            offsetBytes: nextOffset,
            data: data,
            finalChunk: nextOffset + Int64(data.count) == snapshot.sizeBytes
        )
        nextOffset += Int64(data.count)
        return chunk
    }
}
