import Foundation

public struct HandshakeSmokeResult: Equatable, Sendable {
    public let requestID: UInt64
    public let serverName: String
    public let serverVersion: String
    public let protocolMajor: UInt32
    public let protocolMinor: UInt32
    public let transport: Droidmatch_V1_TransportKind
    public let grantedCapabilities: [Droidmatch_V1_Capability]
    public let sessionNonce: Data
    public let serverNonce: Data
    public let deviceIdentityFingerprint: Data
    public let authenticationState: Droidmatch_V1_AuthenticationState
}

public enum HandshakeSmokeClientError: Error, CustomStringConvertible, Sendable {
    case remoteError(Droidmatch_V1_DroidMatchError)
    case requestIDMismatch(expected: UInt64, actual: UInt64)
    case unexpectedEnvelope(kind: Droidmatch_V1_RpcFrameKind, payloadType: Droidmatch_V1_PayloadType)
    case unsupportedProtocol(UInt32)
    case unexpectedTransport(Droidmatch_V1_TransportKind)
    case invalidSessionNonceLength(source: String, actual: Int)
    case invalidPairingIDLength(Int)
    case invalidServerNonceLength(Int)
    case invalidDeviceIdentityFingerprintLength(Int)
    case invalidAuthenticationState(Droidmatch_V1_AuthenticationState)
    case sessionNonceMismatch

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
        case let .invalidSessionNonceLength(source, actual):
            return "invalid \(source) session nonce length: expected 16...32 bytes, got \(actual)"
        case let .invalidPairingIDLength(actual):
            return "invalid pairing ID length: expected 16 bytes, got \(actual)"
        case let .invalidServerNonceLength(actual):
            return "invalid server nonce length: expected 32 bytes, got \(actual)"
        case let .invalidDeviceIdentityFingerprintLength(actual):
            return "invalid device identity fingerprint length: expected 32 bytes, got \(actual)"
        case let .invalidAuthenticationState(state):
            return "invalid ServerHello authentication state: \(state)"
        case .sessionNonceMismatch:
            return "ServerHello session nonce does not match ClientHello"
        }
    }
}

public struct HandshakeSmokeClient {
    public static let defaultRequestID: UInt64 = 1

    /// Capability profile used by the full M1 evidence commands.
    ///
    /// Keep one canonical ordering so sync-to-async command migrations do not
    /// silently change negotiation while preserving only their visible output.
    public static let fullM1Capabilities: [Droidmatch_V1_Capability] = [
        .fileList,
        .fileRead,
        .fileWrite,
        .resumableTransfer,
        .diagnostics,
    ]

    private let clientName: String
    private let clientVersion: String
    private let protocolMajor: UInt32
    private let protocolMinor: UInt32
    private let requestedCapabilities: [Droidmatch_V1_Capability]
    private let sessionNonce: Data
    private let pairingID: Data?

