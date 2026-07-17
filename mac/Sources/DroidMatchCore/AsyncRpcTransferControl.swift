import Foundation

extension AsyncRpcMultiplexer {
    func cancelTransfer(
        requestID: UInt64,
        reason: String
    ) async throws -> Droidmatch_V1_CancelTransferResponse {
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
        let responseBytes = try await sendRequest(
            envelope,
            expectedPayloadType: .cancelTransferResponse,
            payloadValidator: { payload in
                _ = try Droidmatch_V1_CancelTransferResponse(serializedBytes: payload)
            }
        )
        do {
            let responseEnvelope = try RpcEnvelopeCodec.response(
                from: responseBytes,
                requestID: controlRequestID,
                expectedPayloadType: .cancelTransferResponse
            )
            let response = try Droidmatch_V1_CancelTransferResponse(
                serializedBytes: responseEnvelope.payload
            )
            try validate(response, transferID: transferID)
            finishTransfer(requestID: requestID, error: CancellationError())
            return response
        } catch {
            try await handleTransferControlError(error)
        }
    }

    func pauseTransfer(requestID: UInt64) async throws -> Droidmatch_V1_PauseTransferResponse {
        guard let route = downloads[requestID] else {
            throw RpcControlClientError.invalidTransferState(
                "only an active download can be paused by this client"
            )
        }
        let transferID = route.transferID
        let controlRequestID = try allocateRequestID()
        var request = Droidmatch_V1_PauseTransferRequest()
        request.transferID = transferID
        let envelope = try RpcEnvelopeCodec.request(
            payload: request,
            payloadType: .pauseTransferRequest,
            requestID: controlRequestID
        )
        let responseBytes = try await sendRequest(
            envelope,
            expectedPayloadType: .pauseTransferResponse,
            payloadValidator: { payload in
                _ = try Droidmatch_V1_PauseTransferResponse(serializedBytes: payload)
            }
        )
        do {
            let responseEnvelope = try RpcEnvelopeCodec.response(
                from: responseBytes,
                requestID: controlRequestID,
                expectedPayloadType: .pauseTransferResponse
            )
            let response = try Droidmatch_V1_PauseTransferResponse(
                serializedBytes: responseEnvelope.payload
            )
            try validate(response, transferID: transferID)
            finishTransfer(requestID: requestID, error: CancellationError())
            return response
        } catch {
            try await handleTransferControlError(error)
        }
    }

    private func validate(
        _ response: Droidmatch_V1_CancelTransferResponse,
        transferID: String
    ) throws {
        if response.hasError { throw RpcControlClientError.remoteError(response.error) }
        guard response.ok, response.transferID == transferID else {
            throw RpcControlClientError.invalidTransferState(
                "remote did not confirm transfer cancellation"
            )
        }
    }

    private func validate(
        _ response: Droidmatch_V1_PauseTransferResponse,
        transferID: String
    ) throws {
        if response.hasError { throw RpcControlClientError.remoteError(response.error) }
        guard response.ok, response.transferID == transferID else {
            throw RpcControlClientError.invalidTransferState(
                "remote did not confirm transfer pause"
            )
        }
    }

    private func handleTransferControlError(_ error: any Error) async throws -> Never {
        if !AsyncRpcTransferValidation.isRemoteApplicationError(error) {
            await terminate(with: error)
        }
        throw error
    }
}
