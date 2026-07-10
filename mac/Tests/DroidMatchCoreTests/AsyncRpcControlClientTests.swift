import Foundation
import Testing
@testable import DroidMatchCore

@Test func asyncRpcControlClientRunsCompleteControlPlaneOnOneSession() async throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToM1SmokeRequests)
    defer {
        server.cancel()
    }

    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 2
    )
    let client = AsyncRpcControlClient(session: session)

    do {
        let handshake = try await client.handshake()
        let heartbeat = try await client.heartbeat(monotonicMillis: 12_345)
        let deviceInfo = try await client.deviceInfo()
        let roots = try await client.listDir(path: "dm://roots/")
        let productRoots = try await client.listDirectoryPage(
            query: DirectoryListingQuery(path: "dm://roots/"),
            pageToken: nil
        )
        let diagnostics = try await client.diagnostics()

        #expect(handshake.serverName == "LocalFrameTestServer")
        #expect(handshake.protocolMajor == 1)
        #expect(handshake.grantedCapabilities == [.fileList, .diagnostics])
        #expect(heartbeat.monotonicMillis == 12_345)
        #expect(deviceInfo.deviceID == "loopback-test")
        #expect(deviceInfo.manufacturer == "DroidMatch")
        #expect(roots.entries.map(\.path) == ["dm://media-images/"])
        #expect(productRoots.entries.map(\.path) == ["dm://media-images/"])
        #expect(productRoots.entries.first?.kind == .virtual)
        #expect(productRoots.entries.first?.sizeBytes == nil)
        #expect(diagnostics.transport == .adb)
        #expect(diagnostics.serviceState == "rpc.session.open")
        await client.close()
    } catch {
        await client.close()
        throw error
    }
}

@Test func asyncRpcControlClientRejectsListingWithoutNegotiatedCapability() async throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToM1SmokeRequests)
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let client = AsyncRpcControlClient(
        session: session,
        requestedCapabilities: [.diagnostics]
    )

    _ = try await client.handshake()
    var rejectedWithoutFileList = false
    do {
        _ = try await client.listDir(path: "dm://roots/")
    } catch let RpcControlClientError.invalidTransferState(message) {
        rejectedWithoutFileList = message.contains("fileList")
    } catch {
        rejectedWithoutFileList = false
    }
    #expect(rejectedWithoutFileList)
    await client.close()
}

@Test func asyncRpcControlClientRequiresHandshakeAndCachesNegotiation() async throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyWithServerHello)
    defer {
        server.cancel()
    }

    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 2
    )
    let client = AsyncRpcControlClient(session: session)

    var sawHandshakeRequired = false
    do {
        _ = try await client.deviceInfo()
    } catch AsyncRpcControlClientStateError.handshakeRequired {
        sawHandshakeRequired = true
    } catch {
        sawHandshakeRequired = false
    }

    do {
        #expect(sawHandshakeRequired)
        let first = try await client.handshake()
        let cached = try await client.handshake()
        #expect(cached == first)
        await client.close()
    } catch {
        await client.close()
        throw error
    }
}

@Test func asyncRpcControlClientCompletesMutualPairedAuthentication() async throws {
    let pairingID = Data((0..<SessionAuthenticator.pairingIDLength).map { UInt8(0xa0 + $0) })
    let pairingKey = Data((0..<SessionAuthenticator.pairingKeyLength).map { UInt8($0) })
    let credentials = try PairingCredentials(pairingID: pairingID, pairingKey: pairingKey)
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.pairedAuthenticationHandler(
        pairingID: pairingID,
        pairingKey: pairingKey
    ))
    defer {
        server.cancel()
    }

    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let client = AsyncRpcControlClient(session: session, credentials: credentials)
    do {
        let result = try await client.handshake()
        #expect(result.authenticationState == .authenticated)
        #expect(result.serverNonce.count == SessionAuthenticator.nonceLength)
        #expect(result.grantedCapabilities == [.diagnostics])
        await client.close()
    } catch {
        await client.close()
        throw error
    }
}

@Test func asyncRpcControlClientRejectsPairedDowngrade() async throws {
    let pairingID = Data(repeating: 0xa0, count: SessionAuthenticator.pairingIDLength)
    let pairingKey = Data(repeating: 0x42, count: SessionAuthenticator.pairingKeyLength)
    let credentials = try PairingCredentials(pairingID: pairingID, pairingKey: pairingKey)
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyWithServerHello)
    defer {
        server.cancel()
    }

    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let client = AsyncRpcControlClient(session: session, credentials: credentials)
    var rejectedDowngrade = false
    do {
        _ = try await client.handshake()
    } catch AsyncRpcAuthenticationError.downgradeDetected {
        rejectedDowngrade = true
    } catch {
        rejectedDowngrade = false
    }
    #expect(rejectedDowngrade)
    await client.close()
}

@Test func asyncRpcControlClientRequiresCredentialsForPairedEndpoint() async throws {
    let pairingID = Data(repeating: 0xa0, count: SessionAuthenticator.pairingIDLength)
    let pairingKey = Data(repeating: 0x42, count: SessionAuthenticator.pairingKeyLength)
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.pairedAuthenticationHandler(
        pairingID: pairingID,
        pairingKey: pairingKey,
        allowMissingPairingID: true
    ))
    defer {
        server.cancel()
    }

    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let client = AsyncRpcControlClient(session: session)
    var credentialsRequired = false
    do {
        _ = try await client.handshake()
    } catch AsyncRpcAuthenticationError.credentialsRequired {
        credentialsRequired = true
    } catch {
        credentialsRequired = false
    }
    #expect(credentialsRequired)
    await client.close()
}

