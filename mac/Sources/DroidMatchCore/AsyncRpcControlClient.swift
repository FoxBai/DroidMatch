import Foundation
import SwiftProtobuf

public enum AsyncRpcControlClientStateError: Error, CustomStringConvertible, Sendable {
    case handshakeRequired
    case handshakeInProgress
    case closed

    public var description: String {
        switch self {
        case .handshakeRequired:
            return "RPC handshake is required before control-plane requests"
        case .handshakeInProgress:
            return "RPC handshake is already in progress"
        case .closed:
            return "RPC client is closed"
        }
    }
}

public struct PairingCredentials: Equatable, Sendable {
    public let pairingID: Data
    public let pairingKey: Data

    public init(pairingID: Data, pairingKey: Data) throws {
        guard pairingID.count == SessionAuthenticator.pairingIDLength else {
            throw SessionAuthenticationError.invalidLength(
                field: "pairing ID",
                expected: SessionAuthenticator.pairingIDLength,
                actual: pairingID.count
            )
        }
        guard pairingKey.count == SessionAuthenticator.pairingKeyLength else {
            throw SessionAuthenticationError.invalidLength(
                field: "pairing key",
                expected: SessionAuthenticator.pairingKeyLength,
                actual: pairingKey.count
            )
        }
        self.pairingID = pairingID
        self.pairingKey = pairingKey
    }
}

public enum AsyncRpcAuthenticationError: Error, CustomStringConvertible, Sendable {
    case pairingRequired
    case credentialsRequired
    case downgradeDetected
    case unexpectedState(Droidmatch_V1_AuthenticationState)
    case rejected(Droidmatch_V1_DroidMatchError)
    case invalidServerProof

    public var description: String {
        switch self {
        case .pairingRequired:
            return "the Android endpoint requires first-time pairing"
        case .credentialsRequired:
            return "the Android endpoint requires paired-session credentials"
        case .downgradeDetected:
            return "paired credentials were supplied but the endpoint offered nonce correlation only"
        case let .unexpectedState(state):
            return "unexpected authentication state: \(state)"
        case let .rejected(error):
            return "session authentication rejected: \(error.code): \(error.message)"
        case .invalidServerProof:
            return "server proof does not match the paired endpoint"
        }
    }
}

