import Foundation
import SwiftProtobuf

public struct M1SmokeResult: Sendable {
    public let handshake: HandshakeSmokeResult
    public let deviceInfo: Droidmatch_V1_DeviceInfoResponse
    public let diagnostics: Droidmatch_V1_DiagnosticsResponse
}

public struct M1SmokeClient {
    public init() {}

    public func run(
        host: String = "127.0.0.1",
        port: Int,
        timeoutSeconds: TimeInterval = 5
    ) throws -> M1SmokeResult {
        let session = try FramedTcpSession(
            host: host,
            port: port,
            timeoutSeconds: timeoutSeconds
        )
        defer {
            session.close()
        }

        let controlClient = RpcControlClient(session: session)
        return M1SmokeResult(
            handshake: try controlClient.handshake(),
            deviceInfo: try controlClient.deviceInfo(),
            diagnostics: try controlClient.diagnostics()
        )
    }
}

public enum RpcControlClientError: Error, CustomStringConvertible {
    case remoteError(Droidmatch_V1_DroidMatchError)
    case requestIDMismatch(expected: UInt64, actual: UInt64)
    case unexpectedEnvelope(kind: Droidmatch_V1_RpcFrameKind, payloadType: Droidmatch_V1_PayloadType)

    public var description: String {
        switch self {
        case let .remoteError(error):
            return "remote error \(error.code): \(error.message)"
        case let .requestIDMismatch(expected, actual):
            return "response request_id mismatch: expected \(expected), got \(actual)"
        case let .unexpectedEnvelope(kind, payloadType):
            return "unexpected response envelope: kind=\(kind) payload_type=\(payloadType)"
        }
    }
}

public final class RpcControlClient {
    private let session: FramedTcpSession
    private var nextRequestID: UInt64 = 1

    public init(session: FramedTcpSession) {
        self.session = session
    }

    public func handshake() throws -> HandshakeSmokeResult {
        let requestID = allocateRequestID()
        let envelope = try HandshakeSmokeClient().clientHelloEnvelope(requestID: requestID)
        let response = try session.roundTrip(payload: envelope.serializedData())
        return try HandshakeSmokeClient.parseServerHelloResponse(response, expectedRequestID: requestID)
    }

    public func deviceInfo() throws -> Droidmatch_V1_DeviceInfoResponse {
        let requestID = allocateRequestID()
        let envelope = try requestEnvelope(
            payload: Droidmatch_V1_DeviceInfoRequest(),
            payloadType: .deviceInfoRequest,
            requestID: requestID
        )
        let response = try responseEnvelope(
            for: envelope,
            expectedPayloadType: .deviceInfoResponse
        )
        return try Droidmatch_V1_DeviceInfoResponse(serializedBytes: response.payload)
    }

    public func diagnostics() throws -> Droidmatch_V1_DiagnosticsResponse {
        let requestID = allocateRequestID()
        let envelope = try requestEnvelope(
            payload: Droidmatch_V1_DiagnosticsRequest(),
            payloadType: .diagnosticsRequest,
            requestID: requestID
        )
        let response = try responseEnvelope(
            for: envelope,
            expectedPayloadType: .diagnosticsResponse
        )
        return try Droidmatch_V1_DiagnosticsResponse(serializedBytes: response.payload)
    }

    private func requestEnvelope<Payload: SwiftProtobuf.Message>(
        payload: Payload,
        payloadType: Droidmatch_V1_PayloadType,
        requestID: UInt64
    ) throws -> Droidmatch_V1_RpcEnvelope {
        var envelope = Droidmatch_V1_RpcEnvelope()
        envelope.frameVersion = 1
        envelope.kind = .request
        envelope.requestID = requestID
        envelope.payloadType = payloadType
        envelope.payload = try payload.serializedData()
        return envelope
    }

    private func responseEnvelope(
        for request: Droidmatch_V1_RpcEnvelope,
        expectedPayloadType: Droidmatch_V1_PayloadType
    ) throws -> Droidmatch_V1_RpcEnvelope {
        let responseBytes = try session.roundTrip(payload: request.serializedData())
        let response = try Droidmatch_V1_RpcEnvelope(serializedBytes: responseBytes)

        if response.kind == .error {
            throw RpcControlClientError.remoteError(try errorPayload(from: response))
        }
        guard response.kind == .response, response.payloadType == expectedPayloadType else {
            throw RpcControlClientError.unexpectedEnvelope(
                kind: response.kind,
                payloadType: response.payloadType
            )
        }
        guard response.requestID == request.requestID else {
            throw RpcControlClientError.requestIDMismatch(
                expected: request.requestID,
                actual: response.requestID
            )
        }
        return response
    }

    private func allocateRequestID() -> UInt64 {
        defer {
            nextRequestID += 1
        }
        return nextRequestID
    }

    private func errorPayload(from envelope: Droidmatch_V1_RpcEnvelope) throws -> Droidmatch_V1_DroidMatchError {
        if envelope.hasError {
            return envelope.error
        }
        if envelope.payload.isEmpty {
            var error = Droidmatch_V1_DroidMatchError()
            error.code = .protocolError
            error.message = "remote returned error envelope without payload"
            return error
        }
        return try Droidmatch_V1_DroidMatchError(serializedBytes: envelope.payload)
    }
}
