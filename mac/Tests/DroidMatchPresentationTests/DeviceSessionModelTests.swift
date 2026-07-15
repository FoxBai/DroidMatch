import DroidMatchCore
import DroidMatchPresentation
import Dispatch
import Foundation
import Testing

@Test
@MainActor
func deviceSessionModelPresentsApprovalAndUnlocksRootBrowser() async throws {
    let deviceID = UUID()
    let coordinator = DeviceSessionCoordinatorProbe(deviceID: deviceID)
    let model = DeviceSessionModel(coordinator: coordinator)

    model.connect(to: deviceID)
    #expect(await waitForSessionPhase(model, .pairingRequired))
    #expect(model.beginPairing())
    #expect(await waitForSessionPhase(model, .awaitingApproval))
    #expect(model.pairingPresentation?.shortAuthenticationString == "654321")

    model.approvePairing()
    #expect(await waitForSessionPhase(model, .ready))
    #expect(model.sessionInfo?.deviceID == deviceID)
    #expect(model.sessionInfo?.displayName == "Test Android")
    #expect(model.directoryBrowser?.query?.path == "dm://roots/")
    #expect(model.diagnostics != nil)
    #expect(model.transferQueue != nil)
    #expect(model.canUploadFiles)
    #expect(await coordinator.pairCount() == 1)
}

@Test
@MainActor
func deviceSessionModelLeavesReadyWhenAuthenticatedSessionEnds() async throws {
    let deviceID = UUID()
    let coordinator = DeviceSessionCoordinatorProbe(deviceID: deviceID)
    let model = DeviceSessionModel(coordinator: coordinator)

    model.connect(to: deviceID)
    #expect(await waitForSessionPhase(model, .pairingRequired))
    #expect(model.beginPairing())
    #expect(await waitForSessionPhase(model, .awaitingApproval))
    model.approvePairing()
    #expect(await waitForSessionPhase(model, .ready))

    await coordinator.invalidateSession()

    #expect(await waitForSessionPhase(model, .failed))
    #expect(model.failure == .connectionUnavailable)
    #expect(model.selectedDeviceID == deviceID)
    #expect(model.sessionInfo == nil)
    #expect(model.pairingPresentation == nil)
    #expect(model.directoryBrowser == nil)
    #expect(model.diagnostics == nil)
    #expect(model.transferQueue == nil)
    #expect(!model.canUploadFiles)
    #expect(await coordinator.disconnectCount() == 0)
}

@Test
@MainActor
func deviceSessionModelRejectsPairingWithoutLeakingRawError() async throws {
    let deviceID = UUID()
    let coordinator = DeviceSessionCoordinatorProbe(deviceID: deviceID)
    let model = DeviceSessionModel(coordinator: coordinator)

    model.connect(to: deviceID)
    #expect(await waitForSessionPhase(model, .pairingRequired))
    #expect(model.beginPairing())
    #expect(await waitForSessionPhase(model, .awaitingApproval))
    model.rejectPairing()

    #expect(await waitForSessionPhase(model, .failed))
    #expect(model.failure == .pairingRejected)
    #expect(model.pairingPresentation == nil)
    #expect(model.directoryBrowser == nil)
    #expect(model.transferQueue == nil)
    #expect(!model.canUploadFiles)
}

@Test
@MainActor
func deviceSessionModelDisconnectCancelsPendingApprovalAndReturnsIdle() async throws {
    let deviceID = UUID()
    let coordinator = DeviceSessionCoordinatorProbe(deviceID: deviceID)
    let model = DeviceSessionModel(coordinator: coordinator)

    model.connect(to: deviceID)
    #expect(await waitForSessionPhase(model, .pairingRequired))
    #expect(model.beginPairing())
    #expect(await waitForSessionPhase(model, .awaitingApproval))

    model.disconnect()
    #expect(await waitForSessionPhase(model, .idle))
    #expect(model.selectedDeviceID == nil)
    #expect(model.pairingPresentation == nil)
    #expect(await coordinator.disconnectCount() == 1)
}

