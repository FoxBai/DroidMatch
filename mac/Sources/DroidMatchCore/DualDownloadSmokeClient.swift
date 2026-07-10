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

/// Scripted M1 proof that two download streams can remain active on one session.
///
/// This is deliberately separate from the established single-stream client. It
/// sends both OpenTransfer requests before consuming either stream to make both
/// remote readers active, routes interleaved frames by request/stream ID, and
/// requires a Heartbeat response before acknowledging either first chunk. The
/// latter proves control-plane work is not starved by the two data-plane streams.
public final class DualDownloadSmokeClient {
    private let session: FramedTcpSession
    private var nextRequestID: UInt64 = 1

    public init(session: FramedTcpSession) {
        self.session = session
    }

    public func run(
        firstSourcePath: String,
        secondSourcePath: String,
        firstTransferID: String = UUID().uuidString,
        secondTransferID: String = UUID().uuidString,
        preferredChunkSizeBytes: UInt32 = 256 * 1024,
        receiveChunk: (Int, Droidmatch_V1_TransferChunk) throws -> Void = { _, _ in }
    ) throws -> DualDownloadSmokeResult {
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

        let handshake = try performHandshake()
        let first = try sendOpen(
            sourcePath: firstSourcePath,
            transferID: firstTransferID,
            preferredChunkSizeBytes: preferredChunkSizeBytes
        )
        let second = try sendOpen(
            sourcePath: secondSourcePath,
            transferID: secondTransferID,
            preferredChunkSizeBytes: preferredChunkSizeBytes
        )
        let states = [first, second]
        let statesByRequestID = Dictionary(
            uniqueKeysWithValues: states.map { ($0.requestID, $0) }
        )

        // Open responses precede their stream chunks, but frames from the first
        // stream may arrive before the second OpenTransferResponse. Route instead
        // of assuming the next frame belongs to the most recent call.
        while states.contains(where: { $0.openResponse == nil }) {
            _ = try receiveAndRoute(
                statesByRequestID: statesByRequestID,
                heartbeatRequestID: nil
            )
        }
        guard first.openResponse?.streamID != second.openResponse?.streamID else {
            throw RpcControlClientError.invalidTransferState(
                "dual download streams must use distinct stream IDs"
            )
        }

        let heartbeatRequestID = allocateRequestID()
        let heartbeatMillis = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
        var heartbeatRequest = Droidmatch_V1_HeartbeatRequest()
        heartbeatRequest.monotonicMillis = heartbeatMillis
        let heartbeatEnvelope = try RpcEnvelopeCodec.request(
            payload: heartbeatRequest,
            payloadType: .heartbeatRequest,
            requestID: heartbeatRequestID
        )
        try session.sendPayload(heartbeatEnvelope.serializedData())

        var heartbeat: Droidmatch_V1_HeartbeatResponse?
        while heartbeat == nil {
            heartbeat = try receiveAndRoute(
                statesByRequestID: statesByRequestID,
                heartbeatRequestID: heartbeatRequestID
            )
        }
        guard let heartbeat, heartbeat.monotonicMillis == heartbeatMillis else {
            throw RpcControlClientError.invalidTransferState(
                "dual download heartbeat did not echo monotonic_millis"
            )
        }

        // Fair scripted scheduling: process at most one queued chunk per stream
        // before rotating. When neither stream has buffered data, read one frame
        // and route it. This supports Android's four-chunk refill window without
        // coupling TCP frame order to either transfer.
        var cursor = 0
        while states.contains(where: { !$0.completed }) {
            var processedChunk = false
            for offset in 0..<states.count {
                let index = (cursor + offset) % states.count
                let state = states[index]
                guard !state.completed, let chunk = state.popPendingChunk() else {
                    continue
                }
                try receiveChunk(index, chunk)
                try sendAcknowledgement(for: state, chunk: chunk)
                try state.recordAcknowledged(chunk)
                cursor = (index + 1) % states.count
                processedChunk = true
                break
            }
            if !processedChunk {
                let unexpectedHeartbeat = try receiveAndRoute(
                    statesByRequestID: statesByRequestID,
                    heartbeatRequestID: nil
                )
                if unexpectedHeartbeat != nil {
                    throw RpcControlClientError.invalidTransferState(
                        "received an unsolicited heartbeat response"
                    )
                }
            }
        }

        return DualDownloadSmokeResult(
            handshake: handshake,
            heartbeat: heartbeat,
            first: try first.result(),
            second: try second.result()
        )
    }

    private func performHandshake() throws -> HandshakeSmokeResult {
        let requestID = allocateRequestID()
        let client = HandshakeSmokeClient(requestedCapabilities: [
            .fileRead,
            .resumableTransfer,
            .diagnostics,
        ])
        let request = try client.clientHelloEnvelope(requestID: requestID)
        let response = try session.roundTrip(payload: request.serializedData())
        return try client.parseServerHelloResponse(response, expectedRequestID: requestID)
    }

