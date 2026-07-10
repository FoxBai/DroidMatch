import CryptoKit
import Foundation
@preconcurrency import Network
import SwiftProtobuf
import Testing
@testable import DroidMatchCore

@Test func asyncPairingClientCompletesAndPersistsCredential() async throws {
    let store = InMemoryPairingCredentialStore()
    let server = try FirstPairingTestServer()
    defer { server.cancel() }

    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 2
    )
    let client = AsyncPairingClient(session: session, credentialStore: store)
    let metadata = try await client.pair(clientDisplayName: "Test Mac") { presentation in
        #expect(presentation.androidDisplayName == "Test Android")
        #expect(presentation.shortAuthenticationString.count == 6)
        #expect(Int(presentation.shortAuthenticationString) != nil)
        #expect(presentation.deviceIdentityFingerprint.count == PairingAuthenticator.digestLength)
        return true
    }

    let stored = try store.load(pairingID: metadata.pairingID)
    #expect(stored.metadata == metadata)
    #expect(stored.pairingKey.count == PairingAuthenticator.keyLength)
    #expect(store.mutationCounts() == .init(saves: 1, revokes: 0))
}

@Test func asyncPairingClientRejectsInvalidDeviceIdentityBeforeApproval() async throws {
    let store = InMemoryPairingCredentialStore()
    let server = try FirstPairingTestServer(corruptIdentitySignature: true)
    defer { server.cancel() }

    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 2
    )
    let client = AsyncPairingClient(session: session, credentialStore: store)
    var sawExpectedError = false
    do {
        _ = try await client.pair { _ in
            Issue.record("approval must not be requested for an invalid Android identity signature")
            return true
        }
    } catch AsyncPairingClientError.invalidDeviceIdentitySignature {
        sawExpectedError = true
    }

    #expect(sawExpectedError)
    #expect(try store.list().isEmpty)
    #expect(store.mutationCounts() == .init(saves: 0, revokes: 0))
}

@Test func asyncPairingClientUserRejectionDoesNotPersistCredential() async throws {
    let store = InMemoryPairingCredentialStore()
    let server = try FirstPairingTestServer()
    defer { server.cancel() }

    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 2
    )
    let client = AsyncPairingClient(session: session, credentialStore: store)
    var sawExpectedError = false
    do {
        _ = try await client.pair { _ in false }
    } catch AsyncPairingClientError.userRejected {
        sawExpectedError = true
    }

    #expect(sawExpectedError)
    #expect(try store.list().isEmpty)
    #expect(store.mutationCounts() == .init(saves: 0, revokes: 0))
}

@Test func asyncPairingClientRollsBackProvisionalCredentialWhenFinalizeFails() async throws {
    let store = InMemoryPairingCredentialStore()
    let server = try FirstPairingTestServer(rejectFinalize: true)
    defer { server.cancel() }

    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 2
    )
    let client = AsyncPairingClient(session: session, credentialStore: store)
    var sawRemoteError = false
    do {
        _ = try await client.pair { _ in true }
    } catch let AsyncPairingClientError.remoteError(error) {
        sawRemoteError = error.code == .unauthorized
    }

    #expect(sawRemoteError)
    #expect(try store.list().isEmpty)
    #expect(store.mutationCounts() == .init(saves: 1, revokes: 1))
}

private final class InMemoryPairingCredentialStore: PairingCredentialStoring, @unchecked Sendable {
    struct MutationCounts: Equatable {
        let saves: Int
        let revokes: Int
    }

    private let lock = NSLock()
    private var records: [Data: PairingCredentialRecord] = [:]
    private var saves = 0
    private var revokes = 0

    func save(_ record: PairingCredentialRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        if let existing = records[record.pairingID],
           existing.deviceIdentityFingerprint != record.deviceIdentityFingerprint {
            throw PairingCredentialStoreError.duplicatePairingID
        }
        records[record.pairingID] = record
        saves += 1
    }

    func load(pairingID: Data) throws -> PairingCredentialRecord {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[pairingID] else {
            throw PairingCredentialStoreError.notFound
        }
        return record
    }

    func list() throws -> [PairingCredentialMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return records.values.map(\.metadata)
    }

    func revoke(pairingID: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard records.removeValue(forKey: pairingID) != nil else {
            throw PairingCredentialStoreError.notFound
        }
        revokes += 1
    }

    func mutationCounts() -> MutationCounts {
        lock.lock()
        defer { lock.unlock() }
        return MutationCounts(saves: saves, revokes: revokes)
    }
}