@Test func asyncRpcControlClientRejectsInvalidServerProof() async throws {
    let pairingID = Data(repeating: 0xa0, count: SessionAuthenticator.pairingIDLength)
    let pairingKey = Data(repeating: 0x42, count: SessionAuthenticator.pairingKeyLength)
    let credentials = try PairingCredentials(pairingID: pairingID, pairingKey: pairingKey)
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.pairedAuthenticationHandler(
        pairingID: pairingID,
        pairingKey: pairingKey,
        corruptServerProof: true
    ))
    defer {
        server.cancel()
    }

    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let client = AsyncRpcControlClient(session: session, credentials: credentials)
    var invalidProofRejected = false
    do {
        _ = try await client.handshake()
    } catch AsyncRpcAuthenticationError.invalidServerProof {
        invalidProofRejected = true
    } catch {
        invalidProofRejected = false
    }
    #expect(invalidProofRejected)
    await client.close()
}

@Test func asyncRpcControlClientRoutesConcurrentControlRequests() async throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToM1SmokeRequests)
    defer {
        server.cancel()
    }

    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 2
    )
    let client = AsyncRpcControlClient(session: session)

    do {
        _ = try await client.handshake()
        async let heartbeat = client.heartbeat(monotonicMillis: 98_765)
        async let deviceInfo = client.deviceInfo()
        let (heartbeatResponse, deviceResponse) = try await (heartbeat, deviceInfo)

        #expect(heartbeatResponse.monotonicMillis == 98_765)
        #expect(deviceResponse.deviceID == "loopback-test")
        await client.close()
    } catch {
        await client.close()
        throw error
    }
}

@Test func asyncRpcMultiplexerDoesNotApplyTransportTimeoutToIdleReader() async throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToM1SmokeRequests)
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 0.1
    )
    let client = AsyncRpcControlClient(
        session: session,
        requestTimeoutSeconds: 1
    )

    do {
        _ = try await client.handshake()
        try await Task.sleep(nanoseconds: 250_000_000)
        let heartbeat = try await client.heartbeat(monotonicMillis: 8_888)
        #expect(heartbeat.monotonicMillis == 8_888)
        await client.close()
    } catch {
        await client.close()
        throw error
    }
}

@Test func asyncRpcControlClientRejectsRequestsAfterClose() async throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyWithServerHello)
    defer {
        server.cancel()
    }

    let session = try await AsyncFramedTcpSession.connect(
        port: server.port,
        timeoutSeconds: 2
    )
    let client = AsyncRpcControlClient(session: session)
    _ = try await client.handshake()
    await client.close()

    var sawClosed = false
    do {
        _ = try await client.heartbeat(monotonicMillis: 1)
    } catch AsyncRpcControlClientStateError.closed {
        sawClosed = true
    } catch {
        sawClosed = false
    }
    #expect(sawClosed)
}

@Test func rpcEnvelopeCodecRejectsUnsupportedFrameVersion() throws {
    var envelope = Droidmatch_V1_RpcEnvelope()
    envelope.frameVersion = 2
    envelope.kind = .response
    envelope.requestID = 1
    envelope.payloadType = .heartbeatResponse

    #expect(throws: RpcEnvelopeCodecError.self) {
        _ = try RpcEnvelopeCodec.parse(envelope.serializedData())
    }
}

@Test func rpcEnvelopeCodecValidatesOptionalPayloadChecksum() throws {
    var envelope = Droidmatch_V1_RpcEnvelope()
    envelope.frameVersion = 1
    envelope.kind = .response
    envelope.requestID = 1
    envelope.payloadType = .heartbeatResponse
    envelope.payload = Data("checksummed-control-payload".utf8)
    envelope.flags = 1
    envelope.payloadCrc32 = Crc32.checksum(envelope.payload)

    let parsed = try RpcEnvelopeCodec.parse(envelope.serializedData())
    #expect(parsed.payload == envelope.payload)

    envelope.payloadCrc32 ^= 0xffff_ffff
    #expect(throws: RpcEnvelopeCodecError.self) {
        _ = try RpcEnvelopeCodec.parse(envelope.serializedData())
    }
}

@Test func rpcEnvelopeCodecRejectsMismatchedErrorRequestID() throws {
    var remoteError = Droidmatch_V1_DroidMatchError()
    remoteError.code = .permissionRequired
    remoteError.message = "permission is required"

    var envelope = Droidmatch_V1_RpcEnvelope()
    envelope.frameVersion = 1
    envelope.kind = .error
    envelope.requestID = 99
    envelope.error = remoteError

    var sawRequestIDMismatch = false
    do {
        _ = try RpcEnvelopeCodec.response(
            from: envelope.serializedData(),
            requestID: 7,
            expectedPayloadType: .listDirResponse
        )
    } catch let RpcControlClientError.requestIDMismatch(expected, actual) {
        sawRequestIDMismatch = expected == 7 && actual == 99
    } catch {
        sawRequestIDMismatch = false
    }
    #expect(sawRequestIDMismatch)
}