@Test
@MainActor
func deviceSessionModelMapsPreparationFailureToStableProductState() async throws {
    let deviceID = UUID()
    let coordinator = DeviceSessionCoordinatorProbe(
        deviceID: deviceID,
        connectError: DeviceConnectionPreparationError.deviceNotReady
    )
    let model = DeviceSessionModel(coordinator: coordinator)

    model.connect(to: deviceID)

    #expect(await waitForSessionPhase(model, .failed))
    #expect(model.failure == .deviceNotReady)
}

@Test
@MainActor
func deviceSessionModelExplainsWhenAndroidIsStillInDebugMode() async throws {
    let deviceID = UUID()
    let coordinator = DeviceSessionCoordinatorProbe(
        deviceID: deviceID,
        connectError: ProductDeviceSessionError.secureEndpointRequired
    )
    let model = DeviceSessionModel(coordinator: coordinator)

    model.connect(to: deviceID)

    #expect(await waitForSessionPhase(model, .failed))
    #expect(model.failure == .secureEndpointRequired)
}

@Test
@MainActor
func deviceSessionModelDisconnectsAuthenticatedReconnectWhenReadyAssemblyFails() async throws {
    let deviceID = UUID()
    let coordinator = DeviceSessionCoordinatorProbe(
        deviceID: deviceID,
        connectsReady: true,
        readyAssemblyFailures: [.unavailable]
    )
    let model = DeviceSessionModel(coordinator: coordinator)

    model.connect(to: deviceID)

    #expect(await waitForSessionPhase(model, .failed))
    #expect(model.failure == .connectionUnavailable)
    #expect(model.sessionInfo == nil)
    #expect(model.directoryBrowser == nil)
    #expect(model.diagnostics == nil)
    #expect(model.transferQueue == nil)
    #expect(await coordinator.connectCount() == 1)
    #expect(await coordinator.disconnectCount() == 1)
}

@Test
@MainActor
func deviceSessionModelTreatsInternalReadyAssemblyCancellationAsFailure() async throws {
    let deviceID = UUID()
    let coordinator = DeviceSessionCoordinatorProbe(
        deviceID: deviceID,
        connectsReady: true,
        readyAssemblyFailures: [.cancellation]
    )
    let model = DeviceSessionModel(coordinator: coordinator)

    model.connect(to: deviceID)

    #expect(await waitForSessionPhase(model, .failed))
    #expect(model.failure == .connectionUnavailable)
    #expect(model.sessionInfo == nil)
    #expect(model.directoryBrowser == nil)
    #expect(model.diagnostics == nil)
    #expect(model.transferQueue == nil)
    #expect(await coordinator.disconnectCount() == 1)
}

@Test
@MainActor
func deviceSessionModelDisconnectsAfterPairingReadyAssemblyFails() async throws {
    let deviceID = UUID()
    let coordinator = DeviceSessionCoordinatorProbe(
        deviceID: deviceID,
        readyAssemblyFailures: [.unavailable]
    )
    let model = DeviceSessionModel(coordinator: coordinator)

    model.connect(to: deviceID)
    #expect(await waitForSessionPhase(model, .pairingRequired))
    #expect(model.beginPairing())
    #expect(await waitForSessionPhase(model, .awaitingApproval))
    model.approvePairing()

    #expect(await waitForSessionPhase(model, .failed))
    #expect(model.failure == .connectionUnavailable)
    #expect(model.sessionInfo == nil)
    #expect(model.directoryBrowser == nil)
    #expect(model.diagnostics == nil)
    #expect(model.transferQueue == nil)
    #expect(await coordinator.pairCount() == 1)
    #expect(await coordinator.disconnectCount() == 1)
}