    public init(
        clientName: String = "DroidMatchHarness",
        clientVersion: String = "0.1.0-m1",
        protocolMajor: UInt32 = 1,
        protocolMinor: UInt32 = 0,
        requestedCapabilities: [Droidmatch_V1_Capability] = [.diagnostics],
        sessionNonce: Data? = nil,
        pairingID: Data? = nil
    ) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.requestedCapabilities = requestedCapabilities
        self.sessionNonce = sessionNonce ?? Self.generateSessionNonce()
        self.pairingID = pairingID
    }

    public func run(
        host: String = "127.0.0.1",
        port: Int,
        timeoutSeconds: TimeInterval = 5
    ) async throws -> HandshakeSmokeResult {
        let session = try await AsyncFramedTcpSession.connect(
            host: host,
            port: port,
            timeoutSeconds: timeoutSeconds
        )
        do {
            // This remains a Hello-only diagnostic. Do not substitute
            // AsyncRpcControlClient.handshake(), which intentionally turns
            // pairingRequired into a product authentication error.
            let request = try clientHelloEnvelope(requestID: Self.defaultRequestID)
            let response = try await session.roundTrip(payload: request.serializedData())
            let result = try parseServerHelloResponse(
                response,
                expectedRequestID: Self.defaultRequestID
            )
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }

    public func clientHelloEnvelope(requestID: UInt64 = defaultRequestID) throws -> Droidmatch_V1_RpcEnvelope {
        try Self.validateSessionNonceLength(sessionNonce, source: "ClientHello")
        if let pairingID, pairingID.count != SessionAuthenticator.pairingIDLength {
            throw HandshakeSmokeClientError.invalidPairingIDLength(pairingID.count)
        }
        var hello = Droidmatch_V1_ClientHello()
        hello.clientName = clientName
        hello.clientVersion = clientVersion
        hello.protocolMajor = protocolMajor
        hello.protocolMinor = protocolMinor
        hello.transport = .adb
        hello.requestedCapabilities = requestedCapabilities
        hello.sessionNonce = sessionNonce
        if let pairingID {
            hello.pairingID = pairingID
        }

        return try RpcEnvelopeCodec.request(
            payload: hello,
            payloadType: .clientHello,
            requestID: requestID
        )
    }

    public func parseServerHelloResponse(
        _ response: Data,
        expectedRequestID: UInt64 = defaultRequestID
    ) throws -> HandshakeSmokeResult {
        try Self.parseServerHelloResponse(
            response,
            expectedRequestID: expectedRequestID,
            expectedSessionNonce: sessionNonce
        )
    }

    public static func parseServerHelloResponse(
        _ response: Data,
        expectedRequestID: UInt64 = defaultRequestID,
        expectedSessionNonce: Data
    ) throws -> HandshakeSmokeResult {
        let envelope = try RpcEnvelopeCodec.parse(response)

        guard envelope.requestID == expectedRequestID else {
            throw HandshakeSmokeClientError.requestIDMismatch(
                expected: expectedRequestID,
                actual: envelope.requestID
            )
        }

        if envelope.kind == .error {
            throw HandshakeSmokeClientError.remoteError(
                try RpcEnvelopeCodec.errorPayload(from: envelope)
            )
        }

        guard envelope.kind == .response, envelope.payloadType == .serverHello else {
            throw HandshakeSmokeClientError.unexpectedEnvelope(
                kind: envelope.kind,
                payloadType: envelope.payloadType
            )
        }

        let serverHello = try Droidmatch_V1_ServerHello(serializedBytes: envelope.payload)
        guard serverHello.protocolMajor == 1 else {
            throw HandshakeSmokeClientError.unsupportedProtocol(serverHello.protocolMajor)
        }
        guard serverHello.transport == .adb else {
            throw HandshakeSmokeClientError.unexpectedTransport(serverHello.transport)
        }
        try validateSessionNonceLength(serverHello.sessionNonce, source: "ServerHello")
        guard serverHello.sessionNonce == expectedSessionNonce else {
            throw HandshakeSmokeClientError.sessionNonceMismatch
        }

        switch serverHello.authenticationState {
        case .correlated:
            guard serverHello.serverNonce.isEmpty else {
                throw HandshakeSmokeClientError.invalidServerNonceLength(serverHello.serverNonce.count)
            }
            guard serverHello.deviceIdentityFingerprint.isEmpty
                    || serverHello.deviceIdentityFingerprint.count == PairingAuthenticator.digestLength else {
                throw HandshakeSmokeClientError.invalidDeviceIdentityFingerprintLength(
                    serverHello.deviceIdentityFingerprint.count
                )
            }
        case .pairingRequired:
            guard serverHello.serverNonce.isEmpty else {
                throw HandshakeSmokeClientError.invalidServerNonceLength(serverHello.serverNonce.count)
            }
            guard serverHello.deviceIdentityFingerprint.count == PairingAuthenticator.digestLength else {
                throw HandshakeSmokeClientError.invalidDeviceIdentityFingerprintLength(
                    serverHello.deviceIdentityFingerprint.count
                )
            }
        case .required:
            guard serverHello.serverNonce.count == SessionAuthenticator.nonceLength else {
                throw HandshakeSmokeClientError.invalidServerNonceLength(serverHello.serverNonce.count)
            }
            guard serverHello.deviceIdentityFingerprint.count == PairingAuthenticator.digestLength else {
                throw HandshakeSmokeClientError.invalidDeviceIdentityFingerprintLength(
                    serverHello.deviceIdentityFingerprint.count
                )
            }
        case .unspecified, .authenticated, .UNRECOGNIZED:
            throw HandshakeSmokeClientError.invalidAuthenticationState(serverHello.authenticationState)
        }

        return HandshakeSmokeResult(
            requestID: envelope.requestID,
            serverName: serverHello.serverName,
            serverVersion: serverHello.serverVersion,
            protocolMajor: serverHello.protocolMajor,
            protocolMinor: serverHello.protocolMinor,
            transport: serverHello.transport,
            grantedCapabilities: serverHello.grantedCapabilities,
            sessionNonce: serverHello.sessionNonce,
            serverNonce: serverHello.serverNonce,
            deviceIdentityFingerprint: serverHello.deviceIdentityFingerprint,
            authenticationState: serverHello.authenticationState
        )
    }

    private static func generateSessionNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        })
    }

    private static func validateSessionNonceLength(_ nonce: Data, source: String) throws {
        guard (16...32).contains(nonce.count) else {
            throw HandshakeSmokeClientError.invalidSessionNonceLength(
                source: source,
                actual: nonce.count
            )
        }
    }
}
