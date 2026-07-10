import Foundation
import CryptoKit
import Testing
@testable import DroidMatchCore

private enum PairingFixtureError: Error {
    case missingFixture
    case malformedLine(String)
    case missingValue(String)
    case invalidHex(String)
    case invalidInteger(String)
}

@Test func pairingAuthenticatorMatchesCrossPlatformFixture() throws {
    let fixture = try loadPairingFixture()
    let client = try PairingEphemeralKeyPair(
        privateKeyRawRepresentation: pairingFixtureData("client_private_key", from: fixture)
    )
    let server = try PairingEphemeralKeyPair(
        privateKeyRawRepresentation: pairingFixtureData("server_private_key", from: fixture)
    )
    let expectedClientPublicKey = try pairingFixtureData("client_public_key", from: fixture)
    let expectedServerPublicKey = try pairingFixtureData("server_public_key", from: fixture)
    #expect(client.publicKeyX963Representation == expectedClientPublicKey)
    #expect(server.publicKeyX963Representation == expectedServerPublicKey)

    let clientSharedSecret = try client.sharedSecret(
        peerPublicKeyX963Representation: server.publicKeyX963Representation
    )
    let serverSharedSecret = try server.sharedSecret(
        peerPublicKeyX963Representation: client.publicKeyX963Representation
    )
    #expect(clientSharedSecret == serverSharedSecret)
    let expectedSharedSecret = try pairingFixtureData("shared_secret", from: fixture)
    #expect(clientSharedSecret == expectedSharedSecret)
    let identityFingerprint = PairingAuthenticator.transcriptHash(
        try pairingFixtureData("device_identity_public_key", from: fixture)
    )
    let expectedIdentityFingerprint = try pairingFixtureData(
        "device_identity_fingerprint",
        from: fixture
    )
    #expect(identityFingerprint == expectedIdentityFingerprint)
    let transcript = try pairingTranscript(fixture)
    let identitySigningKey = try P256.Signing.PrivateKey(
        rawRepresentation: pairingFixtureData("device_identity_private_key", from: fixture)
    )
    let identitySignature = try identitySigningKey.signature(for: transcript)
    #expect(try PairingAuthenticator.verifyDeviceIdentitySignature(
        identitySignature.derRepresentation,
        deviceIdentityPublicKey: identitySigningKey.publicKey.x963Representation,
        transcript: transcript
    ))

    let transcriptHash = PairingAuthenticator.transcriptHash(transcript)
    let secrets = try PairingAuthenticator.deriveSecrets(
        sharedSecret: clientSharedSecret,
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

    let expectedTranscript = try pairingFixtureData("transcript", from: fixture)
    let expectedTranscriptHash = try pairingFixtureData("transcript_hash", from: fixture)
    let expectedConfirmationKey = try pairingFixtureData("confirmation_key", from: fixture)
    let expectedPairingKey = try pairingFixtureData("pairing_key", from: fixture)
    let expectedClientConfirmation = try pairingFixtureData("client_confirmation", from: fixture)
    let expectedServerConfirmation = try pairingFixtureData("server_confirmation", from: fixture)
    let expectedFinalConfirmation = try pairingFixtureData("final_confirmation", from: fixture)
    #expect(transcript == expectedTranscript)
    #expect(transcriptHash == expectedTranscriptHash)
    #expect(secrets.confirmationKey == expectedConfirmationKey)
    #expect(secrets.pairingKey == expectedPairingKey)
    #expect(secrets.shortAuthenticationString == fixture["sas"])
    #expect(clientConfirmation == expectedClientConfirmation)
    #expect(serverConfirmation == expectedServerConfirmation)
    #expect(finalConfirmation == expectedFinalConfirmation)
    #expect(try PairingAuthenticator.verifyClientConfirmation(
        clientConfirmation,
        confirmationKey: secrets.confirmationKey,
        transcriptHash: transcriptHash
    ))
    #expect(try PairingAuthenticator.verifyServerConfirmation(
        serverConfirmation,
        confirmationKey: secrets.confirmationKey,
        transcriptHash: transcriptHash
    ))
    #expect(try PairingAuthenticator.verifyFinalConfirmation(
        finalConfirmation,
        confirmationKey: secrets.confirmationKey,
        transcriptHash: transcriptHash,
        serverConfirmation: serverConfirmation
    ))
}