    private func sendOpen(
        sourcePath: String,
        transferID: String,
        preferredChunkSizeBytes: UInt32
    ) throws -> PendingDualDownload {
        let requestID = allocateRequestID()
        var request = Droidmatch_V1_OpenTransferRequest()
        request.transferID = transferID
        request.direction = .download
        request.sourcePath = sourcePath
        request.preferredChunkSizeBytes = preferredChunkSizeBytes
        let envelope = try RpcEnvelopeCodec.request(
            payload: request,
            payloadType: .openTransferRequest,
            requestID: requestID
        )
        let state = PendingDualDownload(requestID: requestID, transferID: transferID)
        try session.sendPayload(envelope.serializedData())
        return state
    }

    private func receiveAndRoute(
        statesByRequestID: [UInt64: PendingDualDownload],
        heartbeatRequestID: UInt64?
    ) throws -> Droidmatch_V1_HeartbeatResponse? {
        let envelope = try RpcEnvelopeCodec.parse(session.receivePayload())
        if envelope.kind == .error {
            throw RpcControlClientError.remoteError(
                try RpcEnvelopeCodec.errorPayload(from: envelope)
            )
        }
        if envelope.kind == .response,
           envelope.payloadType == .heartbeatResponse,
           envelope.requestID == heartbeatRequestID {
            return try Droidmatch_V1_HeartbeatResponse(serializedBytes: envelope.payload)
        }
        guard let state = statesByRequestID[envelope.requestID] else {
            throw RpcControlClientError.invalidTransferState(
                "received a frame for unknown request_id \(envelope.requestID)"
            )
        }
        if envelope.kind == .response, envelope.payloadType == .openTransferResponse {
            try state.acceptOpen(envelope)
            return nil
        }
        if envelope.kind == .stream, envelope.payloadType == .transferChunk {
            try state.acceptChunk(envelope)
            return nil
        }
        throw RpcControlClientError.unexpectedEnvelope(
            kind: envelope.kind,
            payloadType: envelope.payloadType
        )
    }

    private func sendAcknowledgement(
        for state: PendingDualDownload,
        chunk: Droidmatch_V1_TransferChunk
    ) throws {
        guard let openResponse = state.openResponse else {
            throw RpcControlClientError.invalidTransferState(
                "cannot acknowledge a dual download before OpenTransferResponse"
            )
        }
        var acknowledgement = Droidmatch_V1_TransferChunkAck()
        acknowledgement.transferID = chunk.transferID
        acknowledgement.nextOffsetBytes = try validatedChunkEndOffset(chunk)
        acknowledgement.finalAck = chunk.finalChunk
        var envelope = Droidmatch_V1_RpcEnvelope()
        envelope.frameVersion = 1
        envelope.kind = .stream
        envelope.requestID = state.requestID
        envelope.streamID = openResponse.streamID
        envelope.payloadType = .transferChunkAck
        envelope.payload = try acknowledgement.serializedData()
        try session.sendPayload(envelope.serializedData())
    }

    private func allocateRequestID() -> UInt64 {
        let requestID = nextRequestID
        nextRequestID = requestID == UInt64.max ? 1 : requestID + 1
        return requestID
    }
}

private final class PendingDualDownload {
    let requestID: UInt64
    let transferID: String
    private(set) var openResponse: Droidmatch_V1_OpenTransferResponse?
    private(set) var completed = false

    private var nextExpectedChunkOffset: Int64 = 0
    private var acknowledgedOffset: Int64 = 0
    private var pendingChunks: [Droidmatch_V1_TransferChunk] = []
    private var pendingHead = 0
    private var finalChunkReceived = false
    private var chunkCount = 0
    private var bytesReceived: Int64 = 0

    init(requestID: UInt64, transferID: String) {
        self.requestID = requestID
        self.transferID = transferID
    }

    func acceptOpen(_ envelope: Droidmatch_V1_RpcEnvelope) throws {
        guard openResponse == nil else {
            throw RpcControlClientError.invalidTransferState(
                "received duplicate OpenTransferResponse for request_id \(requestID)"
            )
        }
        let response = try Droidmatch_V1_OpenTransferResponse(serializedBytes: envelope.payload)
        if response.hasError {
            throw RpcControlClientError.remoteError(response.error)
        }
        guard response.transferID == transferID else {
            throw RpcControlClientError.transferIDMismatch(
                expected: transferID,
                actual: response.transferID
            )
        }
        guard response.streamID != 0 else {
            throw RpcControlClientError.invalidTransferState(
                "remote returned stream_id=0 for dual download"
            )
        }
        guard response.chunkSizeBytes > 0 else {
            throw RpcControlClientError.invalidTransferState(
                "remote returned chunk_size_bytes=0 for dual download"
            )
        }
        guard response.acceptedOffsetBytes >= 0,
              response.totalSizeBytes < 0
                || response.acceptedOffsetBytes <= response.totalSizeBytes else {
            throw RpcControlClientError.invalidTransferState(
                "remote returned invalid dual download offsets"
            )
        }
        openResponse = response
        nextExpectedChunkOffset = response.acceptedOffsetBytes
        acknowledgedOffset = response.acceptedOffsetBytes
    }

