import Foundation

/// Owns the single reader for a multiplexed RPC session and correlates control
/// responses by request ID. Transfer routes are layered into this actor so no
/// second consumer can race for bytes from `AsyncFramedTcpSession`.
actor AsyncRpcMultiplexer {
    private static let maxInFlightControlRequests = 16

    private let session: AsyncFramedTcpSession
    private let sendGate: AsyncRpcSendGate
    private let ownerID = UUID()
    let requestTimeoutSeconds: TimeInterval

    private var state = AsyncRpcMultiplexerLifecycle.idle
    private var terminalError: (any Error)?
    private var requestIDAllocator = AsyncRpcRequestIDAllocator()
    var pendingResponses: [UInt64: AsyncRpcPendingResponse] = [:]
    var downloads: [UInt64: AsyncRpcDownloadRoute] = [:]
    var uploads: [UInt64: AsyncRpcUploadRoute] = [:]
    private var readerTask: Task<Void, Never>?

    init(
        session: AsyncFramedTcpSession,
        requestTimeoutSeconds: TimeInterval = 5,
        sendGate: AsyncRpcSendGate = AsyncRpcSendGate()
    ) {
        self.session = session
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.sendGate = sendGate
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
        let occupied = Set(pendingResponses.keys)
            .union(downloads.keys)
            .union(uploads.keys)
        return try requestIDAllocator.allocate(occupied: occupied)
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
        pendingResponses[envelope.requestID] = AsyncRpcPendingResponse(
            waiter: waiter,
            timeoutTask: nil
        )
        let timeoutTask = makeTimeoutTask(
            requestID: envelope.requestID,
            waiter: waiter
        )
        pendingResponses[envelope.requestID]?.timeoutTask = timeoutTask

        do {
            try await sendPayload(requestBytes)
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
        try AsyncRpcTransferValidation.validateTransferReservation(
            transferID: transferID,
            downloads: downloads,
            uploads: uploads
        )

        let requestID = try allocateRequestID()
        let requestBytes = try AsyncRpcTransferFrames.openDownload(
            requestID: requestID,
            sourcePath: sourcePath,
            transferID: transferID,
            requestedOffsetBytes: requestedOffsetBytes,
            sourceFingerprint: sourceFingerprint,
            preferredChunkSizeBytes: preferredChunkSizeBytes
        )
        let chunkQueue = AsyncDownloadChunkQueue(
            capacity: AsyncRpcTransferValidation.maxDownloadInFlightChunks
        )
        let terminalState = AsyncRpcDownloadTerminalState()
        let waiter = AsyncRpcOneShot<Data>()
        downloads[requestID] = AsyncRpcDownloadRoute(
            requestID: requestID,
            transferID: transferID,
            openWaiter: waiter,
            chunkQueue: chunkQueue,
            terminalState: terminalState,
            openTimeoutTask: nil
        )
        downloads[requestID]?.openTimeoutTask = makeTransferTimeoutTask(
            requestID: requestID,
            direction: .download,
            waiter: waiter
        )

        do {
            try await sendPayload(requestBytes)
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
                terminalState: terminalState,
                multiplexer: self
            )
        } catch {
            if !AsyncRpcTransferValidation.isRemoteApplicationError(error) {
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
        try AsyncRpcTransferValidation.validateTransferReservation(
            transferID: transferID,
            downloads: downloads,
            uploads: uploads
        )

        let requestID = try allocateRequestID()
        let requestBytes = try AsyncRpcTransferFrames.openUpload(
            requestID: requestID,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            transferID: transferID,
            requestedOffsetBytes: requestedOffsetBytes,
            expectedSizeBytes: expectedSizeBytes,
            preferredChunkSizeBytes: preferredChunkSizeBytes
        )
        let waiter = AsyncRpcOneShot<Data>()
        uploads[requestID] = AsyncRpcUploadRoute(
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
            try await sendPayload(requestBytes)
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
            if !AsyncRpcTransferValidation.isRemoteApplicationError(error) {
                await terminate(with: error)
            }
            throw error
        }
    }

    func acknowledgeDownload(
        requestID: UInt64,
        chunk: Droidmatch_V1_TransferChunk,
        terminalState: AsyncRpcDownloadTerminalState
    ) async throws {
        // A write can outlive route teardown. Prefer the first transport or
        // transfer-scoped remote failure and never emit an ACK after it.
        if let error = terminalState.error() {
            throw error
        }
        guard state == .active else {
            throw terminalError ?? AsyncRpcControlClientStateError.closed
        }
        guard let route = downloads[requestID], let open = route.openResponse else {
            throw RpcControlClientError.invalidTransferState("download stream is not active")
        }
        guard let expected = route.outstandingChunks.first, expected == chunk else {
            throw RpcControlClientError.invalidTransferState(
                "download ACK must match the oldest unacknowledged chunk"
            )
        }
        let acknowledgementBytes = try AsyncRpcTransferFrames.downloadAcknowledgement(
            requestID: requestID,
            streamID: open.streamID,
            transferID: route.transferID,
            chunk: chunk
        )

        let sendLease = try await sendGate.acquire()
        do {
            // Acquiring the FIFO lease is an actor re-entry point. Re-read the
            // route and its first-error latch at the actual send admission edge.
            if let error = terminalState.error() {
                throw error
            }
            guard state == .active else {
                throw terminalError ?? AsyncRpcControlClientStateError.closed
            }
            guard var admittedRoute = downloads[requestID],
                  admittedRoute.openResponse != nil else {
                throw RpcControlClientError.invalidTransferState(
                    "download stream is not active"
                )
            }
            guard admittedRoute.outstandingChunks.first == chunk else {
                throw RpcControlClientError.invalidTransferState(
                    "download ACK must match the oldest unacknowledged chunk"
                )
            }
            // Commit before the transport await so refill chunks routed during
            // the send cannot be overwritten by an older route snapshot. Keep a
            // final route recognizable until the ACK send itself succeeds.
            admittedRoute.outstandingChunks.removeFirst()
            downloads[requestID] = admittedRoute
        } catch {
            await sendGate.release(sendLease)
            throw error
        }
        do {
            try await session.sendMultiplexedPayload(
                acknowledgementBytes,
                ownerID: ownerID
            )
            await sendGate.release(sendLease)
        } catch {
            await sendGate.release(sendLease)
            await terminate(with: error)
            throw error
        }
        if let error = terminalState.error() {
            throw error
        }
        if chunk.finalChunk, let completed = downloads.removeValue(forKey: requestID) {
            completed.chunkQueue.finish()
        }
    }

    func submitUploadChunk(
        requestID: UInt64,
        offsetBytes: Int64,
        data: Data,
        finalChunk: Bool
    ) async throws -> AsyncRpcOneShot<Droidmatch_V1_TransferChunkAck> {
        // The reader can terminate the actor while the refilling sender is
        // suspended in its durable-checkpoint or source-read callback. Preserve
        // the transport failure so recovery policy sees a retryable error rather
        // than the secondary fact that teardown removed the upload route.
        guard state == .active else {
            throw terminalError ?? AsyncRpcControlClientStateError.closed
        }
        guard var route = uploads[requestID], let open = route.openResponse else {
            throw RpcControlClientError.invalidTransferState("upload stream is not active")
        }
        try AsyncRpcTransferValidation.validateUploadChunk(
            open: open,
            window: route.uploadWindow,
            offsetBytes: offsetBytes,
            data: data,
            finalChunk: finalChunk
        )

        let envelopeBytes = try AsyncRpcTransferFrames.uploadChunk(
            requestID: requestID,
            streamID: open.streamID,
            transferID: route.transferID,
            offsetBytes: offsetBytes,
            data: data,
            finalChunk: finalChunk
        )

        let waiter = AsyncRpcOneShot<Droidmatch_V1_TransferChunkAck>()
        let timeoutTask = makeUploadAckTimeoutTask(requestID: requestID, waiter: waiter)
        route.uploadWindow.recordSent(
            offsetBytes: offsetBytes,
            dataLength: data.count,
            finalChunk: finalChunk
        )
        route.outstandingAcknowledgements.append(AsyncRpcPendingUploadAcknowledgement(
            waiter: waiter,
            timeoutTask: timeoutTask
        ))
        // Commit the send checkpoint before awaiting the transport. Actor
        // re-entrancy may admit the next contiguous chunk while this frame is
        // still waiting for the session's FIFO send lease.
        uploads[requestID] = route

        do {
            try await sendPayload(envelopeBytes)
        } catch {
            await terminate(with: error)
            throw error
        }
        return waiter
    }

    func awaitUploadAcknowledgement(
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
            if !AsyncRpcTransferValidation.isRemoteApplicationError(error) {
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
            route.terminalState.record(error)
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
            route.terminalState.record(error)
            route.openWaiter.resolve(.success(rawPayload))
            route.chunkQueue.finish(throwing: error)
            downloads.removeValue(forKey: envelope.requestID)
            return
        }
        try AsyncRpcTransferValidation.validateOpenResponse(
            response,
            requestID: route.requestID,
            transferID: route.transferID
        )
        try AsyncRpcTransferValidation.validateUniqueStreamID(
            response.streamID,
            excludingRequestID: route.requestID,
            downloads: downloads,
            uploads: uploads
        )
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
        try AsyncRpcTransferValidation.validateOpenResponse(
            response,
            requestID: route.requestID,
            transferID: route.transferID
        )
        try AsyncRpcTransferValidation.validateUniqueStreamID(
            response.streamID,
            excludingRequestID: route.requestID,
            downloads: downloads,
            uploads: uploads
        )
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
        let validated = try AsyncRpcTransferValidation.validateDownloadChunk(
            envelope: envelope,
            route: route,
            open: open
        )
        route.nextExpectedOffsetBytes = validated.nextOffsetBytes
        route.finalChunkReceived = validated.chunk.finalChunk
        route.outstandingChunks.append(validated.chunk)
        guard route.chunkQueue.yield(validated.chunk) else {
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

    func finishTransfer(requestID: UInt64, error: (any Error)?) {
        if let route = downloads.removeValue(forKey: requestID) {
            route.openTimeoutTask?.cancel()
            if let error {
                route.terminalState.record(error)
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

    func terminate(with error: any Error) async {
        guard state != .closed else {
            return
        }
        terminalError = error
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
        await sendGate.close(with: error)
        await session.close()
    }

    private func sendPayload(_ payload: Data) async throws {
        let sendLease = try await sendGate.acquire()
        do {
            try await session.sendMultiplexedPayload(payload, ownerID: ownerID)
            await sendGate.release(sendLease)
        } catch {
            await sendGate.release(sendLease)
            throw error
        }
    }
}
