import DroidMatchCore
import DroidMatchPresentation
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
    try await Task.sleep(nanoseconds: 20_000_000)
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
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(model.phase == .disconnecting)
    #expect(await coordinator.disconnectCount() == 1)

    await coordinator.finishDisconnect()
    #expect(await waitForSessionPhase(model, .idle))
    #expect(await coordinator.disconnectCount() == 1)
    #expect(model.failure == nil)
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
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(await coordinator.connectCount() == 1)

    await coordinator.finishDisconnect()
    #expect(await waitForSessionPhase(model, .pairingRequired))
    #expect(await coordinator.connectCount() == 2)

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

private actor DeviceSessionCoordinatorProbe: ProductDeviceSessionCoordinating {
    private let deviceID: UUID
    private let connectError: (any Error & Sendable)?
    private let connectsReady: Bool
    private var delayDisconnect: Bool
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
    private var disconnectContinuation: CheckedContinuation<Void, Never>?
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
        self.readyAssemblyFailures = readyAssemblyFailures
    }

    func connect(to deviceID: UUID) throws -> ProductDeviceConnectionOutcome {
        connects += 1
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
        pairs += 1
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
        if !readyAssemblyFailures.isEmpty {
            switch readyAssemblyFailures.removeFirst() {
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
        sessionEventContinuation?.finish()
        sessionEventContinuation = pair.continuation
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
        disconnects += 1
        sessionEventContinuation?.finish()
        sessionEventContinuation = nil
        if delayDisconnect {
            await withCheckedContinuation { continuation in
                disconnectContinuation = continuation
            }
        }
    }

    func finishDisconnect() {
        disconnectContinuation?.resume()
        disconnectContinuation = nil
    }

    func disableDisconnectDelay() {
        delayDisconnect = false
    }

    func invalidateSession() {
        sessionEventContinuation?.yield(.connectionUnavailable)
        sessionEventContinuation?.finish()
        sessionEventContinuation = nil
    }

    func connectCount() -> Int { connects }
    func pairCount() -> Int { pairs }
    func disconnectCount() -> Int { disconnects }

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