/// Product-facing async RPC client for the M1 control plane.
///
/// Request construction and response validation are shared with the synchronous
/// harness through `RpcEnvelopeCodec`. This actor owns handshake/capability state,
/// while `AsyncRpcMultiplexer` owns request IDs, the single reader, and routing.
public actor AsyncRpcControlClient {
    private enum State {
        case awaitingHandshake
        case handshaking
        case ready
        case closed
    }

    private let multiplexer: AsyncRpcMultiplexer
    private let credentials: PairingCredentials?
    private let requestedCapabilities: [Droidmatch_V1_Capability]
    private var state = State.awaitingHandshake
    private var cachedHandshake: HandshakeSmokeResult?

    public init(
        session: AsyncFramedTcpSession,
        credentials: PairingCredentials? = nil,
        requestedCapabilities: [Droidmatch_V1_Capability] = [.fileList, .diagnostics],
        requestTimeoutSeconds: TimeInterval = 5
    ) {
        self.multiplexer = AsyncRpcMultiplexer(
            session: session,
            requestTimeoutSeconds: requestTimeoutSeconds
        )
        self.credentials = credentials
        self.requestedCapabilities = requestedCapabilities
    }

    /// Performs ClientHello once. Later calls return the negotiated result without
    /// writing another handshake frame to the connection.
    public func handshake() async throws -> HandshakeSmokeResult {
        switch state {
        case .ready:
            guard let cachedHandshake else {
                preconditionFailure("ready RPC client is missing handshake result")
            }
            return cachedHandshake
        case .handshaking:
            throw AsyncRpcControlClientStateError.handshakeInProgress
        case .closed:
            throw AsyncRpcControlClientStateError.closed
        case .awaitingHandshake:
            state = .handshaking
        }

        do {
            try await multiplexer.start()
            let requestID = try await multiplexer.allocateRequestID()
            let handshakeClient = HandshakeSmokeClient(
                requestedCapabilities: requestedCapabilities,
                pairingID: credentials?.pairingID
            )
            let envelope = try handshakeClient.clientHelloEnvelope(requestID: requestID)
            let response = try await multiplexer.sendRequest(envelope)
            let result = try handshakeClient.parseServerHelloResponse(
                response,
                expectedRequestID: requestID
            )
            let authenticatedResult = try await authenticateIfRequired(result)
            cachedHandshake = authenticatedResult
            state = .ready
            return authenticatedResult
        } catch {
            // A failed negotiation leaves no safe interpretation for later frames.
            state = .closed
            await multiplexer.close()
            throw error
        }
    }

    private func authenticateIfRequired(
        _ handshake: HandshakeSmokeResult
    ) async throws -> HandshakeSmokeResult {
        switch handshake.authenticationState {
        case .correlated:
            guard credentials == nil else {
                throw AsyncRpcAuthenticationError.downgradeDetected
            }
            return handshake
        case .pairingRequired:
            throw AsyncRpcAuthenticationError.pairingRequired
        case .required:
            guard let credentials else {
                throw AsyncRpcAuthenticationError.credentialsRequired
            }

            let transcript = try SessionAuthenticator.transcript(
                pairingID: credentials.pairingID,
                clientNonce: handshake.sessionNonce,
                serverNonce: handshake.serverNonce,
                protocolMajor: handshake.protocolMajor,
                protocolMinor: handshake.protocolMinor,
                transport: handshake.transport
            )
            let transcriptHash = SessionAuthenticator.transcriptHash(transcript)
            var authentication = Droidmatch_V1_AuthenticateSessionRequest()
            authentication.pairingID = credentials.pairingID
            authentication.clientProof = try SessionAuthenticator.clientProof(
                pairingKey: credentials.pairingKey,
                transcriptHash: transcriptHash
            )

            let requestID = try await multiplexer.allocateRequestID()
            let envelope = try RpcEnvelopeCodec.request(
                payload: authentication,
                payloadType: .authenticateSessionRequest,
                requestID: requestID
            )
            let responseBytes = try await multiplexer.sendRequest(envelope)
            let responseEnvelope = try RpcEnvelopeCodec.response(
                from: responseBytes,
                requestID: requestID,
                expectedPayloadType: .authenticateSessionResponse
            )
            let response = try Droidmatch_V1_AuthenticateSessionResponse(
                serializedBytes: responseEnvelope.payload
            )
            guard response.authenticated, !response.hasError else {
                let error: Droidmatch_V1_DroidMatchError
                if response.hasError {
                    error = response.error
                } else {
                    var missingProof = Droidmatch_V1_DroidMatchError()
                    missingProof.code = .unauthorized
                    missingProof.message = "session authentication failed"
                    error = missingProof
                }
                throw AsyncRpcAuthenticationError.rejected(error)
            }
            guard try SessionAuthenticator.verifyServerProof(
                response.serverProof,
                pairingKey: credentials.pairingKey,
                transcriptHash: transcriptHash
            ) else {
                throw AsyncRpcAuthenticationError.invalidServerProof
            }

            return HandshakeSmokeResult(
                requestID: handshake.requestID,
                serverName: handshake.serverName,
                serverVersion: handshake.serverVersion,
                protocolMajor: handshake.protocolMajor,
                protocolMinor: handshake.protocolMinor,
                transport: handshake.transport,
                grantedCapabilities: response.grantedCapabilities,
                sessionNonce: handshake.sessionNonce,
                serverNonce: handshake.serverNonce,
                authenticationState: .authenticated
            )
        case .unspecified, .authenticated, .UNRECOGNIZED:
            throw AsyncRpcAuthenticationError.unexpectedState(handshake.authenticationState)
        }
    }

    public func heartbeat(monotonicMillis: Int64) async throws -> Droidmatch_V1_HeartbeatResponse {
        var request = Droidmatch_V1_HeartbeatRequest()
        request.monotonicMillis = monotonicMillis
        return try await execute(
            payload: request,
            requestPayloadType: .heartbeatRequest,
            responsePayloadType: .heartbeatResponse
        ) { payload in
            try Droidmatch_V1_HeartbeatResponse(serializedBytes: payload)
        }
    }

    public func deviceInfo() async throws -> Droidmatch_V1_DeviceInfoResponse {
        try await execute(
            payload: Droidmatch_V1_DeviceInfoRequest(),
            requestPayloadType: .deviceInfoRequest,
            responsePayloadType: .deviceInfoResponse
        ) { payload in
            try Droidmatch_V1_DeviceInfoResponse(serializedBytes: payload)
        }
    }

    public func listDir(path: String) async throws -> Droidmatch_V1_ListDirResponse {
        var request = Droidmatch_V1_ListDirRequest()
        request.path = path
        return try await listDir(request: request)
    }

    public func listDir(
        request: Droidmatch_V1_ListDirRequest
    ) async throws -> Droidmatch_V1_ListDirResponse {
        return try await execute(
            payload: request,
            requestPayloadType: .listDirRequest,
            responsePayloadType: .listDirResponse
        ) { payload in
            try Droidmatch_V1_ListDirResponse(serializedBytes: payload)
        }
    }

    public func diagnostics() async throws -> Droidmatch_V1_DiagnosticsResponse {
        try await execute(
            payload: Droidmatch_V1_DiagnosticsRequest(),
            requestPayloadType: .diagnosticsRequest,
            responsePayloadType: .diagnosticsResponse
        ) { payload in
            try Droidmatch_V1_DiagnosticsResponse(serializedBytes: payload)
        }
    }

    public func openDownload(
        sourcePath: String,
        transferID: String = UUID().uuidString,
        requestedOffsetBytes: Int64 = 0,
        sourceFingerprint: Droidmatch_V1_TransferFingerprint? = nil,
        preferredChunkSizeBytes: UInt32 = 256 * 1024
    ) async throws -> AsyncDownloadTransfer {
        try requireReady()
        try requireCapability(.fileRead)
        if requestedOffsetBytes > 0 {
            try requireCapability(.resumableTransfer)
        }
        do {
            return try await multiplexer.openDownload(
                sourcePath: sourcePath,
                transferID: transferID,
                requestedOffsetBytes: requestedOffsetBytes,
                sourceFingerprint: sourceFingerprint,
                preferredChunkSizeBytes: preferredChunkSizeBytes
            )
        } catch {
            await synchronizeClosedState()
            throw error
        }
    }

    public func openUpload(
        sourcePath: String,
        destinationPath: String,
        transferID: String = UUID().uuidString,
        requestedOffsetBytes: Int64 = 0,
        expectedSizeBytes: Int64 = -1,
        preferredChunkSizeBytes: UInt32 = 256 * 1024
    ) async throws -> AsyncUploadTransfer {
        try requireReady()
        try requireCapability(.fileWrite)
        if requestedOffsetBytes > 0 {
            try requireCapability(.resumableTransfer)
        }
        do {
            return try await multiplexer.openUpload(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                transferID: transferID,
                requestedOffsetBytes: requestedOffsetBytes,
                expectedSizeBytes: expectedSizeBytes,
                preferredChunkSizeBytes: preferredChunkSizeBytes
            )
        } catch {
            await synchronizeClosedState()
            throw error
        }
    }

    public func close() async {
        state = .closed
        await multiplexer.close()
    }

    private func execute<Request: SwiftProtobuf.Message, Response: Sendable>(
        payload: Request,
        requestPayloadType: Droidmatch_V1_PayloadType,
        responsePayloadType: Droidmatch_V1_PayloadType,
        decode: @escaping @Sendable (Data) throws -> Response
    ) async throws -> Response {
        try requireReady()
        let requestID: UInt64
        do {
            requestID = try await multiplexer.allocateRequestID()
        } catch {
            await synchronizeClosedState()
            throw error
        }
        let envelope = try RpcEnvelopeCodec.request(
            payload: payload,
            payloadType: requestPayloadType,
            requestID: requestID
        )

        do {
            let responseBytes = try await multiplexer.sendRequest(envelope)
            let response = try RpcEnvelopeCodec.response(
                from: responseBytes,
                requestID: requestID,
                expectedPayloadType: responsePayloadType
            )
            return try decode(response.payload)
        } catch {
            if !isRecoverableRemoteError(error) {
                state = .closed
                await multiplexer.close()
            }
            throw error
        }
    }

    private func requireReady() throws {
        switch state {
        case .ready:
            return
        case .awaitingHandshake:
            throw AsyncRpcControlClientStateError.handshakeRequired
        case .handshaking:
            throw AsyncRpcControlClientStateError.handshakeInProgress
        case .closed:
            throw AsyncRpcControlClientStateError.closed
        }
    }

    private func requireCapability(_ capability: Droidmatch_V1_Capability) throws {
        guard cachedHandshake?.grantedCapabilities.contains(capability) == true else {
            throw RpcControlClientError.invalidTransferState(
                "required capability was not granted: \(capability)"
            )
        }
    }

    private func synchronizeClosedState() async {
        if await multiplexer.isClosed() {
            state = .closed
        }
    }

    private func isRecoverableRemoteError(_ error: any Error) -> Bool {
        guard let rpcError = error as? RpcControlClientError else {
            return false
        }
        if case .remoteError = rpcError {
            return true
        }
        return false
    }
}
