import Foundation

/// Owns the single reader for a multiplexed RPC session and correlates control
/// responses by request ID. Transfer routes are layered into this actor so no
/// second consumer can race for bytes from `AsyncFramedTcpSession`.
actor AsyncRpcMultiplexer {
    private static let maxConcurrentTransfers = 2
    private static let maxInFlightControlRequests = 16
    private static let maxDownloadInFlightChunks = 4
    private static let maxDownloadInFlightBytes = 2 * 1024 * 1024
    private static let maxTransferChunkBytes = 1024 * 1024

    private enum State: Equatable {
        case idle
        case active
        case closed
    }

    private struct PendingResponse {
        let waiter: AsyncRpcOneShot<Data>
        var timeoutTask: Task<Void, Never>?
    }

    private struct DownloadRoute {
        let requestID: UInt64
        let transferID: String
        let openWaiter: AsyncRpcOneShot<Data>
        let chunkQueue: AsyncDownloadChunkQueue
        var openTimeoutTask: Task<Void, Never>?
        var openResponse: Droidmatch_V1_OpenTransferResponse?
        var nextExpectedOffsetBytes: Int64 = 0
        var outstandingChunks: [Droidmatch_V1_TransferChunk] = []
        var finalChunkReceived = false
    }

    private struct UploadRoute {
        let requestID: UInt64
        let transferID: String
        let openWaiter: AsyncRpcOneShot<Data>
        var openTimeoutTask: Task<Void, Never>?
        var openResponse: Droidmatch_V1_OpenTransferResponse?
        var uploadWindow = UploadWindow(startingOffsetBytes: 0)
        var outstandingAcknowledgements: [PendingUploadAcknowledgement] = []
    }

    /// Metadata kept in the exact wire-send order. Android processes upload
    /// chunks sequentially, so its ACKs must retire this queue from the head.
    private struct PendingUploadAcknowledgement {
        let waiter: AsyncRpcOneShot<Droidmatch_V1_TransferChunkAck>
        var timeoutTask: Task<Void, Never>?
    }

    private let session: AsyncFramedTcpSession
    private let ownerID = UUID()
    private let requestTimeoutSeconds: TimeInterval

    private var state = State.idle
    private var nextRequestID: UInt64 = 1
    private var pendingResponses: [UInt64: PendingResponse] = [:]
    private var downloads: [UInt64: DownloadRoute] = [:]
    private var uploads: [UInt64: UploadRoute] = [:]
    private var readerTask: Task<Void, Never>?

    init(
        session: AsyncFramedTcpSession,
        requestTimeoutSeconds: TimeInterval = 5
    ) {
        self.session = session
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    deinit {
        readerTask?.cancel()
    }

    func start() async throws {
        switch state {
        case .active:
            return
        case .closed:
            throw AsyncRpcControlClientStateError.closed
        case .idle:
            break
        }
        guard requestTimeoutSeconds > 0, requestTimeoutSeconds.isFinite else {
            throw FramedTcpClientError.timedOut(
                stage: "validating RPC request timeout",
                seconds: requestTimeoutSeconds
            )
        }

        try await session.activateMultiplexing(ownerID: ownerID)
        state = .active
        let session = session
        let ownerID = ownerID
        readerTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let payload = try await session.receiveMultiplexedPayload(ownerID: ownerID)
                    guard let self else {
                        return
                    }
                    try await self.route(payload)
                }
            } catch {
                guard let self else {
                    return
                }
                await self.terminate(with: error)
            }
        }
    }

    func allocateRequestID() throws -> UInt64 {
        guard state == .active else {
            throw AsyncRpcControlClientStateError.closed
        }
        for _ in 0..<64 {
            let requestID = nextRequestID
            nextRequestID = requestID == UInt64.max ? 1 : requestID + 1
            if pendingResponses[requestID] == nil,
               downloads[requestID] == nil,
               uploads[requestID] == nil {
                return requestID
            }
        }
        throw RpcControlClientError.invalidTransferState(
            "could not allocate a free request_id within the bounded in-flight window"
        )
    }

    func sendRequest(_ envelope: Droidmatch_V1_RpcEnvelope) async throws -> Data {
        guard state == .active else {
            throw AsyncRpcControlClientStateError.closed
        }
        guard envelope.kind == .request, envelope.requestID != 0 else {
            throw RpcControlClientError.invalidTransferState(
                "multiplexed RPC requests require request kind and non-zero request_id"
            )
        }
        guard pendingResponses[envelope.requestID] == nil else {
            throw RpcControlClientError.invalidTransferState(
                "request_id \(envelope.requestID) is already pending"
            )
        }
        guard pendingResponses.count < Self.maxInFlightControlRequests else {
            throw RpcControlClientError.invalidTransferState(
                "at most 16 control requests may be in flight"
            )
        }
        // Protobuf encoding failure has not touched the connection and must not
        // poison other routed requests.
        let requestBytes = try envelope.serializedData()

        let waiter = AsyncRpcOneShot<Data>()
        pendingResponses[envelope.requestID] = PendingResponse(
            waiter: waiter,
            timeoutTask: nil
        )
        let timeoutTask = makeTimeoutTask(
            requestID: envelope.requestID,
            waiter: waiter
        )
        pendingResponses[envelope.requestID]?.timeoutTask = timeoutTask

        do {
            try await session.sendMultiplexedPayload(
                requestBytes,
                ownerID: ownerID
            )
        } catch {
            await terminate(with: error)
            throw error
        }

        return try await waiter.wait { [weak self] in
            guard let self else {
                return
            }
            Task {
                await self.terminate(with: CancellationError())
            }
        }
    }

    func openDownload(
        sourcePath: String,
        transferID: String,
        requestedOffsetBytes: Int64,
        sourceFingerprint: Droidmatch_V1_TransferFingerprint?,
        preferredChunkSizeBytes: UInt32
    ) async throws -> AsyncDownloadTransfer {
        guard state == .active else {
            throw AsyncRpcControlClientStateError.closed
        }
        try validateTransferReservation(transferID: transferID)
        guard !sourcePath.isEmpty else {
            throw RpcControlClientError.invalidTransferState(
                "download source path must be non-empty"
            )
        }
        guard requestedOffsetBytes >= 0 else {
            throw RpcControlClientError.invalidTransferState(
                "download requested offset must be non-negative"
            )
        }
        if requestedOffsetBytes > 0, sourceFingerprint == nil {
            throw RpcControlClientError.invalidTransferState(
                "download resume requires a source fingerprint"
            )
        }

        let requestID = try allocateRequestID()
        var request = Droidmatch_V1_OpenTransferRequest()
        request.transferID = transferID
        request.direction = .download
        request.sourcePath = sourcePath
        request.requestedOffsetBytes = requestedOffsetBytes
        request.preferredChunkSizeBytes = preferredChunkSizeBytes
        if let sourceFingerprint {
            request.sourceFingerprint = sourceFingerprint
        }
        let envelope = try RpcEnvelopeCodec.request(
            payload: request,
            payloadType: .openTransferRequest,
            requestID: requestID
        )
        let requestBytes = try envelope.serializedData()
        let chunkQueue = AsyncDownloadChunkQueue(
            capacity: Self.maxDownloadInFlightChunks
        )
        let waiter = AsyncRpcOneShot<Data>()
        downloads[requestID] = DownloadRoute(
            requestID: requestID,
            transferID: transferID,
            openWaiter: waiter,
            chunkQueue: chunkQueue,
            openTimeoutTask: nil
        )
        downloads[requestID]?.openTimeoutTask = makeTransferTimeoutTask(
            requestID: requestID,
            direction: .download,
            waiter: waiter
        )

        do {
            try await session.sendMultiplexedPayload(requestBytes, ownerID: ownerID)
            let responseBytes = try await waiter.wait { [weak self] in
                guard let self else { return }
                Task { await self.terminate(with: CancellationError()) }
            }
            let responseEnvelope = try RpcEnvelopeCodec.response(
                from: responseBytes,
                requestID: requestID,
                expectedPayloadType: .openTransferResponse
            )
            let response = try Droidmatch_V1_OpenTransferResponse(
                serializedBytes: responseEnvelope.payload
            )
            if response.hasError {
                throw RpcControlClientError.remoteError(response.error)
            }
            return AsyncDownloadTransfer(
                openResponse: response,
                requestID: requestID,
                chunkQueue: chunkQueue,
                multiplexer: self
            )
        } catch {
            if !isRemoteApplicationError(error) {
                await terminate(with: error)
            }
            throw error
        }
    }

    func openUpload(
        sourcePath: String,
        destinationPath: String,
        transferID: String,
        requestedOffsetBytes: Int64,
        expectedSizeBytes: Int64,
        preferredChunkSizeBytes: UInt32
    ) async throws -> AsyncUploadTransfer {
        guard state == .active else {
            throw AsyncRpcControlClientStateError.closed
        }
        try validateTransferReservation(transferID: transferID)
        guard !destinationPath.isEmpty else {
            throw RpcControlClientError.invalidTransferState(
                "upload destination path must be non-empty"
            )
        }
        guard requestedOffsetBytes >= 0, expectedSizeBytes >= -1 else {
            throw RpcControlClientError.invalidTransferState(
                "upload offsets or expected size are invalid"
            )
        }

        let requestID = try allocateRequestID()
        var request = Droidmatch_V1_OpenTransferRequest()
        request.transferID = transferID
        request.direction = .upload
        request.sourcePath = sourcePath
        request.destinationPath = destinationPath
        request.requestedOffsetBytes = requestedOffsetBytes
        request.expectedSizeBytes = expectedSizeBytes
        request.preferredChunkSizeBytes = preferredChunkSizeBytes
        let envelope = try RpcEnvelopeCodec.request(
            payload: request,
            payloadType: .openTransferRequest,
            requestID: requestID
        )
        let requestBytes = try envelope.serializedData()
        let waiter = AsyncRpcOneShot<Data>()
        uploads[requestID] = UploadRoute(
            requestID: requestID,
            transferID: transferID,
            openWaiter: waiter,
            openTimeoutTask: nil
        )
        uploads[requestID]?.openTimeoutTask = makeTransferTimeoutTask(
            requestID: requestID,
            direction: .upload,
            waiter: waiter
        )

        do {
            try await session.sendMultiplexedPayload(requestBytes, ownerID: ownerID)
            let responseBytes = try await waiter.wait { [weak self] in
                guard let self else { return }
                Task { await self.terminate(with: CancellationError()) }
            }
            let responseEnvelope = try RpcEnvelopeCodec.response(
                from: responseBytes,
                requestID: requestID,
                expectedPayloadType: .openTransferResponse
            )
            let response = try Droidmatch_V1_OpenTransferResponse(
                serializedBytes: responseEnvelope.payload
            )
            if response.hasError {
                throw RpcControlClientError.remoteError(response.error)
            }
            return AsyncUploadTransfer(
                openResponse: response,
                requestID: requestID,
                multiplexer: self
            )
        } catch {
            if !isRemoteApplicationError(error) {
                await terminate(with: error)
            }
            throw error
        }
    }

    func acknowledgeDownload(
        requestID: UInt64,
        chunk: Droidmatch_V1_TransferChunk
    ) async throws {
        guard var route = downloads[requestID], let open = route.openResponse else {
            throw RpcControlClientError.invalidTransferState("download stream is not active")
        }
        guard let expected = route.outstandingChunks.first, expected == chunk else {
            throw RpcControlClientError.invalidTransferState(
                "download ACK must match the oldest unacknowledged chunk"
            )
        }
        let nextOffset = try validatedEndOffset(chunk)
        var acknowledgement = Droidmatch_V1_TransferChunkAck()
        acknowledgement.transferID = route.transferID
        acknowledgement.nextOffsetBytes = nextOffset
        acknowledgement.finalAck = chunk.finalChunk
        var envelope = Droidmatch_V1_RpcEnvelope()
        envelope.frameVersion = 1
        envelope.kind = .stream
        envelope.requestID = requestID
        envelope.streamID = open.streamID
        envelope.payloadType = .transferChunkAck
        envelope.payload = try acknowledgement.serializedData()

        // Commit the checkpoint before awaiting the send callback. The sole reader
        // may route Android's refill chunks while this actor is re-entrant; writing
        // an old route snapshot after the await would otherwise discard them.
        route.outstandingChunks.removeFirst()
        if chunk.finalChunk {
            route.chunkQueue.finish()
            downloads.removeValue(forKey: requestID)
        } else {
            downloads[requestID] = route
        }
        do {
            try await session.sendMultiplexedPayload(
                envelope.serializedData(),
                ownerID: ownerID
            )
        } catch {
            await terminate(with: error)
            throw error
        }
    }

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
        chunks: [AsyncUploadChunk]
    ) async throws -> [Droidmatch_V1_TransferChunkAck] {
        try preflightUploadWindow(requestID: requestID, chunks: chunks)

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
            acknowledgements.append(try await awaitUploadAcknowledgement(waiter))
        }
        return acknowledgements
    }

    private func preflightUploadWindow(
        requestID: UInt64,
        chunks: [AsyncUploadChunk]
    ) throws {
        guard !chunks.isEmpty else {
            throw RpcControlClientError.invalidTransferState(
                "an upload window must contain at least one chunk"
            )
        }
        guard let route = uploads[requestID], let open = route.openResponse else {
            throw RpcControlClientError.invalidTransferState("upload stream is not active")
        }
        var window = route.uploadWindow
        for chunk in chunks {
            try validateUploadChunk(
                open: open,
                window: window,
                offsetBytes: chunk.offsetBytes,
                data: chunk.data,
                finalChunk: chunk.finalChunk
            )
            window.recordSent(
                offsetBytes: chunk.offsetBytes,
                dataLength: chunk.data.count,
                finalChunk: chunk.finalChunk
            )
        }
    }

    private func submitUploadChunk(
        requestID: UInt64,
        offsetBytes: Int64,
        data: Data,
        finalChunk: Bool
    ) async throws -> AsyncRpcOneShot<Droidmatch_V1_TransferChunkAck> {
        guard var route = uploads[requestID], let open = route.openResponse else {
            throw RpcControlClientError.invalidTransferState("upload stream is not active")
        }
        try validateUploadChunk(
            open: open,
            window: route.uploadWindow,
            offsetBytes: offsetBytes,
            data: data,
            finalChunk: finalChunk
        )

        var chunk = Droidmatch_V1_TransferChunk()
        chunk.transferID = route.transferID
        chunk.offsetBytes = offsetBytes
        chunk.data = data
        chunk.crc32 = Crc32.checksum(data)
        chunk.finalChunk = finalChunk
        var envelope = Droidmatch_V1_RpcEnvelope()
        envelope.frameVersion = 1
        envelope.kind = .stream
        envelope.requestID = requestID
        envelope.streamID = open.streamID
        envelope.payloadType = .transferChunk
        envelope.payload = try chunk.serializedData()
        let envelopeBytes = try envelope.serializedData()

        let waiter = AsyncRpcOneShot<Droidmatch_V1_TransferChunkAck>()
        let timeoutTask = makeUploadAckTimeoutTask(requestID: requestID, waiter: waiter)
        route.uploadWindow.recordSent(
            offsetBytes: offsetBytes,
            dataLength: data.count,
            finalChunk: finalChunk
        )
        route.outstandingAcknowledgements.append(PendingUploadAcknowledgement(
            waiter: waiter,
            timeoutTask: timeoutTask
        ))
        // Commit the send checkpoint before awaiting the transport. Actor
        // re-entrancy may admit the next contiguous chunk while this frame is
        // still waiting for the session's FIFO send lease.
        uploads[requestID] = route

        do {
            try await session.sendMultiplexedPayload(envelopeBytes, ownerID: ownerID)
        } catch {
            await terminate(with: error)
            throw error
        }
        return waiter
    }

    private func validateUploadChunk(
        open: Droidmatch_V1_OpenTransferResponse,
        window: UploadWindow,
        offsetBytes: Int64,
        data: Data,
        finalChunk: Bool
    ) throws {
        guard !window.finalChunkSent else {
            throw RpcControlClientError.invalidTransferState(
                "upload stream already sent its final chunk"
            )
        }
        guard offsetBytes == window.nextSendOffsetBytes else {
            throw RpcControlClientError.offsetMismatch(
                expected: window.nextSendOffsetBytes,
                actual: offsetBytes
            )
        }
        guard data.count <= Int(open.chunkSizeBytes) else {
            throw RpcControlClientError.invalidTransferState(
                "upload chunk exceeds negotiated chunk size"
            )
        }
        guard !data.isEmpty || finalChunk else {
            throw RpcControlClientError.invalidTransferState(
                "empty upload chunks must be final"
            )
        }
        guard !data.isEmpty || window.outstandingChunkCount == 0 else {
            throw RpcControlClientError.invalidTransferState(
                "an empty final upload chunk must wait for earlier chunks to be acknowledged"
            )
        }
        let nextOffset = try validatedEndOffset(
            offsetBytes: offsetBytes,
            dataCount: data.count
        )
        if open.totalSizeBytes >= 0 {
            guard nextOffset <= open.totalSizeBytes,
                  !finalChunk || nextOffset == open.totalSizeBytes else {
                throw RpcControlClientError.invalidTransferState(
                    "upload chunk does not match negotiated total size"
                )
            }
        }
        guard window.outstandingChunkCount < UploadWindow.maxInFlightChunks else {
            throw RpcControlClientError.invalidTransferState(
                "upload stream reached the four-chunk in-flight limit; await an ACK before sending more"
            )
        }
        guard window.outstandingByteCount + Int64(data.count)
                <= UploadWindow.maxInFlightBytes else {
            throw RpcControlClientError.invalidTransferState(
                "upload stream reached the 2 MiB in-flight limit; await an ACK before sending more"
            )
        }
    }

    private func awaitUploadAcknowledgement(
        _ waiter: AsyncRpcOneShot<Droidmatch_V1_TransferChunkAck>
    ) async throws -> Droidmatch_V1_TransferChunkAck {
        do {
            return try await waiter.wait { [weak self] in
                guard let self else { return }
                Task { await self.terminate(with: CancellationError()) }
            }
        } catch is CancellationError {
            // Protocol `cancelTransfer` also wakes outstanding ACK waiters with
            // CancellationError, but the waiting Task itself remains active and
            // the multiplexed session is reusable. Direct Task cancellation is
            // ambiguous after a frame is admitted and must close the session.
            if Task.isCancelled {
                await terminate(with: CancellationError())
            }
            throw CancellationError()
        } catch {
            if !isRemoteApplicationError(error) {
                await terminate(with: error)
            }
            throw error
        }
    }

    func cancelTransfer(requestID: UInt64, reason: String) async throws {
        let transferID: String
        if let route = downloads[requestID] {
            transferID = route.transferID
        } else if let route = uploads[requestID] {
            transferID = route.transferID
        } else {
            throw RpcControlClientError.invalidTransferState("transfer is not active")
        }

        let controlRequestID = try allocateRequestID()
        var request = Droidmatch_V1_CancelTransferRequest()
        request.transferID = transferID
        request.reason = reason
        let envelope = try RpcEnvelopeCodec.request(
            payload: request,
            payloadType: .cancelTransferRequest,
            requestID: controlRequestID
        )
        let responseBytes = try await sendRequest(envelope)
        do {
            let responseEnvelope = try RpcEnvelopeCodec.response(
                from: responseBytes,
                requestID: controlRequestID,
                expectedPayloadType: .cancelTransferResponse
            )
            let response = try Droidmatch_V1_CancelTransferResponse(
                serializedBytes: responseEnvelope.payload
            )
            if response.hasError {
                throw RpcControlClientError.remoteError(response.error)
            }
            guard response.ok, response.transferID == transferID else {
                throw RpcControlClientError.invalidTransferState(
                    "remote did not confirm transfer cancellation"
                )
            }
            finishTransfer(requestID: requestID, error: CancellationError())
        } catch {
            if !isRemoteApplicationError(error) {
                await terminate(with: error)
            }
            throw error
        }
    }

    func close() async {
        await terminate(
            with: FramedTcpClientError.connectionClosed(stage: "closing RPC multiplexer")
        )
    }

    func isClosed() -> Bool {
        state == .closed
    }

    private func route(_ payload: Data) async throws {
        let envelope = try RpcEnvelopeCodec.parse(payload)
        if envelope.kind == .stream {
            try routeStream(envelope)
            return
        }
        guard envelope.kind == .response || envelope.kind == .error else {
            throw RpcControlClientError.unexpectedEnvelope(kind: envelope.kind, payloadType: envelope.payloadType)
        }
        if var pending = pendingResponses.removeValue(forKey: envelope.requestID) {
            pending.timeoutTask?.cancel()
            pending.timeoutTask = nil
            pending.waiter.resolve(.success(payload))
            return
        }
        if downloads[envelope.requestID] != nil {
            try routeDownloadControl(envelope, rawPayload: payload)
            return
        }
        if uploads[envelope.requestID] != nil {
            try routeUploadControl(envelope, rawPayload: payload)
            return
        }
        throw RpcControlClientError.invalidTransferState(
            "received response for unknown request_id \(envelope.requestID)"
        )
    }

    private func routeDownloadControl(
        _ envelope: Droidmatch_V1_RpcEnvelope,
        rawPayload: Data
    ) throws {
        guard var route = downloads[envelope.requestID] else {
            throw RpcControlClientError.invalidTransferState("download route disappeared")
        }
        if envelope.kind == .error {
            let error = RpcControlClientError.remoteError(
                try RpcEnvelopeCodec.errorPayload(from: envelope)
            )
            route.openTimeoutTask?.cancel()
            route.openWaiter.resolve(.success(rawPayload))
            route.chunkQueue.finish(throwing: error)
            downloads.removeValue(forKey: envelope.requestID)
            return
        }
        guard route.openResponse == nil,
              envelope.payloadType == .openTransferResponse else {
            throw RpcControlClientError.unexpectedEnvelope(
                kind: envelope.kind,
                payloadType: envelope.payloadType
            )
        }
        let response = try Droidmatch_V1_OpenTransferResponse(
            serializedBytes: envelope.payload
        )
        route.openTimeoutTask?.cancel()
        route.openTimeoutTask = nil
        if response.hasError {
            let error = RpcControlClientError.remoteError(response.error)
            route.openWaiter.resolve(.success(rawPayload))
            route.chunkQueue.finish(throwing: error)
            downloads.removeValue(forKey: envelope.requestID)
            return
        }
        try validateOpenResponse(
            response,
            requestID: route.requestID,
            transferID: route.transferID
        )
        try validateUniqueStreamID(response.streamID, excludingRequestID: route.requestID)
        route.openResponse = response
        route.nextExpectedOffsetBytes = response.acceptedOffsetBytes
        downloads[envelope.requestID] = route
        route.openWaiter.resolve(.success(rawPayload))
    }

    private func routeUploadControl(
        _ envelope: Droidmatch_V1_RpcEnvelope,
        rawPayload: Data
    ) throws {
        guard var route = uploads[envelope.requestID] else {
            throw RpcControlClientError.invalidTransferState("upload route disappeared")
        }
        if envelope.kind == .error {
            let error = RpcControlClientError.remoteError(
                try RpcEnvelopeCodec.errorPayload(from: envelope)
            )
            if route.openResponse == nil {
                route.openTimeoutTask?.cancel()
                route.openWaiter.resolve(.success(rawPayload))
                uploads.removeValue(forKey: envelope.requestID)
                return
            }
            if !route.outstandingAcknowledgements.isEmpty {
                finishTransfer(requestID: envelope.requestID, error: error)
                return
            }
            throw error
        }
        guard route.openResponse == nil,
              envelope.payloadType == .openTransferResponse else {
            throw RpcControlClientError.unexpectedEnvelope(
                kind: envelope.kind,
                payloadType: envelope.payloadType
            )
        }
        let response = try Droidmatch_V1_OpenTransferResponse(
            serializedBytes: envelope.payload
        )
        route.openTimeoutTask?.cancel()
        route.openTimeoutTask = nil
        if response.hasError {
            route.openWaiter.resolve(.success(rawPayload))
            uploads.removeValue(forKey: envelope.requestID)
            return
        }
        try validateOpenResponse(
            response,
            requestID: route.requestID,
            transferID: route.transferID
        )
        try validateUniqueStreamID(response.streamID, excludingRequestID: route.requestID)
        route.openResponse = response
        route.uploadWindow = UploadWindow(
            startingOffsetBytes: response.acceptedOffsetBytes
        )
        uploads[envelope.requestID] = route
        route.openWaiter.resolve(.success(rawPayload))
    }

    private func routeStream(_ envelope: Droidmatch_V1_RpcEnvelope) throws {
        switch envelope.payloadType {
        case .transferChunk:
            try routeDownloadChunk(envelope)
        case .transferChunkAck:
            try routeUploadAcknowledgement(envelope)
        default:
            throw RpcControlClientError.unexpectedEnvelope(
                kind: envelope.kind,
                payloadType: envelope.payloadType
            )
        }
    }

    private func routeDownloadChunk(_ envelope: Droidmatch_V1_RpcEnvelope) throws {
        guard var route = downloads[envelope.requestID],
              let open = route.openResponse else {
            throw RpcControlClientError.invalidTransferState(
                "received a chunk for an unopened or unknown download stream"
            )
        }
        guard envelope.streamID == open.streamID else {
            throw RpcControlClientError.streamIDMismatch(
                expected: open.streamID,
                actual: envelope.streamID
            )
        }
        guard !route.finalChunkReceived else {
            throw RpcControlClientError.invalidTransferState(
                "received a download chunk after the final chunk"
            )
        }
        guard route.outstandingChunks.count < Self.maxDownloadInFlightChunks else {
            throw RpcControlClientError.invalidTransferState(
                "download stream exceeded the four-chunk in-flight limit"
            )
        }
        let chunk = try Droidmatch_V1_TransferChunk(serializedBytes: envelope.payload)
        guard chunk.transferID == route.transferID else {
            throw RpcControlClientError.transferIDMismatch(
                expected: route.transferID,
                actual: chunk.transferID
            )
        }
        guard chunk.offsetBytes == route.nextExpectedOffsetBytes else {
            throw RpcControlClientError.offsetMismatch(
                expected: route.nextExpectedOffsetBytes,
                actual: chunk.offsetBytes
            )
        }
        guard chunk.data.count <= Int(open.chunkSizeBytes) else {
            throw RpcControlClientError.invalidTransferState(
                "download chunk exceeds negotiated chunk size"
            )
        }
        guard !chunk.data.isEmpty || chunk.finalChunk else {
            throw RpcControlClientError.invalidTransferState(
                "empty download chunks must be final"
            )
        }
        let actualChecksum = Crc32.checksum(chunk.data)
        guard actualChecksum == chunk.crc32 else {
            throw RpcControlClientError.checksumMismatch(
                expected: chunk.crc32,
                actual: actualChecksum
            )
        }
        let nextOffset = try validatedEndOffset(chunk)
        let outstandingBytes = route.outstandingChunks.reduce(0) {
            $0 + $1.data.count
        }
        guard outstandingBytes + chunk.data.count <= Self.maxDownloadInFlightBytes else {
            throw RpcControlClientError.invalidTransferState(
                "download stream exceeded the 2 MiB in-flight limit"
            )
        }
        if open.totalSizeBytes >= 0 {
            guard nextOffset <= open.totalSizeBytes,
                  !chunk.finalChunk || nextOffset == open.totalSizeBytes else {
                throw RpcControlClientError.invalidTransferState(
                    "download chunk does not match negotiated total size"
                )
            }
        }

        route.nextExpectedOffsetBytes = nextOffset
        route.finalChunkReceived = chunk.finalChunk
        route.outstandingChunks.append(chunk)
        guard route.chunkQueue.yield(chunk) else {
            throw RpcControlClientError.invalidTransferState(
                "download consumer exceeded the bounded four-chunk buffer"
            )
        }
        downloads[envelope.requestID] = route
    }

    private func routeUploadAcknowledgement(
        _ envelope: Droidmatch_V1_RpcEnvelope
    ) throws {
        guard var route = uploads[envelope.requestID],
              let open = route.openResponse,
              let pending = route.outstandingAcknowledgements.first else {
            throw RpcControlClientError.invalidTransferState(
                "received an upload ACK with no outstanding chunk"
            )
        }
        guard envelope.streamID == open.streamID else {
            throw RpcControlClientError.streamIDMismatch(
                expected: open.streamID,
                actual: envelope.streamID
            )
        }
        let acknowledgement = try Droidmatch_V1_TransferChunkAck(
            serializedBytes: envelope.payload
        )
        if acknowledgement.hasError {
            finishTransfer(
                requestID: envelope.requestID,
                error: RpcControlClientError.remoteError(acknowledgement.error)
            )
            return
        }
        guard acknowledgement.transferID == route.transferID else {
            throw RpcControlClientError.transferIDMismatch(
                expected: route.transferID,
                actual: acknowledgement.transferID
            )
        }
        let result = try route.uploadWindow.recordAck(
            nextOffsetBytes: acknowledgement.nextOffsetBytes,
            finalAck: acknowledgement.finalAck
        )
        pending.timeoutTask?.cancel()
        route.outstandingAcknowledgements.removeFirst()
        if result.finalAcknowledged {
            uploads.removeValue(forKey: envelope.requestID)
        } else {
            uploads[envelope.requestID] = route
        }
        pending.waiter.resolve(.success(acknowledgement))
    }

    private func validateTransferReservation(transferID: String) throws {
        guard !transferID.isEmpty else {
            throw RpcControlClientError.invalidTransferState(
                "transfer_id must be non-empty"
            )
        }
        guard downloads.count + uploads.count < Self.maxConcurrentTransfers else {
            throw RpcControlClientError.invalidTransferState(
                "at most two transfer streams may be active in one session"
            )
        }
        let duplicateDownload = downloads.values.contains { $0.transferID == transferID }
        let duplicateUpload = uploads.values.contains { $0.transferID == transferID }
        guard !duplicateDownload, !duplicateUpload else {
            throw RpcControlClientError.invalidTransferState(
                "transfer_id is already active in this session"
            )
        }
    }

    private func validateOpenResponse(
        _ response: Droidmatch_V1_OpenTransferResponse,
        requestID: UInt64,
        transferID: String
    ) throws {
        guard response.transferID == transferID else {
            throw RpcControlClientError.transferIDMismatch(
                expected: transferID,
                actual: response.transferID
            )
        }
        guard response.streamID != 0 else {
            throw RpcControlClientError.invalidTransferState(
                "remote returned stream_id=0 for an active transfer"
            )
        }
        guard response.chunkSizeBytes > 0,
              response.chunkSizeBytes <= UInt32(Self.maxTransferChunkBytes) else {
            throw RpcControlClientError.invalidTransferState(
                "remote returned an invalid chunk_size_bytes"
            )
        }
        guard response.acceptedOffsetBytes >= 0,
              response.totalSizeBytes >= -1,
              (response.totalSizeBytes < 0
                || response.acceptedOffsetBytes <= response.totalSizeBytes) else {
            throw RpcControlClientError.invalidTransferState(
                "remote returned invalid transfer offsets for request_id \(requestID)"
            )
        }
    }

    private func validateUniqueStreamID(
        _ streamID: UInt64,
        excludingRequestID: UInt64
    ) throws {
        let downloadCollision = downloads.values.contains {
            $0.requestID != excludingRequestID && $0.openResponse?.streamID == streamID
        }
        let uploadCollision = uploads.values.contains {
            $0.requestID != excludingRequestID && $0.openResponse?.streamID == streamID
        }
        guard !downloadCollision, !uploadCollision else {
            throw RpcControlClientError.invalidTransferState(
                "remote reused an active stream_id"
            )
        }
    }

    private func finishTransfer(requestID: UInt64, error: (any Error)?) {
        if let route = downloads.removeValue(forKey: requestID) {
            route.openTimeoutTask?.cancel()
            if let error {
                route.openWaiter.resolve(.failure(error))
                route.chunkQueue.finish(throwing: error)
            } else {
                route.chunkQueue.finish()
            }
            return
        }
        if let route = uploads.removeValue(forKey: requestID) {
            route.openTimeoutTask?.cancel()
            for pending in route.outstandingAcknowledgements {
                pending.timeoutTask?.cancel()
            }
            if let error {
                route.openWaiter.resolve(.failure(error))
                for pending in route.outstandingAcknowledgements {
                    pending.waiter.resolve(.failure(error))
                }
            } else {
                for pending in route.outstandingAcknowledgements {
                    pending.waiter.resolve(.failure(CancellationError()))
                }
            }
        }
    }

    private func makeTransferTimeoutTask(
        requestID: UInt64,
        direction: Droidmatch_V1_TransferDirection,
        waiter: AsyncRpcOneShot<Data>
    ) -> Task<Void, Never> {
        makeDeadlineTask { [weak self, waiter] in
            guard let self else { return }
            await self.timeoutTransferOpen(
                requestID: requestID,
                direction: direction,
                waiter: waiter
            )
        }
    }

    private func timeoutTransferOpen(
        requestID: UInt64,
        direction: Droidmatch_V1_TransferDirection,
        waiter: AsyncRpcOneShot<Data>
    ) async {
        let stillPending: Bool
        switch direction {
        case .download:
            stillPending = downloads[requestID]?.openWaiter === waiter
                && downloads[requestID]?.openResponse == nil
        case .upload:
            stillPending = uploads[requestID]?.openWaiter === waiter
                && uploads[requestID]?.openResponse == nil
        default:
            stillPending = false
        }
        guard stillPending else { return }
        await terminate(with: FramedTcpClientError.timedOut(
            stage: "waiting for transfer open response \(requestID)",
            seconds: requestTimeoutSeconds
        ))
    }

    private func makeUploadAckTimeoutTask(
        requestID: UInt64,
        waiter: AsyncRpcOneShot<Droidmatch_V1_TransferChunkAck>
    ) -> Task<Void, Never> {
        makeDeadlineTask { [weak self, waiter] in
            guard let self else { return }
            await self.timeoutUploadAck(requestID: requestID, waiter: waiter)
        }
    }

    private func timeoutUploadAck(
        requestID: UInt64,
        waiter: AsyncRpcOneShot<Droidmatch_V1_TransferChunkAck>
    ) async {
        guard uploads[requestID]?.outstandingAcknowledgements.contains(where: {
            $0.waiter === waiter
        }) == true else { return }
        await terminate(with: FramedTcpClientError.timedOut(
            stage: "waiting for upload ACK \(requestID)",
            seconds: requestTimeoutSeconds
        ))
    }

    private func makeDeadlineTask(
        action: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let delayNanoseconds = timeoutDelayNanoseconds()
        return Task {
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            await action()
        }
    }

    private func timeoutDelayNanoseconds() -> UInt64 {
        UInt64(min(requestTimeoutSeconds * 1_000_000_000, Double(UInt64.max)))
    }

    private func validatedEndOffset(
        _ chunk: Droidmatch_V1_TransferChunk
    ) throws -> Int64 {
        try validatedEndOffset(
            offsetBytes: chunk.offsetBytes,
            dataCount: chunk.data.count
        )
    }

    private func validatedEndOffset(
        offsetBytes: Int64,
        dataCount: Int
    ) throws -> Int64 {
        let (endOffset, overflow) = offsetBytes.addingReportingOverflow(Int64(dataCount))
        guard !overflow else {
            throw RpcControlClientError.invalidTransferState(
                "transfer chunk end offset overflowed Int64"
            )
        }
        return endOffset
    }

    private func isRemoteApplicationError(_ error: any Error) -> Bool {
        guard let rpcError = error as? RpcControlClientError else { return false }
        if case .remoteError = rpcError { return true }
        return false
    }

    private func makeTimeoutTask(
        requestID: UInt64,
        waiter: AsyncRpcOneShot<Data>
    ) -> Task<Void, Never> {
        let timeoutSeconds = requestTimeoutSeconds
        let delayNanoseconds = UInt64(
            min(timeoutSeconds * 1_000_000_000, Double(UInt64.max))
        )
        return Task { [weak self, waiter] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard let self else {
                return
            }
            await self.timeoutRequest(requestID: requestID, waiter: waiter)
        }
    }

    private func timeoutRequest(
        requestID: UInt64,
        waiter: AsyncRpcOneShot<Data>
    ) async {
        guard let pending = pendingResponses[requestID], pending.waiter === waiter else {
            return
        }
        let error = FramedTcpClientError.timedOut(
            stage: "waiting for RPC response \(requestID)",
            seconds: requestTimeoutSeconds
        )
        await terminate(with: error)
    }

    private func terminate(with error: any Error) async {
        guard state != .closed else {
            return
        }
        state = .closed
        readerTask?.cancel()
        readerTask = nil

        let pending = pendingResponses.values
        pendingResponses.removeAll(keepingCapacity: false)
        for item in pending {
            item.timeoutTask?.cancel()
            item.waiter.resolve(.failure(error))
        }
        let activeDownloadIDs = Array(downloads.keys)
        let activeUploadIDs = Array(uploads.keys)
        for requestID in activeDownloadIDs + activeUploadIDs {
            finishTransfer(requestID: requestID, error: error)
        }
        await session.close()
    }
}

/// A lock-backed one-shot avoids a response-before-wait race: the sole reader may
/// route a fast response while the sending task is still awaiting its send callback.
final class AsyncRpcOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pendingResult: Result<Value, any Error>?
    private var resolved = false

    func wait(onCancel: @escaping @Sendable () -> Void) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if resolved {
                    let result = pendingResult
                    pendingResult = nil
                    lock.unlock()
                    guard let result else {
                        preconditionFailure("resolved RPC waiter is missing its result")
                    }
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            if self.resolve(.failure(CancellationError())) {
                onCancel()
            }
        }
    }

    @discardableResult
    func resolve(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}