private final class FirstPairingTestServer: @unchecked Sendable {
    private final class ConnectionState: @unchecked Sendable {
        let serverKeyAgreement = PairingEphemeralKeyPair()
        let deviceIdentity = P256.Signing.PrivateKey()
        let pairingID = Data((0..<PairingAuthenticator.pairingIDLength).map { UInt8(0x10 + $0) })
        let serverNonce = Data((0..<PairingAuthenticator.nonceLength).map { UInt8(0x40 + $0) })
        var transcriptHash: Data?
        var secrets: PairingDerivedSecrets?
        var serverConfirmation: Data?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.droidmatch.tests.first-pairing")
    private let corruptIdentitySignature: Bool
    private let rejectFinalize: Bool

    let port: Int

    init(
        corruptIdentitySignature: Bool = false,
        rejectFinalize: Bool = false
    ) throws {
        self.corruptIdentitySignature = corruptIdentitySignature
        self.rejectFinalize = rejectFinalize
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [queue, corruptIdentitySignature, rejectFinalize] connection in
            connection.start(queue: queue)
            Self.receiveStart(
                on: connection,
                state: ConnectionState(),
                corruptIdentitySignature: corruptIdentitySignature,
                rejectFinalize: rejectFinalize
            )
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success,
              let rawPort = listener.port?.rawValue else {
            throw FirstPairingTestServerError.listenerDidNotBecomeReady
        }
        port = Int(rawPort)
    }

    func cancel() {
        listener.cancel()
    }

    private static func receiveStart(
        on connection: NWConnection,
        state: ConnectionState,
        corruptIdentitySignature: Bool,
        rejectFinalize: Bool
    ) {
        receiveFrameBody(on: connection) { body in
            do {
                let envelope = try requestEnvelope(body, expectedType: .pairingStartRequest)
                let request = try Droidmatch_V1_PairingStartRequest(serializedBytes: envelope.payload)
                let identityPublicKey = state.deviceIdentity.publicKey.x963Representation
                let transcript = try PairingAuthenticator.transcript(
                    pairingVersion: request.pairingVersion,
                    pairingID: state.pairingID,
                    clientPublicKey: request.clientPublicKey,
                    serverPublicKey: state.serverKeyAgreement.publicKeyX963Representation,
                    deviceIdentityPublicKey: identityPublicKey,
                    clientNonce: request.clientNonce,
                    serverNonce: state.serverNonce,
                    clientName: request.clientName,
                    serverName: "Test Android"
                )
                let transcriptHash = PairingAuthenticator.transcriptHash(transcript)
                let sharedSecret = try state.serverKeyAgreement.sharedSecret(
                    peerPublicKeyX963Representation: request.clientPublicKey
                )
                state.transcriptHash = transcriptHash
                state.secrets = try PairingAuthenticator.deriveSecrets(
                    sharedSecret: sharedSecret,
                    transcriptHash: transcriptHash
                )

                var signature = try state.deviceIdentity.signature(for: transcript).derRepresentation
                if corruptIdentitySignature {
                    signature[signature.index(before: signature.endIndex)] ^= 0x01
                }
                var response = Droidmatch_V1_PairingStartResponse()
                response.pairingVersion = PairingAuthenticator.version
                response.pairingID = state.pairingID
                response.serverName = "Test Android"
                response.serverPublicKey = state.serverKeyAgreement.publicKeyX963Representation
                response.serverNonce = state.serverNonce
                response.deviceIdentityPublicKey = identityPublicKey
                response.deviceIdentitySignature = signature
                try sendResponse(
                    response,
                    payloadType: .pairingStartResponse,
                    requestID: envelope.requestID,
                    on: connection
                ) {
                    receiveConfirm(
                        on: connection,
                        state: state,
                        rejectFinalize: rejectFinalize
                    )
                }
            } catch {
                connection.cancel()
            }
        }
    }