@Test
@MainActor
func deviceSessionModelWaitsForFailedReadyAssemblyTeardownBeforeReplacement() async throws {
    let deviceID = UUID()
    let coordinator = DeviceSessionCoordinatorProbe(
        deviceID: deviceID,
        connectsReady: true,
        delayDisconnect: true,
        readyAssemblyFailures: [.unavailable]
    )
    let model = DeviceSessionModel(coordinator: coordinator)

    model.connect(to: deviceID)
    #expect(await waitForDisconnectCount(coordinator, 1))
    #expect(model.phase == .connecting)

    model.connect(to: deviceID)
    await mainActorTurnFence()
    #expect(await coordinator.connectCount() == 1)
    #expect(await coordinator.disconnectCount() == 1)

    await coordinator.finishDisconnect()
    #expect(await waitForSessionPhase(model, .ready))
    #expect(await coordinator.connectCount() == 2)
    #expect(await coordinator.disconnectCount() == 1)
    #expect(model.failure == nil)
    #expect(model.directoryBrowser != nil)
    #expect(model.diagnostics != nil)
    #expect(model.transferQueue != nil)
    #expect(await coordinator.eventTrace() == [
        .connect(1),
        .disconnectStarted(1),
        .disconnectFinished(1),
        .connect(2),
    ])

    await coordinator.disableDisconnectDelay()
    model.disconnect()
    #expect(await waitForSessionPhase(model, .idle))
    #expect(await coordinator.disconnectCount() == 2)
}

@Test
@MainActor
func deviceSessionModelReusesFailedReadyAssemblyTeardownForExplicitDisconnect() async throws {
    let deviceID = UUID()
    let coordinator = DeviceSessionCoordinatorProbe(
        deviceID: deviceID,
        connectsReady: true,
        delayDisconnect: true,
        readyAssemblyFailures: [.unavailable]
    )
    let model = DeviceSessionModel(coordinator: coordinator)

    model.connect(to: deviceID)
    #expect(await waitForDisconnectCount(coordinator, 1))

    model.disconnect()
    await mainActorTurnFence()
    #expect(model.phase == .disconnecting)
    #expect(await coordinator.disconnectCount() == 1)

    await coordinator.finishDisconnect()
    #expect(await waitForSessionPhase(model, .idle))
    #expect(await coordinator.disconnectCount() == 1)
    #expect(model.failure == nil)
    await mainActorTurnFence()
    #expect(await coordinator.eventTrace() == [
        .connect(1),
        .disconnectStarted(1),
        .disconnectFinished(1),
    ])
    await coordinator.disableDisconnectDelay()
}

@Test
@MainActor
func deviceSessionModelWaitsForDisconnectBeforeImmediateReconnect() async throws {
    let deviceID = UUID()
    let coordinator = DeviceSessionCoordinatorProbe(
        deviceID: deviceID,
        delayDisconnect: true
    )
    let model = DeviceSessionModel(coordinator: coordinator)
    model.connect(to: deviceID)
    #expect(await waitForSessionPhase(model, .pairingRequired))

    model.disconnect()
    #expect(await waitForDisconnectCount(coordinator, 1))
    model.connect(to: deviceID)
    await mainActorTurnFence()
    #expect(await coordinator.connectCount() == 1)

    await coordinator.finishDisconnect()
    #expect(await waitForSessionPhase(model, .pairingRequired))
    #expect(await coordinator.connectCount() == 2)
    #expect(await coordinator.eventTrace() == [
        .connect(1),
        .disconnectStarted(1),
        .disconnectFinished(1),
        .connect(2),
    ])

    await coordinator.resetDisconnectGate()
    model.disconnect()
    #expect(await waitForDisconnectCount(coordinator, 2))
    await coordinator.finishDisconnect()
    #expect(await waitForSessionPhase(model, .idle))
    await coordinator.disableDisconnectDelay()
}

@Test
@MainActor
func deviceSessionModelCanAwaitDisconnectBeforeRevokingTrust() async throws {
    let deviceID = UUID()
    let coordinator = DeviceSessionCoordinatorProbe(deviceID: deviceID, delayDisconnect: true)
    let model = DeviceSessionModel(coordinator: coordinator)
    model.connect(to: deviceID)
    #expect(await waitForSessionPhase(model, .pairingRequired))

    let operation = Task { await model.disconnectAndWaitIfNeeded() }
    #expect(await waitForDisconnectCount(coordinator, 1))
    #expect(model.phase == .disconnecting)
    await coordinator.finishDisconnect()
    await operation.value
    #expect(model.phase == .idle)
    await coordinator.disableDisconnectDelay()
}

