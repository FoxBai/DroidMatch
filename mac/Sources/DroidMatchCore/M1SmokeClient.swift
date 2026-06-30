import Foundation
import SwiftProtobuf

public struct M1SmokeResult: Sendable {
    public let handshake: HandshakeSmokeResult
    public let deviceInfo: Droidmatch_V1_DeviceInfoResponse
    public let rootList: Droidmatch_V1_ListDirResponse
    public let diagnostics: Droidmatch_V1_DiagnosticsResponse
}

public struct DownloadOnceResult: Sendable {
    public let openResponse: Droidmatch_V1_OpenTransferResponse
    public let chunk: Droidmatch_V1_TransferChunk
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
            rootList: try controlClient.listDir(path: "dm://roots/"),
            diagnostics: try controlClient.diagnostics()
        )
    }
}

public enum RpcControlClientError: Error, CustomStringConvertible {
    case remoteError(Droidmatch_V1_DroidMatchError)
    case requestIDMismatch(expected: UInt64, actual: UInt64)
    case streamIDMismatch(expected: UInt64, actual: UInt64)
    case transferIDMismatch(expected: String, actual: String)
    case unexpectedEnvelope(kind: Droidmatch_V1_RpcFrameKind, payloadType: Droidmatch_V1_PayloadType)
    case checksumMismatch(expected: UInt32, actual: UInt32)

    public var description: String {
        switch self {
        case let .remoteError(error):
            return "remote error \(error.code): \(error.message)"
        case let .requestIDMismatch(expected, actual):
            return "response request_id mismatch: expected \(expected), got \(actual)"
        case let .streamIDMismatch(expected, actual):
            return "stream_id mismatch: expected \(expected), got \(actual)"
        case let .transferIDMismatch(expected, actual):
            return "transfer_id mismatch: expected \(expected), got \(actual)"
        case let .unexpectedEnvelope(kind, payloadType):
            return "unexpected response envelope: kind=\(kind) payload_type=\(payloadType)"
        case let .checksumMismatch(expected, actual):
            return "transfer chunk checksum mismatch: expected \(expected), got \(actual)"
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

    public func listDir(path: String) throws -> Droidmatch_V1_ListDirResponse {
        let requestID = allocateRequestID()
        var request = Droidmatch_V1_ListDirRequest()
        request.path = path
        let envelope = try requestEnvelope(
            payload: request,
            payloadType: .listDirRequest,
            requestID: requestID
        )
        let response = try responseEnvelope(
            for: envelope,
            expectedPayloadType: .listDirResponse
        )
        return try Droidmatch_V1_ListDirResponse(serializedBytes: response.payload)
    }

    public func downloadFirstChunk(
        sourcePath: String,
        destinationPath: String = "",
        transferID: String = UUID().uuidString,
        preferredChunkSizeBytes: UInt32 = 256 * 1024
    ) throws -> DownloadOnceResult {
        let requestID = allocateRequestID()
        var request = Droidmatch_V1_OpenTransferRequest()
        request.transferID = transferID
        request.direction = .download
        request.sourcePath = sourcePath
        request.destinationPath = destinationPath
        request.preferredChunkSizeBytes = preferredChunkSizeBytes
        let envelope = try requestEnvelope(
            payload: request,
            payloadType: .openTransferRequest,
            requestID: requestID
        )
        try session.sendPayload(envelope.serializedData())

        let openEnvelope = try parseEnvelope(try session.receivePayload())
        if openEnvelope.kind == .error {
            throw RpcControlClientError.remoteError(try errorPayload(from: openEnvelope))
        }
        guard openEnvelope.kind == .response, openEnvelope.payloadType == .openTransferResponse else {
            throw RpcControlClientError.unexpectedEnvelope(
                kind: openEnvelope.kind,
                payloadType: openEnvelope.payloadType
            )
        }
        guard openEnvelope.requestID == requestID else {
            throw RpcControlClientError.requestIDMismatch(expected: requestID, actual: openEnvelope.requestID)
        }
        let openResponse = try Droidmatch_V1_OpenTransferResponse(serializedBytes: openEnvelope.payload)
        if openResponse.hasError {
            throw RpcControlClientError.remoteError(openResponse.error)
        }
        guard openResponse.transferID == transferID else {
            throw RpcControlClientError.transferIDMismatch(
                expected: transferID,
                actual: openResponse.transferID
            )
        }

        let chunkEnvelope = try parseEnvelope(try session.receivePayload())
        guard chunkEnvelope.kind == .stream, chunkEnvelope.payloadType == .transferChunk else {
            throw RpcControlClientError.unexpectedEnvelope(
                kind: chunkEnvelope.kind,
                payloadType: chunkEnvelope.payloadType
            )
        }
        guard chunkEnvelope.requestID == requestID else {
            throw RpcControlClientError.requestIDMismatch(expected: requestID, actual: chunkEnvelope.requestID)
        }
        guard chunkEnvelope.streamID == openResponse.streamID else {
            throw RpcControlClientError.streamIDMismatch(
                expected: openResponse.streamID,
                actual: chunkEnvelope.streamID
            )
        }
        let chunk = try Droidmatch_V1_TransferChunk(serializedBytes: chunkEnvelope.payload)
        guard chunk.transferID == openResponse.transferID else {
            throw RpcControlClientError.transferIDMismatch(
                expected: openResponse.transferID,
                actual: chunk.transferID
            )
        }
        let actualCrc = Crc32.checksum(chunk.data)
        guard actualCrc == chunk.crc32 else {
            throw RpcControlClientError.checksumMismatch(expected: chunk.crc32, actual: actualCrc)
        }

        var ack = Droidmatch_V1_TransferChunkAck()
        ack.transferID = chunk.transferID
        ack.nextOffsetBytes = chunk.offsetBytes + Int64(chunk.data.count)
        ack.finalAck = chunk.finalChunk
        var ackEnvelope = Droidmatch_V1_RpcEnvelope()
        ackEnvelope.frameVersion = 1
        ackEnvelope.kind = .stream
        ackEnvelope.requestID = requestID
        ackEnvelope.streamID = openResponse.streamID
        ackEnvelope.payloadType = .transferChunkAck
        ackEnvelope.payload = try ack.serializedData()
        try session.sendPayload(ackEnvelope.serializedData())

        return DownloadOnceResult(openResponse: openResponse, chunk: chunk)
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
        let response = try parseEnvelope(responseBytes)

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

    private func parseEnvelope(_ bytes: Data) throws -> Droidmatch_V1_RpcEnvelope {
        try Droidmatch_V1_RpcEnvelope(serializedBytes: bytes)
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