    func acceptChunk(_ envelope: Droidmatch_V1_RpcEnvelope) throws {
        guard let openResponse else {
            throw RpcControlClientError.invalidTransferState(
                "received TransferChunk before OpenTransferResponse"
            )
        }
        guard !finalChunkReceived else {
            throw RpcControlClientError.invalidTransferState(
                "received TransferChunk after final chunk"
            )
        }
        guard envelope.streamID == openResponse.streamID else {
            throw RpcControlClientError.streamIDMismatch(
                expected: openResponse.streamID,
                actual: envelope.streamID
            )
        }
        let chunk = try Droidmatch_V1_TransferChunk(serializedBytes: envelope.payload)
        guard chunk.transferID == transferID else {
            throw RpcControlClientError.transferIDMismatch(
                expected: transferID,
                actual: chunk.transferID
            )
        }
        guard chunk.offsetBytes == nextExpectedChunkOffset else {
            throw RpcControlClientError.offsetMismatch(
                expected: nextExpectedChunkOffset,
                actual: chunk.offsetBytes
            )
        }
        guard chunk.data.count <= Int(openResponse.chunkSizeBytes) else {
            throw RpcControlClientError.invalidTransferState(
                "dual download chunk exceeds negotiated chunk size"
            )
        }
        guard !chunk.data.isEmpty || chunk.finalChunk else {
            throw RpcControlClientError.invalidTransferState(
                "dual download received an empty non-final chunk"
            )
        }
        let actualChecksum = Crc32.checksum(chunk.data)
        guard actualChecksum == chunk.crc32 else {
            throw RpcControlClientError.checksumMismatch(
                expected: chunk.crc32,
                actual: actualChecksum
            )
        }
        let nextOffset = try validatedChunkEndOffset(chunk)
        if openResponse.totalSizeBytes >= 0 {
            guard nextOffset <= openResponse.totalSizeBytes else {
                throw RpcControlClientError.invalidTransferState(
                    "dual download exceeded total_size_bytes"
                )
            }
            if chunk.finalChunk, nextOffset != openResponse.totalSizeBytes {
                throw RpcControlClientError.invalidTransferState(
                    "dual download final chunk does not end at total_size_bytes"
                )
            }
        }
        nextExpectedChunkOffset = nextOffset
        finalChunkReceived = chunk.finalChunk
        pendingChunks.append(chunk)
    }

    func popPendingChunk() -> Droidmatch_V1_TransferChunk? {
        guard pendingHead < pendingChunks.count else {
            return nil
        }
        let chunk = pendingChunks[pendingHead]
        pendingHead += 1
        if pendingHead == pendingChunks.count {
            pendingChunks.removeAll(keepingCapacity: true)
            pendingHead = 0
        }
        return chunk
    }

    func recordAcknowledged(_ chunk: Droidmatch_V1_TransferChunk) throws {
        let nextOffset = try validatedChunkEndOffset(chunk)
        guard chunk.offsetBytes == acknowledgedOffset else {
            throw RpcControlClientError.offsetMismatch(
                expected: acknowledgedOffset,
                actual: chunk.offsetBytes
            )
        }
        acknowledgedOffset = nextOffset
        chunkCount += 1
        bytesReceived += Int64(chunk.data.count)
        if chunk.finalChunk {
            completed = true
        }
    }

    func result() throws -> DualDownloadStreamResult {
        guard let openResponse, completed else {
            throw RpcControlClientError.invalidTransferState(
                "dual download result requested before completion"
            )
        }
        return DualDownloadStreamResult(
            openResponse: openResponse,
            chunkCount: chunkCount,
            bytesReceived: bytesReceived,
            finalOffsetBytes: acknowledgedOffset
        )
    }
}

private func validatedChunkEndOffset(
    _ chunk: Droidmatch_V1_TransferChunk
) throws -> Int64 {
    let (endOffset, overflow) = chunk.offsetBytes.addingReportingOverflow(
        Int64(chunk.data.count)
    )
    guard !overflow else {
        throw RpcControlClientError.invalidTransferState(
            "dual download chunk end offset overflowed Int64"
        )
    }
    return endOffset
}
