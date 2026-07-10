import Foundation
import SwiftProtobuf

public struct PairingPresentation: Equatable, Sendable {
    public let androidDisplayName: String
    public let shortAuthenticationString: String
    public let deviceIdentityFingerprint: Data

    public init(
        androidDisplayName: String,
        shortAuthenticationString: String,
        deviceIdentityFingerprint: Data
    ) {
        self.androidDisplayName = androidDisplayName
        self.shortAuthenticationString = shortAuthenticationString
        self.deviceIdentityFingerprint = deviceIdentityFingerprint
    }
}

public enum AsyncPairingClientError: Error, CustomStringConvertible, Sendable {
    case alreadyStarted
    case closed
    case remoteError(Droidmatch_V1_DroidMatchError)
    case unsupportedVersion(UInt32)
    case invalidResponse(String)
    case invalidDeviceIdentitySignature
    case userRejected
    case pairingIDCollision

    public var description: String {
        switch self {
        case .alreadyStarted:
            return "pairing client can run only once"
        case .closed:
            return "pairing client is closed"
        case let .remoteError(error):
            return "pairing failed: \(error.code): \(error.message)"
        case let .unsupportedVersion(version):
            return "unsupported pairing version: \(version)"
        case let .invalidResponse(message):
            return "invalid pairing response: \(message)"
        case .invalidDeviceIdentitySignature:
            return "Android device identity signature is invalid"
        case .userRejected:
            return "pairing was rejected on the Mac"
        case .pairingIDCollision:
            return "pairing ID already exists in Keychain"
        }
    }
}

