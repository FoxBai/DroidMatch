import Foundation
import Testing
@testable import DroidMatchCore

private enum SessionAuthFixtureError: Error {
    case missingFixture
    case malformedLine(String)
    case missingValue(String)
    case invalidHex(String)
    case invalidInteger(String)
}

@Test func sessionAuthenticatorMatchesCrossPlatformFixture() throws {
    let fixture = try loadSessionAuthFixture()
    let pairingKey = try fixtureData("pairing_key", from: fixture)
    let pairingID = try fixtureData("pairing_id", from: fixture)
    let clientNonce = try fixtureData("client_nonce", from: fixture)
    let serverNonce = try fixtureData("server_nonce", from: fixture)
    let protocolMajor = try fixtureUInt32("protocol_major", from: fixture)
    let protocolMinor = try fixtureUInt32("protocol_minor", from: fixture)
    let transportKind = try fixtureUInt32("transport_kind", from: fixture)
    #expect(transportKind == UInt32(Droidmatch_V1_TransportKind.adb.rawValue))

    let transcript = try SessionAuthenticator.transcript(
        pairingID: pairingID,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
        protocolMajor: protocolMajor,
        protocolMinor: protocolMinor,
        transport: .adb
    )
    let transcriptHash = SessionAuthenticator.transcriptHash(transcript)
    let clientProof = try SessionAuthenticator.clientProof(
        pairingKey: pairingKey,
        transcriptHash: transcriptHash
    )
    let serverProof = try SessionAuthenticator.serverProof(
        pairingKey: pairingKey,
        transcriptHash: transcriptHash
    )
    let sessionKey = try SessionAuthenticator.sessionKey(
        pairingKey: pairingKey,
        transcriptHash: transcriptHash
    )
    let expectedTranscript = try fixtureData("transcript", from: fixture)
    let expectedTranscriptHash = try fixtureData("transcript_hash", from: fixture)
    let expectedClientProof = try fixtureData("client_proof", from: fixture)
    let expectedServerProof = try fixtureData("server_proof", from: fixture)
    let expectedSessionKey = try fixtureData("session_key", from: fixture)

    #expect(transcript == expectedTranscript)
    #expect(transcriptHash == expectedTranscriptHash)
    #expect(clientProof == expectedClientProof)
    #expect(serverProof == expectedServerProof)
    #expect(sessionKey == expectedSessionKey)
    #expect(try SessionAuthenticator.verifyClientProof(
        clientProof,
        pairingKey: pairingKey,
        transcriptHash: transcriptHash
    ))
    #expect(try SessionAuthenticator.verifyServerProof(
        serverProof,
        pairingKey: pairingKey,
        transcriptHash: transcriptHash
    ))
}

@Test func sessionAuthenticatorSeparatesRolesAndRejectsReplay() throws {
    let fixture = try loadSessionAuthFixture()
    let pairingKey = try fixtureData("pairing_key", from: fixture)
    let clientProof = try fixtureData("client_proof", from: fixture)
    let serverProof = try fixtureData("server_proof", from: fixture)
    let originalHash = try fixtureData("transcript_hash", from: fixture)

    #expect(try !SessionAuthenticator.verifyClientProof(
        serverProof,
        pairingKey: pairingKey,
        transcriptHash: originalHash
    ))
    #expect(try !SessionAuthenticator.verifyServerProof(
        clientProof,
        pairingKey: pairingKey,
        transcriptHash: originalHash
    ))

    var changedServerNonce = try fixtureData("server_nonce", from: fixture)
    changedServerNonce[0] ^= 0xff
    let changedTranscript = try SessionAuthenticator.transcript(
        pairingID: fixtureData("pairing_id", from: fixture),
        clientNonce: fixtureData("client_nonce", from: fixture),
        serverNonce: changedServerNonce,
        protocolMajor: 1,
        protocolMinor: 0,
        transport: .adb
    )
    let changedHash = SessionAuthenticator.transcriptHash(changedTranscript)
    #expect(try !SessionAuthenticator.verifyClientProof(
        clientProof,
        pairingKey: pairingKey,
        transcriptHash: changedHash
    ))
}

@Test func sessionAuthenticatorRejectsInvalidFixedLengths() throws {
    let fixture = try loadSessionAuthFixture()
    let pairingID = try fixtureData("pairing_id", from: fixture)
    let clientNonce = try fixtureData("client_nonce", from: fixture)
    let serverNonce = try fixtureData("server_nonce", from: fixture)

    #expect(throws: SessionAuthenticationError.self) {
        _ = try SessionAuthenticator.transcript(
            pairingID: pairingID.dropLast(),
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            protocolMajor: 1,
            protocolMinor: 0,
            transport: .adb
        )
    }
    #expect(throws: SessionAuthenticationError.self) {
        _ = try SessionAuthenticator.clientProof(
            pairingKey: Data(repeating: 0, count: 31),
            transcriptHash: Data(repeating: 0, count: 32)
        )
    }
}

private func loadSessionAuthFixture() throws -> [String: String] {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixtureURL = repositoryRoot
        .appendingPathComponent("fixtures", isDirectory: true)
        .appendingPathComponent("crypto", isDirectory: true)
        .appendingPathComponent("session-auth-v1.properties")
    guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
        throw SessionAuthFixtureError.missingFixture
    }

    let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
    var result: [String: String] = [:]
    for line in contents.split(whereSeparator: \.isNewline) {
        guard let separator = line.firstIndex(of: "=") else {
            throw SessionAuthFixtureError.malformedLine(String(line))
        }
        result[String(line[..<separator])] = String(line[line.index(after: separator)...])
    }
    return result
}

private func fixtureData(_ key: String, from fixture: [String: String]) throws -> Data {
    guard let value = fixture[key] else {
        throw SessionAuthFixtureError.missingValue(key)
    }
    guard value.count.isMultiple(of: 2) else {
        throw SessionAuthFixtureError.invalidHex(key)
    }

    var data = Data()
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<next], radix: 16) else {
            throw SessionAuthFixtureError.invalidHex(key)
        }
        data.append(byte)
        index = next
    }
    return data
}

private func fixtureUInt32(_ key: String, from fixture: [String: String]) throws -> UInt32 {
    guard let value = fixture[key], let parsed = UInt32(value) else {
        throw SessionAuthFixtureError.invalidInteger(key)
    }
    return parsed
}
