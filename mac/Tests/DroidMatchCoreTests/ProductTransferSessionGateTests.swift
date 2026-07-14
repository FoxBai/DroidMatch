import Foundation
import Testing
@testable import DroidMatchCore

@Test func productTransferSessionGateCreatesAuthenticatedRetryClient() async throws {
    let pairingID = Data(repeating: 0xa0, count: SessionAuthenticator.pairingIDLength)
    let pairingKey = Data(repeating: 0x42, count: SessionAuthenticator.pairingKeyLength)
    let credentials = try transferGateCredentials(pairingID: pairingID, pairingKey: pairingKey)
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.pairedAuthenticationHandler(
        pairingID: pairingID,
        pairingKey: pairingKey
    ))
    defer { server.cancel() }
    let gate = ProductTransferSessionGate(
        lease: transferGateLease(port: server.port),
        credentials: credentials
    )

    let client = try await gate.makeClient(attemptIndex: 2)
    do {
        let result = try await client.handshake()
        #expect(result.authenticationState == .authenticated)
        #expect(result.grantedCapabilities == [.diagnostics])
        await client.close()
        await gate.invalidate()
    } catch {
        await client.close()
        await gate.invalidate()
        throw error
    }
}

@Test func productTransferSessionGateRejectsClientCreationAfterInvalidation() async throws {
    let gate = ProductTransferSessionGate(
        lease: transferGateLease(port: 1),
        credentials: try transferGateCredentials(),
        sessionConnector: { _, _, _ in
            throw ProductTransferSessionGateTestError.connectorCalled
        }
    )
    await gate.invalidate()

    var rejectedAsCancellation = false
    do {
        _ = try await gate.makeClient(attemptIndex: 0)
    } catch is CancellationError {
        rejectedAsCancellation = true
    }
    #expect(rejectedAsCancellation)
}

@Test func productTransferSessionGateClosesConnectionCompletedAfterInvalidation() async throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.echoOneFrame)
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let connectorHold = ProductTransferSessionConnectorHold()
    let gate = ProductTransferSessionGate(
        lease: transferGateLease(port: server.port),
        credentials: try transferGateCredentials(),
        sessionConnector: { host, port, timeoutSeconds in
            try await connectorHold.connect(
                host: host,
                port: port,
                timeoutSeconds: timeoutSeconds,
                returning: session
            )
        }
    )
    let clientTask = Task {
        try await gate.makeClient(attemptIndex: 1)
    }

    await connectorHold.waitUntilEntered()
    await gate.invalidate()
    await connectorHold.release()

    var rejectedAsCancellation = false
    do {
        _ = try await clientTask.value
    } catch is CancellationError {
        rejectedAsCancellation = true
    }
    #expect(rejectedAsCancellation)
    #expect(await connectorHold.receivedEndpoint() == .init(
        host: "127.0.0.1",
        port: server.port,
        timeoutSeconds: 10
    ))

    var closedBeforeReuse = false
    do {
        _ = try await session.roundTrip(payload: Data([1]))
    } catch FramedTcpClientError.connectionClosed {
        closedBeforeReuse = true
    } catch {
        closedBeforeReuse = false
    }
    #expect(closedBeforeReuse)
    await session.close()
}

private enum ProductTransferSessionGateTestError: Error {
    case connectorCalled
}

private struct ProductTransferSessionEndpoint: Sendable, Equatable {
    let host: String
    let port: Int
    let timeoutSeconds: TimeInterval
}

private actor ProductTransferSessionConnectorHold {
    private var endpoint: ProductTransferSessionEndpoint?
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func connect(
        host: String,
        port: Int,
        timeoutSeconds: TimeInterval,
        returning session: AsyncFramedTcpSession
    ) async throws -> AsyncFramedTcpSession {
        endpoint = .init(host: host, port: port, timeoutSeconds: timeoutSeconds)
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return session
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func receivedEndpoint() -> ProductTransferSessionEndpoint? { endpoint }
}

private func transferGateCredentials(
    pairingID: Data = Data(repeating: 0xa0, count: SessionAuthenticator.pairingIDLength),
    pairingKey: Data = Data(repeating: 0x42, count: SessionAuthenticator.pairingKeyLength)
) throws -> PairingCredentials {
    try PairingCredentials(
        pairingID: pairingID,
        pairingKey: pairingKey,
        deviceIdentityFingerprint: LocalFrameTestServer.pairedDeviceIdentityFingerprint
    )
}

private func transferGateLease(port: Int) -> DeviceConnectionLease {
    DeviceConnectionLease(deviceID: UUID(), host: "127.0.0.1", port: port)
}
