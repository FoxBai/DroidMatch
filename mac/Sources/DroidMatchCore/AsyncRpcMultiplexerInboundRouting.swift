import Foundation

/// Actor-isolated application of inbound control responses and transfer frames.
///
/// The core multiplexer still owns the only reader and every route table. This
/// extension only groups the parsing, waiter resolution, and route mutation
/// reached from that reader; it introduces no second state or execution owner.
extension AsyncRpcMultiplexer {
    func route(_ payload: Data) async throws {
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
            route.terminalState.record(error)
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
            uploads.removeValue(forKey: envelope.requestID)
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
            route.terminalState.record(RpcControlClientError.remoteError(response.error))
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
}
