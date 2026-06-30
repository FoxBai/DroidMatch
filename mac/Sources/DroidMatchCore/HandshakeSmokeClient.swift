import Foundation

public struct HandshakeSmokeResult: Equatable, Sendable {
    public let requestID: UInt64
    public let serverName: String
    public let serverVersion: String
    public let protocolMajor: UInt32
    public let protocolMinor: UInt32
    public let transport: Droidmatch_V1_TransportKind
    public let grantedCapabilities: [Droidmatch_V1_Capability]
}

public enum HandshakeSmokeClientError: Error, CustomStringConvertible {
    case remoteError(Droidmatch_V1_DroidMatchError)
    case requestIDMismatch(expected: UInt64, actual: UInt64)
    case unexpectedEnvelope(kind: Droidmatch_V1_RpcFrameKind, payloadType: Droidmatch_V1_PayloadType)
    case unsupportedProtocol(UInt32)
    case unexpectedTransport(Droidmatch_V1_TransportKind)

    public var description: String {
        switch self {
        case let .remoteError(error):
            return "remote error \(error.code): \(error.message)"
        case let .requestIDMismatch(expected, actual):
            return "response request_id mismatch: expected \(expected), got \(actual)"
        case let .unexpectedEnvelope(kind, payloadType):
            return "unexpected response envelope: kind=\(kind) payload_type=\(payloadType)"
        case let .unsupportedProtocol(protocolMajor):
            return "unsupported server protocol_major: \(protocolMajor)"
        case let .unexpectedTransport(transport):
            return "unexpected server transport: \(transport)"
        }
    }
}

public struct HandshakeSmokeClient {
    public static let defaultRequestID: UInt64 = 1

    private let clientName: String
    private let clientVersion: String
    private let protocolMajor: UInt32
    private let protocolMinor: UInt32
    private let requestedCapabilities: [Droidmatch_V1_Capability]

    public init(
        clientName: String = "DroidMatchHarness",
        clientVersion: String = "0.1.0-m1",
        protocolMajor: UInt32 = 1,
        protocolMinor: UInt32 = 0,
        requestedCapabilities: [Droidmatch_V1_Capability] = [.diagnostics]
    ) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.requestedCapabilities = requestedCapabilities
    }

    public func run(
        host: String = "127.0.0.1",
        port: Int,
        timeoutSeconds: TimeInterval = 5
    ) throws -> HandshakeSmokeResult {
        let tcpClient = FramedTcpClient(host: host, port: port, timeoutSeconds: timeoutSeconds)
        let request = try clientHelloEnvelope(requestID: Self.defaultRequestID)
        let response = try tcpClient.roundTrip(payload: request.serializedData())
        return try Self.parseServerHelloResponse(response, expectedRequestID: Self.defaultRequestID)
    }

    public func clientHelloEnvelope(requestID: UInt64 = defaultRequestID) throws -> Droidmatch_V1_RpcEnvelope {
        var hello = Droidmatch_V1_ClientHello()
        hello.clientName = clientName
        hello.clientVersion = clientVersion
        hello.protocolMajor = protocolMajor
        hello.protocolMinor = protocolMinor
        hello.transport = .adb
        hello.requestedCapabilities = requestedCapabilities

        var envelope = Droidmatch_V1_RpcEnvelope()
        envelope.frameVersion = 1
        envelope.kind = .request
        envelope.requestID = requestID
        envelope.payloadType = .clientHello
        envelope.payload = try hello.serializedData()
        return envelope
    }

    public static func parseServerHelloResponse(
        _ response: Data,
        expectedRequestID: UInt64 = defaultRequestID
    ) throws -> HandshakeSmokeResult {
        let envelope = try Droidmatch_V1_RpcEnvelope(serializedBytes: response)

        if envelope.kind == .error {
            throw HandshakeSmokeClientError.remoteError(try errorPayload(from: envelope))
        }

        guard envelope.kind == .response, envelope.payloadType == .serverHello else {
            throw HandshakeSmokeClientError.unexpectedEnvelope(
                kind: envelope.kind,
                payloadType: envelope.payloadType
            )
        }

        guard envelope.requestID == expectedRequestID else {
            throw HandshakeSmokeClientError.requestIDMismatch(
                expected: expectedRequestID,
                actual: envelope.requestID
            )
        }

        let serverHello = try Droidmatch_V1_ServerHello(serializedBytes: envelope.payload)
        guard serverHello.protocolMajor == 1 else {
            throw HandshakeSmokeClientError.unsupportedProtocol(serverHello.protocolMajor)
        }
        guard serverHello.transport == .adb else {
            throw HandshakeSmokeClientError.unexpectedTransport(serverHello.transport)
        }

        return HandshakeSmokeResult(
            requestID: envelope.requestID,
            serverName: serverHello.serverName,
            serverVersion: serverHello.serverVersion,
            protocolMajor: serverHello.protocolMajor,
            protocolMinor: serverHello.protocolMinor,
            transport: serverHello.transport,
            grantedCapabilities: serverHello.grantedCapabilities
        )
    }

    private static func errorPayload(from envelope: Droidmatch_V1_RpcEnvelope) throws -> Droidmatch_V1_DroidMatchError {
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
