import Foundation
@preconcurrency import Network
import Testing
@testable import DroidMatchCore

@Test func m1SmokeClientRunsTheBaselineControlPlaneOnOneRealSession() async throws {
    let server = try LocalFrameTestServer(handler: LocalFrameTestServer.replyToM1SmokeRequests)
    defer { server.cancel() }

    let result = try await M1SmokeClient().run(
        port: server.port,
        timeoutSeconds: 2
    )

    #expect(result.handshake.serverName == "LocalFrameTestServer")
    #expect(result.handshake.protocolMajor == 1)
    #expect(result.handshake.grantedCapabilities == HandshakeSmokeClient.fullM1Capabilities)
    #expect(result.heartbeat.monotonicMillis > 0)
    #expect(result.deviceInfo.deviceID == "loopback-test")
    #expect(result.rootList.entries.map(\.path) == ["dm://media-images/"])
    #expect(result.diagnostics.transport == .adb)
    #expect(result.diagnostics.serviceState == "rpc.session.open")
}

@Test func m1SmokeClientClosesItsSessionAfterRecoverableRemoteFailure() async throws {
    let probe = M1SmokeRecoverableFailureProbe()
    let server = try LocalFrameTestServer(handler: probe.handle)
    defer { server.cancel() }

    var observedFailure = false
    do {
        _ = try await M1SmokeClient().run(
            port: server.port,
            timeoutSeconds: 2
        )
    } catch let RpcControlClientError.remoteError(error) {
        observedFailure = error.code == .permissionRequired
    }

    #expect(observedFailure)
    #expect(await probe.waitForClientClose())
}

/// Returns a recoverable RPC error after Hello and heartbeat, then keeps the
/// server side open. `AsyncRpcControlClient` deliberately preserves sessions for
/// remote application errors, so observing EOF proves `M1SmokeClient.run()` owns
/// cleanup of its failed orchestration rather than relying on the lower layer.
///
/// 中文：在 Hello 和 heartbeat 后返回可恢复远端错误并保持服务端连接；只有
/// M1SmokeClient 的失败清理会主动关闭该 session，因此 EOF 是编排器所有权证据。
private final class M1SmokeRecoverableFailureProbe: @unchecked Sendable {
    private let didObserveClientClose = LockedValue(false)

    func handle(on connection: NWConnection) {
        receiveRequest(index: 0, on: connection)
    }

    func waitForClientClose() async -> Bool {
        for _ in 0..<200 {
            if didObserveClientClose.value() {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return didObserveClientClose.value()
    }

    private func receiveRequest(index: Int, on connection: NWConnection) {
        LocalFrameTestServer.receiveFrameBody(on: connection) { [self] requestBody in
            do {
                if index < 2 {
                    let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
                    let expectedType: Droidmatch_V1_PayloadType = index == 0
                        ? .clientHello
                        : .heartbeatRequest
                    guard request.payloadType == expectedType else {
                        throw LocalEchoServerError.unexpectedPayloadType
                    }
                    let response = try LocalFrameTestServer.m1SmokeResponse(to: requestBody)
                    LocalFrameTestServer.send(response.payloads, on: connection) {
                        self.receiveRequest(index: index + 1, on: connection)
                    }
                    return
                }

                let request = try Droidmatch_V1_RpcEnvelope(serializedBytes: requestBody)
                guard request.payloadType == .deviceInfoRequest else {
                    throw LocalEchoServerError.unexpectedPayloadType
                }
                var remoteError = Droidmatch_V1_DroidMatchError()
                remoteError.code = .permissionRequired
                remoteError.message = "bounded smoke fixture error"
                var response = Droidmatch_V1_RpcEnvelope()
                response.frameVersion = 1
                response.kind = .error
                response.requestID = request.requestID
                response.error = remoteError
                LocalFrameTestServer.send([try response.serializedData()], on: connection) {
                    self.observeClientClose(on: connection)
                }
            } catch {
                connection.cancel()
            }
        }
    }

    private func observeClientClose(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
            [self] data, _, isComplete, error in
            if isComplete || error != nil || data == nil {
                didObserveClientClose.set(true)
                connection.cancel()
                return
            }
            observeClientClose(on: connection)
        }
    }
}
