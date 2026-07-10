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
        var nextOffset = transfer.openResponse.acceptedOffsetBytes
        var bytesSent: Int64 = 0
        var chunkCount = 0

        while true {
            try Task.checkCancellation()
            let chunks = try await readWindow(
                source: source,
                snapshot: snapshot,
                startingOffset: nextOffset,
                chunkSize: chunkSize,
                sendLimitBytes: effectiveLimit
            )
            let acknowledgements = try await transfer.sendWindow(
                chunks,
                didAcknowledge: didAcknowledge
            )
            guard let last = acknowledgements.last else {
                throw AsyncUploadCoordinatorError.emptyAcknowledgementWindow
            }
            bytesSent += chunks.reduce(0) { $0 + Int64($1.data.count) }
            chunkCount += chunks.count
            nextOffset = last.nextOffsetBytes
            if last.finalAck {
                return UploadResult(
                    openResponse: transfer.openResponse,
                    chunkCount: chunkCount,
                    bytesSent: bytesSent,
                    finalOffsetBytes: nextOffset
                )
            }
        }
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