private final class DeviceSessionCoordinatorProbe:
    ProductDeviceSessionCoordinating,
    @unchecked Sendable
{
    private let deviceID: UUID
    private let connectError: (any Error & Sendable)?
    private let connectsReady: Bool
    private let lock = NSLock()
    private var delayDisconnect: Bool
    private var disconnectGate: DeviceSessionDisconnectGate?
    private var readyAssemblyFailures: [ReadyAssemblyFailure]
    private let directoryClient = DeviceSessionDirectoryClientProbe()
    private let scheduler: AsyncTransferScheduler = {
        let factory: AsyncRpcControlClientFactory = { _ in
            throw DeviceSessionProbeError.unexpectedTransfer
        }
        return AsyncTransferScheduler(
            downloadCoordinator: AsyncDownloadCoordinator(clientFactory: factory),
            uploadCoordinator: AsyncUploadCoordinator(clientFactory: factory),
            maxConcurrentJobs: 1
        )
    }()
    private var connects = 0
    private var pairs = 0
    private var disconnects = 0
    private var events: [DeviceSessionCoordinatorEvent] = []
    private var sessionEventContinuation:
        AsyncStream<ProductDeviceSessionEvent>.Continuation?

    init(
        deviceID: UUID,
        connectError: (any Error & Sendable)? = nil,
        connectsReady: Bool = false,
        delayDisconnect: Bool = false,
        readyAssemblyFailures: [ReadyAssemblyFailure] = []
    ) {
        self.deviceID = deviceID
        self.connectError = connectError
        self.connectsReady = connectsReady
        self.delayDisconnect = delayDisconnect
        disconnectGate = delayDisconnect ? DeviceSessionDisconnectGate() : nil
        self.readyAssemblyFailures = readyAssemblyFailures
    }

    func connect(to deviceID: UUID) throws -> ProductDeviceConnectionOutcome {
        locked {
            connects += 1
            events.append(.connect(connects))
        }
        if let connectError { throw connectError }
        guard deviceID == self.deviceID else {
            throw DeviceConnectionPreparationError.deviceUnavailable
        }
        return connectsReady ? .ready(sessionInfo()) : .pairingRequired
    }

    func pair(
        clientDisplayName: String,
        approve: @escaping @Sendable (PairingPresentation) async throws -> Bool
    ) async throws -> ProductDeviceSessionInfo {
        locked { pairs += 1 }
        let accepted = try await approve(
            PairingPresentation(
                androidDisplayName: "Test Android",
                shortAuthenticationString: "654321",
                deviceIdentityFingerprint: Data(repeating: 0x77, count: 32)
            )
        )
        guard accepted else {
            throw ProductDeviceSessionError.pairingRejected
        }
        return sessionInfo()
    }

    func directoryListingClient() -> any DirectoryBrowserClient {
        directoryClient
    }

    func transferScheduler() throws -> AsyncTransferScheduler {
        let failure = locked {
            readyAssemblyFailures.isEmpty ? nil : readyAssemblyFailures.removeFirst()
        }
        if let failure {
            switch failure {
            case .unavailable:
                throw DeviceSessionProbeError.readyAssemblyUnavailable
            case .cancellation:
                throw CancellationError()
            }
        }
        return scheduler
    }

    func sessionInvalidationEvents() -> AsyncStream<ProductDeviceSessionEvent> {
        let pair = AsyncStream<ProductDeviceSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let previous = locked {
            let previous = sessionEventContinuation
            sessionEventContinuation = pair.continuation
            return previous
        }
        previous?.finish()
        return pair.stream
    }

    func diagnosticsSnapshot() -> ProductDeviceDiagnosticsSnapshot {
        ProductDeviceDiagnosticsSnapshot(
            manufacturer: "Example",
            model: "Phone",
            androidVersion: "14",
            sdkLevel: 34,
            totalStorageBytes: 1_000,
            freeStorageBytes: 400,
            batteryPercent: 70,
            permissions: [],
            serviceState: .connected,
            recentErrorCount: 0,
            counters: [:]
        )
    }

    func disconnect() async {
        let state: (
            id: Int,
            continuation: AsyncStream<ProductDeviceSessionEvent>.Continuation?,
            gate: DeviceSessionDisconnectGate?
        ) = locked {
            disconnects += 1
            let disconnectID = disconnects
            events.append(.disconnectStarted(disconnectID))
            let continuation = sessionEventContinuation
            sessionEventContinuation = nil
            if delayDisconnect, disconnectGate == nil {
                disconnectGate = DeviceSessionDisconnectGate()
            }
            return (
                disconnectID,
                continuation,
                delayDisconnect ? disconnectGate : nil
            )
        }
        state.continuation?.finish()
        await state.gate?.wait()
        locked { events.append(.disconnectFinished(state.id)) }
    }

    func finishDisconnect() async {
        let gate = locked { disconnectGate }
        await gate?.release()
    }

    func resetDisconnectGate() async {
        locked {
            if delayDisconnect {
                disconnectGate = DeviceSessionDisconnectGate()
            }
        }
    }

    func disableDisconnectDelay() async {
        let gate = locked {
            delayDisconnect = false
            let gate = disconnectGate
            disconnectGate = nil
            return gate
        }
        await gate?.release()
    }

    func invalidateSession() async {
        let continuation = locked {
            let continuation = sessionEventContinuation
            sessionEventContinuation = nil
            return continuation
        }
        continuation?.yield(.connectionUnavailable)
        continuation?.finish()
    }

    func connectCount() async -> Int { locked { connects } }
    func pairCount() async -> Int { locked { pairs } }
    func disconnectCount() async -> Int { locked { disconnects } }
    func eventTrace() async -> [DeviceSessionCoordinatorEvent] { locked { events } }

    private func sessionInfo() -> ProductDeviceSessionInfo {
        ProductDeviceSessionInfo(
            deviceID: deviceID,
            displayName: "Test Android",
            grantedCapabilities: [
                .fileList,
                .fileRead,
                .fileWrite,
                .resumableTransfer,
                .diagnostics,
            ]
        )
    }

    private func locked<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private actor DeviceSessionDisconnectGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private enum DeviceSessionCoordinatorEvent: Sendable, Equatable {
    case connect(Int)
    case disconnectStarted(Int)
    case disconnectFinished(Int)
}

private enum ReadyAssemblyFailure: Sendable {
    case unavailable
    case cancellation
}

private enum DeviceSessionProbeError: Error, Sendable {
    case unexpectedTransfer
    case readyAssemblyUnavailable
}

private actor DeviceSessionDirectoryClientProbe: DirectoryBrowserClient {
    func listDirectoryPage(
        query: DirectoryListingQuery,
        pageToken: String?
    ) -> DirectoryListingPage {
        DirectoryListingPage(entries: [], nextPageToken: nil)
    }
}

@MainActor
private func waitForSessionPhase(
    _ model: DeviceSessionModel,
    _ expected: DeviceSessionPhase
) async -> Bool {
    for _ in 0..<200 {
        if model.phase == expected { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

private func waitForDisconnectCount(
    _ coordinator: DeviceSessionCoordinatorProbe,
    _ expected: Int
) async -> Bool {
    for _ in 0..<200 {
        if await coordinator.disconnectCount() == expected { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

/// Lets work already enqueued on the MainActor reach its first suspension
/// without relying on a wall-clock observation window.
/// 中文：让已入队的 MainActor 工作运行到首个挂起点，不依赖固定时间窗口。
@MainActor
private func mainActorTurnFence() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            continuation.resume()
        }
    }
}
