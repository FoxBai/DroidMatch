import Foundation

public struct DualDownloadStreamResult: Sendable {
    public let openResponse: Droidmatch_V1_OpenTransferResponse
    public let chunkCount: Int
    public let bytesReceived: Int64
    public let finalOffsetBytes: Int64
}

public struct DualDownloadSmokeResult: Sendable {
    public let handshake: HandshakeSmokeResult
    public let heartbeat: Droidmatch_V1_HeartbeatResponse
    public let first: DualDownloadStreamResult
    public let second: DualDownloadStreamResult
}

/// Async evidence probe that keeps two downloads active on one multiplexed RPC
/// session and proves control traffic remains responsive before either stream is
/// acknowledged. Production and evidence paths now exercise the same router.
public struct AsyncDualDownloadSmokeClient: Sendable {
    private let client: AsyncRpcControlClient

    public init(client: AsyncRpcControlClient) {
        self.client = client
    }

    public func run(
        firstSourcePath: String,
        secondSourcePath: String,
        firstTransferID: String = UUID().uuidString,
        secondTransferID: String = UUID().uuidString,
        preferredChunkSizeBytes: UInt32 = 256 * 1024,
        receiveChunk: @escaping @Sendable (Int, Droidmatch_V1_TransferChunk) async throws -> Void = { _, _ in }
    ) async throws -> DualDownloadSmokeResult {
        guard !firstSourcePath.isEmpty, !secondSourcePath.isEmpty else {
            throw RpcControlClientError.invalidTransferState(
                "dual download source paths must be non-empty"
            )
        }
        guard !firstTransferID.isEmpty,
              !secondTransferID.isEmpty,
              firstTransferID != secondTransferID else {
            throw RpcControlClientError.invalidTransferState(
                "dual download transfer IDs must be non-empty and distinct"
            )
        }

        let handshake = try await client.handshake()
        async let firstOpen = client.openDownload(
            sourcePath: firstSourcePath,
            transferID: firstTransferID,
            preferredChunkSizeBytes: preferredChunkSizeBytes
        )
        async let secondOpen = client.openDownload(
            sourcePath: secondSourcePath,
            transferID: secondTransferID,
            preferredChunkSizeBytes: preferredChunkSizeBytes
        )
        let (first, second) = try await (firstOpen, secondOpen)
        guard first.openResponse.streamID != second.openResponse.streamID else {
            throw RpcControlClientError.invalidTransferState(
                "dual download streams must use distinct stream IDs"
            )
        }

        // Do this before starting either consumer. The multiplexer may buffer
        // chunks, but Android cannot receive an ACK until heartbeat completes.
        let heartbeatMillis = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
        let heartbeat = try await client.heartbeat(monotonicMillis: heartbeatMillis)
        guard heartbeat.monotonicMillis == heartbeatMillis else {
            throw RpcControlClientError.invalidTransferState(
                "dual download heartbeat did not echo monotonic_millis"
            )
        }

        var firstAccumulator = StreamAccumulator(transfer: first)
        var secondAccumulator = StreamAccumulator(transfer: second)
        // Alternate consumers explicitly so evidence remains deterministic while
        // the multiplexer reader continues routing both streams independently.
        while !firstAccumulator.completed || !secondAccumulator.completed {
            if !firstAccumulator.completed {
                try await firstAccumulator.consumeNext(index: 0, receiveChunk: receiveChunk)
            }
            if !secondAccumulator.completed {
                try await secondAccumulator.consumeNext(index: 1, receiveChunk: receiveChunk)
            }
        }
        return DualDownloadSmokeResult(
            handshake: handshake,
            heartbeat: heartbeat,
            first: firstAccumulator.result,
            second: secondAccumulator.result
        )
    }

    private struct StreamAccumulator {
        let transfer: AsyncDownloadTransfer
        var chunkCount = 0
        var bytesReceived: Int64 = 0
        var finalOffset: Int64
        var completed = false

        init(transfer: AsyncDownloadTransfer) {
            self.transfer = transfer
            finalOffset = transfer.openResponse.acceptedOffsetBytes
        }

        mutating func consumeNext(
            index: Int,
            receiveChunk: @escaping @Sendable (Int, Droidmatch_V1_TransferChunk) async throws -> Void
        ) async throws {
            guard let chunk = try await transfer.nextChunk() else {
                throw AsyncDownloadFileError.streamEndedBeforeFinalChunk
            }
            try await receiveChunk(index, chunk)
            try await transfer.acknowledge(chunk)
            chunkCount += 1
            bytesReceived += Int64(chunk.data.count)
            finalOffset = chunk.offsetBytes + Int64(chunk.data.count)
            completed = chunk.finalChunk
        }

        var result: DualDownloadStreamResult {
            DualDownloadStreamResult(
                openResponse: transfer.openResponse,
                chunkCount: chunkCount,
                bytesReceived: bytesReceived,
                finalOffsetBytes: finalOffset
            )
        }
    }
}
