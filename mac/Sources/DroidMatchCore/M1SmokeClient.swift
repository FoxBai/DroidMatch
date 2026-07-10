import Foundation

public struct M1SmokeResult: Sendable {
    public let handshake: HandshakeSmokeResult
    public let heartbeat: Droidmatch_V1_HeartbeatResponse
    public let deviceInfo: Droidmatch_V1_DeviceInfoResponse
    public let rootList: Droidmatch_V1_ListDirResponse
    public let diagnostics: Droidmatch_V1_DiagnosticsResponse
}

public struct M1SmokeClient {
    public init() {}

    /// Runs the baseline control-plane probe on the product async transport.
    ///
    /// The command intentionally requests the same capability set as the legacy
    /// synchronous client so changing the transport does not change negotiation
    /// or the archived CLI output contract.
    public func run(
        host: String = "127.0.0.1",
        port: Int,
        timeoutSeconds: TimeInterval = 5
    ) async throws -> M1SmokeResult {
        let session = try await AsyncFramedTcpSession.connect(
            host: host,
            port: port,
            timeoutSeconds: timeoutSeconds
        )
        let controlClient = AsyncRpcControlClient(
            session: session,
            requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities,
            requestTimeoutSeconds: timeoutSeconds
        )
        do {
            let result = M1SmokeResult(
                handshake: try await controlClient.handshake(),
                heartbeat: try await controlClient.heartbeat(
                    monotonicMillis: MonotonicClock.milliseconds()
                ),
                deviceInfo: try await controlClient.deviceInfo(),
                rootList: try await controlClient.listDir(path: "dm://roots/"),
                diagnostics: try await controlClient.diagnostics()
            )
            await controlClient.close()
            return result
        } catch {
            await controlClient.close()
            throw error
        }
    }
}

private enum MonotonicClock {
    static func milliseconds() -> Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1_000)
    }
}
