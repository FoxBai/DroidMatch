import Foundation

/// Regenerates the non-secret deterministic first-pairing fixture.
/// Compile this file together with PairingAuthenticator.swift; never substitute
/// these scalar-1/scalar-2 test keys in product code.
@main
struct GeneratePairingVector {
    static func main() throws {
        var clientPrivate = Data(repeating: 0, count: 32)
        clientPrivate[31] = 1
        var serverPrivate = Data(repeating: 0, count: 32)
        serverPrivate[31] = 2
        var identityPrivate = Data(repeating: 0, count: 32)
        identityPrivate[31] = 3

        let client = try PairingEphemeralKeyPair(privateKeyRawRepresentation: clientPrivate)
        let server = try PairingEphemeralKeyPair(privateKeyRawRepresentation: serverPrivate)
        let identity = try PairingEphemeralKeyPair(privateKeyRawRepresentation: identityPrivate)
        let sharedSecret = try client.sharedSecret(
            peerPublicKeyX963Representation: server.publicKeyX963Representation
        )
        let pairingID = sequentialBytes(start: 0xa0, count: 16)
        let clientNonce = sequentialBytes(start: 0x10, count: 32)
        let serverNonce = sequentialBytes(start: 0x40, count: 32)
        let transcript = try PairingAuthenticator.transcript(
            pairingVersion: 1,
            pairingID: pairingID,
            clientPublicKey: client.publicKeyX963Representation,
            serverPublicKey: server.publicKeyX963Representation,
            deviceIdentityPublicKey: identity.publicKeyX963Representation,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            clientName: "DroidMatch Mac",
            serverName: "DroidMatch Android"
        )
        let transcriptHash = PairingAuthenticator.transcriptHash(transcript)
        let secrets = try PairingAuthenticator.deriveSecrets(
            sharedSecret: sharedSecret,
            transcriptHash: transcriptHash
        )
        let clientConfirmation = try PairingAuthenticator.clientConfirmation(
            confirmationKey: secrets.confirmationKey,
            transcriptHash: transcriptHash
        )
        let serverConfirmation = try PairingAuthenticator.serverConfirmation(
            confirmationKey: secrets.confirmationKey,
            transcriptHash: transcriptHash
        )
        let finalConfirmation = try PairingAuthenticator.finalConfirmation(
            confirmationKey: secrets.confirmationKey,
            transcriptHash: transcriptHash,
            serverConfirmation: serverConfirmation
        )

        emit("version", "1")
        emit("client_name", "DroidMatch Mac")
        emit("server_name", "DroidMatch Android")
        emit("client_private_key", hex(clientPrivate))
        emit("client_public_key", hex(client.publicKeyX963Representation))
        emit("server_private_key", hex(serverPrivate))
        emit("server_public_key", hex(server.publicKeyX963Representation))
        emit("device_identity_private_key", hex(identityPrivate))
        emit("device_identity_public_key", hex(identity.publicKeyX963Representation))
        emit("device_identity_fingerprint", hex(PairingAuthenticator.transcriptHash(
            identity.publicKeyX963Representation
        )))
        emit("pairing_id", hex(pairingID))
        emit("client_nonce", hex(clientNonce))
        emit("server_nonce", hex(serverNonce))
        emit("shared_secret", hex(sharedSecret))
        emit("transcript", hex(transcript))
        emit("transcript_hash", hex(transcriptHash))
        emit("confirmation_key", hex(secrets.confirmationKey))
        emit("pairing_key", hex(secrets.pairingKey))
        emit("sas", secrets.shortAuthenticationString)
        emit("client_confirmation", hex(clientConfirmation))
        emit("server_confirmation", hex(serverConfirmation))
        emit("final_confirmation", hex(finalConfirmation))
    }

    private static func sequentialBytes(start: UInt8, count: Int) -> Data {
        Data((0..<count).map { start &+ UInt8($0) })
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func emit(_ key: String, _ value: String) {
        print("\(key)=\(value)")
    }
}