/// One-shot async first-pairing client.
///
/// Use a pairing transport timeout longer than the Android approval timeout (for
/// example 90 seconds). This actor never retries automatically: a timeout or lost
/// response requires a new visible pairing window and fresh ephemeral keys.
public actor AsyncPairingClient {
    private enum State {
        case idle
        case running
        case completed
        case closed
    }

    private let session: AsyncFramedTcpSession
    private let credentialStore: any PairingCredentialStoring
    private var state = State.idle
    private var nextRequestID: UInt64 = 1

    public init(
        session: AsyncFramedTcpSession,
        credentialStore: any PairingCredentialStoring
    ) {
        self.session = session
        self.credentialStore = credentialStore
    }

    public func pair(
        clientDisplayName: String = "DroidMatch Mac",
        approve: @escaping @Sendable (PairingPresentation) async throws -> Bool
    ) async throws -> PairingCredentialMetadata {
        switch state {
        case .idle:
            state = .running
        case .running, .completed:
            throw AsyncPairingClientError.alreadyStarted
        case .closed:
            throw AsyncPairingClientError.closed
        }

        var provisionalPairingID: Data?
        do {
            let keyAgreement = PairingEphemeralKeyPair()
            let clientNonce = Self.randomBytes(count: PairingAuthenticator.nonceLength)
            var start = Droidmatch_V1_PairingStartRequest()
            start.pairingVersion = PairingAuthenticator.version
            start.clientName = clientDisplayName
            start.clientPublicKey = keyAgreement.publicKeyX963Representation
            start.clientNonce = clientNonce
            let startResponse: Droidmatch_V1_PairingStartResponse = try await execute(
                payload: start,
                requestType: .pairingStartRequest,
                responseType: .pairingStartResponse
            )
            try throwIfRemoteError(startResponse.hasError ? startResponse.error : nil)
            guard startResponse.pairingVersion == PairingAuthenticator.version else {
                throw AsyncPairingClientError.unsupportedVersion(startResponse.pairingVersion)
            }

            let transcript = try PairingAuthenticator.transcript(
                pairingVersion: startResponse.pairingVersion,
                pairingID: startResponse.pairingID,
                clientPublicKey: keyAgreement.publicKeyX963Representation,
                serverPublicKey: startResponse.serverPublicKey,
                deviceIdentityPublicKey: startResponse.deviceIdentityPublicKey,
                clientNonce: clientNonce,
                serverNonce: startResponse.serverNonce,
                clientName: clientDisplayName,
                serverName: startResponse.serverName
            )
            guard try PairingAuthenticator.verifyDeviceIdentitySignature(
                startResponse.deviceIdentitySignature,
                deviceIdentityPublicKey: startResponse.deviceIdentityPublicKey,
                transcript: transcript
            ) else {
                throw AsyncPairingClientError.invalidDeviceIdentitySignature
            }
            let deviceIdentityFingerprint = PairingAuthenticator.transcriptHash(
                startResponse.deviceIdentityPublicKey
            )
            let transcriptHash = PairingAuthenticator.transcriptHash(transcript)
            let sharedSecret = try keyAgreement.sharedSecret(
                peerPublicKeyX963Representation: startResponse.serverPublicKey
            )
            let secrets = try PairingAuthenticator.deriveSecrets(
                sharedSecret: sharedSecret,
                transcriptHash: transcriptHash
            )
            let presentation = PairingPresentation(
                androidDisplayName: startResponse.serverName,
                shortAuthenticationString: secrets.shortAuthenticationString,
                deviceIdentityFingerprint: deviceIdentityFingerprint
            )
            guard try await approve(presentation) else {
                throw AsyncPairingClientError.userRejected
            }

            var confirm = Droidmatch_V1_PairingConfirmRequest()
            confirm.pairingID = startResponse.pairingID
            confirm.clientApproved = true
            confirm.clientConfirmation = try PairingAuthenticator.clientConfirmation(
                confirmationKey: secrets.confirmationKey,
                transcriptHash: transcriptHash
            )
            let confirmResponse: Droidmatch_V1_PairingConfirmResponse = try await execute(
                payload: confirm,
                requestType: .pairingConfirmRequest,
                responseType: .pairingConfirmResponse
            )
            try throwIfRemoteError(confirmResponse.hasError ? confirmResponse.error : nil)
            guard confirmResponse.clientConfirmationAccepted,
                  confirmResponse.serverApproved else {
                throw AsyncPairingClientError.invalidResponse(
                    "Android did not confirm both user approvals"
                )
            }
            guard try PairingAuthenticator.verifyServerConfirmation(
                confirmResponse.serverConfirmation,
                confirmationKey: secrets.confirmationKey,
                transcriptHash: transcriptHash
            ) else {
                throw AsyncPairingClientError.invalidResponse("server confirmation is invalid")
            }

            do {
                _ = try credentialStore.load(pairingID: startResponse.pairingID)
                throw AsyncPairingClientError.pairingIDCollision
            } catch PairingCredentialStoreError.notFound {
                // Expected for a fresh server-generated 128-bit identifier.
            }
            let now = Date()
            let record = try PairingCredentialRecord(
                pairingID: startResponse.pairingID,
                deviceIdentityFingerprint: deviceIdentityFingerprint,
                pairingKey: secrets.pairingKey,
                displayName: startResponse.serverName,
                createdAt: now,
                lastUsedAt: now
            )
            try credentialStore.save(record)
            provisionalPairingID = record.pairingID

            var finalize = Droidmatch_V1_PairingFinalizeRequest()
            finalize.pairingID = record.pairingID
            finalize.finalConfirmation = try PairingAuthenticator.finalConfirmation(
                confirmationKey: secrets.confirmationKey,
                transcriptHash: transcriptHash,
                serverConfirmation: confirmResponse.serverConfirmation
            )
            let finalizeResponse: Droidmatch_V1_PairingFinalizeResponse = try await execute(
                payload: finalize,
                requestType: .pairingFinalizeRequest,
                responseType: .pairingFinalizeResponse
            )
            try throwIfRemoteError(finalizeResponse.hasError ? finalizeResponse.error : nil)
            guard finalizeResponse.paired else {
                throw AsyncPairingClientError.invalidResponse("Android did not persist the pairing")
            }

            provisionalPairingID = nil
            state = .completed
            await session.close()
            return record.metadata
        } catch {
            if let provisionalPairingID {
                try? credentialStore.revoke(pairingID: provisionalPairingID)
            }
            state = .closed
            await session.close()
            throw error
        }
    }

    public func close() async {
        state = .closed
        await session.close()
    }

    private func execute<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
        payload: Request,
        requestType: Droidmatch_V1_PayloadType,
        responseType: Droidmatch_V1_PayloadType
    ) async throws -> Response {
        let requestID = allocateRequestID()
        let envelope = try RpcEnvelopeCodec.request(
            payload: payload,
            payloadType: requestType,
            requestID: requestID
        )
        let responseBytes = try await session.roundTrip(payload: envelope.serializedData())
        let response = try RpcEnvelopeCodec.response(
            from: responseBytes,
            requestID: requestID,
            expectedPayloadType: responseType
        )
        return try Response(serializedBytes: response.payload)
    }

    private func throwIfRemoteError(_ error: Droidmatch_V1_DroidMatchError?) throws {
        if let error {
            throw AsyncPairingClientError.remoteError(error)
        }
    }

    private func allocateRequestID() -> UInt64 {
        let requestID = nextRequestID
        nextRequestID = requestID == UInt64.max ? 1 : requestID + 1
        return requestID
    }

    private static func randomBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        })
    }
}
