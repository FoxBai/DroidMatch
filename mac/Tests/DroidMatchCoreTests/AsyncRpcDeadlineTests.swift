import Foundation
@preconcurrency import Network
import Testing
@testable import DroidMatchCore

private enum TransferOpenDeadlineDirection: CaseIterable, Sendable {
    case download
    case upload

    var wireValue: Droidmatch_V1_TransferDirection {
        switch self {
        case .download: .download
        case .upload: .upload
        }
    }
}

@Test func asyncRpcControlDeadlineTerminatesTheAmbiguousSession() async throws {
    try await withDeadlineClient(
        handler: LocalFrameTestServer.controlDeadlineHandler
    ) { client in
        var observedTimeout = false
        do {
            _ = try await client.heartbeat(monotonicMillis: 1)
        } catch let FramedTcpClientError.timedOut(stage, seconds) {
            observedTimeout = stage.hasPrefix("waiting for RPC response ")
                && seconds == deadlineTestTimeout
        }
        #expect(observedTimeout)
        await expectClosedSession(client)
    }
}

@Test(arguments: TransferOpenDeadlineDirection.allCases)
private func asyncRpcTransferOpenDeadlineTerminatesTheAmbiguousSession(
    direction: TransferOpenDeadlineDirection
) async throws {
    try await withDeadlineClient(
        handler: LocalFrameTestServer.transferOpenDeadlineHandler(
            direction: direction.wireValue
        )
    ) { client in
        var observedTimeout = false
        do {
            switch direction {
            case .download:
                _ = try await client.openDownload(
                    sourcePath: "dm://app-sandbox/deadline.bin",
                    transferID: "deadline-download"
                )
            case .upload:
                _ = try await client.openUpload(
                    sourcePath: "mac-local-upload",
                    destinationPath: "dm://app-sandbox/deadline.bin",
                    transferID: "deadline-upload",
                    expectedSizeBytes: 2
                )
            }
        } catch let FramedTcpClientError.timedOut(stage, seconds) {
            observedTimeout = stage.hasPrefix("waiting for transfer open response ")
                && seconds == deadlineTestTimeout
        }
        #expect(observedTimeout)
        await expectClosedSession(client)
    }
}

@Test func asyncRpcUploadAcknowledgementDeadlineTerminatesTheAmbiguousSession() async throws {
    try await withDeadlineClient(
        handler: LocalFrameTestServer.uploadAcknowledgementDeadlineHandler
    ) { client in
        let upload = try await client.openUpload(
            sourcePath: "mac-local-upload",
            destinationPath: "dm://app-sandbox/deadline-ack.bin",
            transferID: "deadline-upload-ack",
            expectedSizeBytes: 2,
            preferredChunkSizeBytes: 2
        )
        var observedTimeout = false
        do {
            _ = try await upload.sendChunk(
                offsetBytes: 0,
                data: Data("ok".utf8),
                finalChunk: true
            )
        } catch let FramedTcpClientError.timedOut(stage, seconds) {
            observedTimeout = stage.hasPrefix("waiting for upload ACK ")
                && seconds == deadlineTestTimeout
        }
        #expect(observedTimeout)
        await expectClosedSession(client)
    }
}

@Test func asyncRpcDeadlineSaturatesHugeFiniteTimeoutWithoutTrapping() async throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToM1SmokeRequests)
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let client = AsyncRpcControlClient(
        session: session,
        requestTimeoutSeconds: .greatestFiniteMagnitude
    )
    do {
        _ = try await client.handshake()
        let heartbeat = try await client.heartbeat(monotonicMillis: 2)
        #expect(heartbeat.monotonicMillis == 2)
        await client.close()
    } catch {
        await client.close()
        throw error
    }
}

private let deadlineTestTimeout: TimeInterval = 0.05

private func withDeadlineClient(
    handler: @escaping @Sendable (NWConnection) -> Void,
    operation: @escaping @Sendable (AsyncRpcControlClient) async throws -> Void
) async throws {
    let server = try LocalFrameTestServer(handler: handler)
    defer { server.cancel() }
    let session = try await AsyncFramedTcpSession.connect(port: server.port, timeoutSeconds: 2)
    let client = AsyncRpcControlClient(
        session: session,
        requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities,
        requestTimeoutSeconds: deadlineTestTimeout
    )
    do {
        _ = try await client.handshake()
        try await operation(client)
        await client.close()
    } catch {
        await client.close()
        throw error
    }
}

private func expectClosedSession(_ client: AsyncRpcControlClient) async {
    await #expect(throws: AsyncRpcControlClientStateError.closed) {
        _ = try await client.heartbeat(monotonicMillis: 3)
    }
}
