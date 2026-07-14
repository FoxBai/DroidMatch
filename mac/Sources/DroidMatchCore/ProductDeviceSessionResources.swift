import Foundation

/// Resources detached atomically from one product-session generation.
///
/// The coordinator remains the only owner of live session state. Once detached,
/// this value preserves the security-sensitive release order without retaining
/// or mutating the coordinator actor. In particular, invalidating the transfer
/// gate before the first suspension prevents an in-flight retry from opening a
/// new client against a forward that is about to be released.
/// 中文：首次挂起前先关闭 gate，避免 retry 在 forward 释放前新建 client。
struct ProductDeviceSessionDetachedResources {
    let lease: DeviceConnectionLease?
    let sessionClient: (any ProductSessionClient)?
    let pairingClient: (any ProductPairingClient)?
    let transferGate: ProductTransferSessionGate?
    let transferScheduler: AsyncTransferScheduler?
    let transferSchedulerBuildTask: Task<AsyncTransferScheduler, Error>?
    let keepaliveTask: Task<Void, Never>?

    func release(using connectionPreparer: any DeviceConnectionPreparing) async {
        transferSchedulerBuildTask?.cancel()
        await transferGate?.invalidate()
        keepaliveTask?.cancel()
        await transferScheduler?.suspendForSessionEnd()
        await pairingClient?.close()
        await sessionClient?.close()
        if let lease {
            await connectionPreparer.releaseConnection(lease)
        }
    }
}

/// Session-scoped factory gate captured by transfer coordinators.
///
/// It owns the only copy of the forward endpoint and product credentials used by
/// retry clients. Once invalidated it never reopens, so an old queue cannot attach
/// itself to a later device session even if a local port number is recycled.
actor ProductTransferSessionGate {
    private let lease: DeviceConnectionLease
    private let credentials: PairingCredentials
    private var isActive = true

    init(lease: DeviceConnectionLease, credentials: PairingCredentials) {
        self.lease = lease
        self.credentials = credentials
    }

    func makeClient(attemptIndex: Int) async throws -> AsyncRpcControlClient {
        _ = attemptIndex // Attempt identity is intentionally not security state.
        guard isActive else { throw CancellationError() }
        let session = try await AsyncFramedTcpSession.connect(
            host: lease.host,
            port: lease.port,
            timeoutSeconds: 10
        )
        guard isActive else {
            await session.close()
            throw CancellationError()
        }
        return AsyncRpcControlClient(
            session: session,
            credentials: credentials,
            requestedCapabilities: HandshakeSmokeClient.fullM1Capabilities,
            requestTimeoutSeconds: 10
        )
    }

    func invalidate() {
        isActive = false
    }
}