@Test func pairingAuthenticatorSeparatesRolesAndBindsFreshTranscript() throws {
    let fixture = try loadPairingFixture()
    let confirmationKey = try pairingFixtureData("confirmation_key", from: fixture)
    let originalHash = try pairingFixtureData("transcript_hash", from: fixture)
    let clientConfirmation = try pairingFixtureData("client_confirmation", from: fixture)
    let serverConfirmation = try pairingFixtureData("server_confirmation", from: fixture)

    #expect(try !PairingAuthenticator.verifyClientConfirmation(
        serverConfirmation,
        confirmationKey: confirmationKey,
        transcriptHash: originalHash
    ))
    #expect(try !PairingAuthenticator.verifyServerConfirmation(
        clientConfirmation,
        confirmationKey: confirmationKey,
        transcriptHash: originalHash
    ))

    var changedServerNonce = try pairingFixtureData("server_nonce", from: fixture)
    changedServerNonce[0] ^= 0xff
    let changedTranscript = try PairingAuthenticator.transcript(
        pairingVersion: 1,
        pairingID: pairingFixtureData("pairing_id", from: fixture),
        clientPublicKey: pairingFixtureData("client_public_key", from: fixture),
        serverPublicKey: pairingFixtureData("server_public_key", from: fixture),
        deviceIdentityPublicKey: pairingFixtureData("device_identity_public_key", from: fixture),
        clientNonce: pairingFixtureData("client_nonce", from: fixture),
        serverNonce: changedServerNonce,
        clientName: try pairingFixtureString("client_name", from: fixture),
        serverName: try pairingFixtureString("server_name", from: fixture)
    )
    let changedHash = PairingAuthenticator.transcriptHash(changedTranscript)
    #expect(try !PairingAuthenticator.verifyClientConfirmation(
        clientConfirmation,
        confirmationKey: confirmationKey,
        transcriptHash: changedHash
    ))
}

@Test func pairingKeyAgreementRejectsMalformedPeerAndProducesFreshMutualSecret() throws {
    let client = PairingEphemeralKeyPair()
    let server = PairingEphemeralKeyPair()
    let clientSecret = try client.sharedSecret(
        peerPublicKeyX963Representation: server.publicKeyX963Representation
    )
    let serverSecret = try server.sharedSecret(
        peerPublicKeyX963Representation: client.publicKeyX963Representation
    )
    #expect(clientSecret == serverSecret)
    #expect(clientSecret.count == PairingAuthenticator.keyLength)

    #expect(throws: PairingAuthenticationError.self) {
        _ = try client.sharedSecret(peerPublicKeyX963Representation: Data(repeating: 0, count: 65))
    }
    #expect(throws: PairingAuthenticationError.self) {
        _ = try PairingAuthenticator.transcript(
            pairingVersion: 1,
            pairingID: Data(repeating: 0, count: 16),
            clientPublicKey: client.publicKeyX963Representation,
            serverPublicKey: server.publicKeyX963Representation,
            deviceIdentityPublicKey: server.publicKeyX963Representation,
            clientNonce: Data(repeating: 0, count: 32),
            serverNonce: Data(repeating: 0, count: 32),
            clientName: "",
            serverName: "Android"
        )
    }
}

private func pairingTranscript(_ fixture: [String: String]) throws -> Data {
    try PairingAuthenticator.transcript(
        pairingVersion: pairingFixtureUInt32("version", from: fixture),
        pairingID: pairingFixtureData("pairing_id", from: fixture),
        clientPublicKey: pairingFixtureData("client_public_key", from: fixture),
        serverPublicKey: pairingFixtureData("server_public_key", from: fixture),
        deviceIdentityPublicKey: pairingFixtureData("device_identity_public_key", from: fixture),
        clientNonce: pairingFixtureData("client_nonce", from: fixture),
        serverNonce: pairingFixtureData("server_nonce", from: fixture),
        clientName: pairingFixtureString("client_name", from: fixture),
        serverName: pairingFixtureString("server_name", from: fixture)
    )
}

private func loadPairingFixture() throws -> [String: String] {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixtureURL = repositoryRoot
        .appendingPathComponent("fixtures", isDirectory: true)
        .appendingPathComponent("crypto", isDirectory: true)
        .appendingPathComponent("pairing-v1.properties")
    guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
        throw PairingFixtureError.missingFixture
    }
    let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
    var result: [String: String] = [:]
    for line in contents.split(whereSeparator: \.isNewline) {
        guard let separator = line.firstIndex(of: "=") else {
            throw PairingFixtureError.malformedLine(String(line))
        }
        result[String(line[..<separator])] = String(line[line.index(after: separator)...])
    }
    return result
}

private func pairingFixtureString(_ key: String, from fixture: [String: String]) throws -> String {
    guard let value = fixture[key] else {
        throw PairingFixtureError.missingValue(key)
    }
    return value
}

private func pairingFixtureData(_ key: String, from fixture: [String: String]) throws -> Data {
    let value = try pairingFixtureString(key, from: fixture)
    guard value.count.isMultiple(of: 2) else {
        throw PairingFixtureError.invalidHex(key)
    }
    var data = Data()
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<next], radix: 16) else {
            throw PairingFixtureError.invalidHex(key)
        }
        data.append(byte)
        index = next
    }
    return data
}

private func pairingFixtureUInt32(_ key: String, from fixture: [String: String]) throws -> UInt32 {
    let value = try pairingFixtureString(key, from: fixture)
    guard let parsed = UInt32(value) else {
        throw PairingFixtureError.invalidInteger(key)
    }
    return parsed
}