    private static func receiveConfirm(
        on connection: NWConnection,
        state: ConnectionState,
        rejectFinalize: Bool
    ) {
        receiveFrameBody(on: connection) { body in
            do {
                let envelope = try requestEnvelope(body, expectedType: .pairingConfirmRequest)
                let request = try Droidmatch_V1_PairingConfirmRequest(serializedBytes: envelope.payload)
                guard let secrets = state.secrets,
                      let transcriptHash = state.transcriptHash,
                      request.pairingID == state.pairingID,
                      request.clientApproved,
                      try PairingAuthenticator.verifyClientConfirmation(
                          request.clientConfirmation,
                          confirmationKey: secrets.confirmationKey,
                          transcriptHash: transcriptHash
                      ) else {
                    throw FirstPairingTestServerError.invalidRequest
                }
                let serverConfirmation = try PairingAuthenticator.serverConfirmation(
                    confirmationKey: secrets.confirmationKey,
                    transcriptHash: transcriptHash
                )
                state.serverConfirmation = serverConfirmation
                var response = Droidmatch_V1_PairingConfirmResponse()
                response.clientConfirmationAccepted = true
                response.serverApproved = true
                response.serverConfirmation = serverConfirmation
                try sendResponse(
                    response,
                    payloadType: .pairingConfirmResponse,
                    requestID: envelope.requestID,
                    on: connection
                ) {
                    receiveFinalize(
                        on: connection,
                        state: state,
                        rejectFinalize: rejectFinalize
                    )
                }
            } catch {
                connection.cancel()
            }
        }
    }

    private static func receiveFinalize(
        on connection: NWConnection,
        state: ConnectionState,
        rejectFinalize: Bool
    ) {
        receiveFrameBody(on: connection) { body in
            do {
                let envelope = try requestEnvelope(body, expectedType: .pairingFinalizeRequest)
                let request = try Droidmatch_V1_PairingFinalizeRequest(serializedBytes: envelope.payload)
                guard let secrets = state.secrets,
                      let transcriptHash = state.transcriptHash,
                      let serverConfirmation = state.serverConfirmation,
                      request.pairingID == state.pairingID,
                      try PairingAuthenticator.verifyFinalConfirmation(
                          request.finalConfirmation,
                          confirmationKey: secrets.confirmationKey,
                          transcriptHash: transcriptHash,
                          serverConfirmation: serverConfirmation
                      ) else {
                    throw FirstPairingTestServerError.invalidRequest
                }

                var response = Droidmatch_V1_PairingFinalizeResponse()
                if rejectFinalize {
                    var error = Droidmatch_V1_DroidMatchError()
                    error.code = .unauthorized
                    error.message = "test server rejected final confirmation"
                    response.error = error
                } else {
                    response.paired = true
                }
                try sendResponse(
                    response,
                    payloadType: .pairingFinalizeResponse,
                    requestID: envelope.requestID,
                    on: connection
                ) {
                    connection.cancel()
                }
            } catch {
                connection.cancel()
            }
        }
    }

    private static func requestEnvelope(
        _ body: Data,
        expectedType: Droidmatch_V1_PayloadType
    ) throws -> Droidmatch_V1_RpcEnvelope {
        let envelope = try Droidmatch_V1_RpcEnvelope(serializedBytes: body)
        guard envelope.kind == .request, envelope.payloadType == expectedType else {
            throw FirstPairingTestServerError.invalidRequest
        }
        return envelope
    }

    private static func sendResponse<Response: SwiftProtobuf.Message>(
        _ response: Response,
        payloadType: Droidmatch_V1_PayloadType,
        requestID: UInt64,
        on connection: NWConnection,
        completion: @escaping @Sendable () -> Void
    ) throws {
        var envelope = Droidmatch_V1_RpcEnvelope()
        envelope.frameVersion = 1
        envelope.kind = .response
        envelope.requestID = requestID
        envelope.payloadType = payloadType
        envelope.payload = try response.serializedData()
        let frame = try FrameCodec().encode(payload: envelope.serializedData())
        connection.send(content: frame, completion: .contentProcessed { error in
            guard error == nil else {
                connection.cancel()
                return
            }
            completion()
        })
    }

    private static func receiveFrameBody(
        on connection: NWConnection,
        completion: @escaping @Sendable (Data) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                connection.cancel()
                return
            }
            let length = (UInt32(header[0]) << 24)
                | (UInt32(header[1]) << 16)
                | (UInt32(header[2]) << 8)
                | UInt32(header[3])
            guard length > 0, length <= UInt32(FrameCodec.defaultMaxEnvelopeLength) else {
                connection.cancel()
                return
            }
            connection.receive(
                minimumIncompleteLength: Int(length),
                maximumLength: Int(length)
            ) { body, _, _, _ in
                guard let body, body.count == Int(length) else {
                    connection.cancel()
                    return
                }
                completion(body)
            }
        }
    }
}

private enum FirstPairingTestServerError: Error {
    case listenerDidNotBecomeReady
    case invalidRequest
}
