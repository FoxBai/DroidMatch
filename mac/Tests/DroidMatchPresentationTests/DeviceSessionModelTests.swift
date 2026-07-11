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
    private var delayDisconnect: Bool
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

    init(
        deviceID: UUID,
        connectError: (any Error & Sendable)? = nil,
        delayDisconnect: Bool = false
    ) {
        self.deviceID = deviceID
        self.connectError = connectError
        self.delayDisconnect = delayDisconnect
    }

    func connect(to deviceID: UUID) throws -> ProductDeviceConnectionOutcome {
        connects += 1
        if let connectError { throw connectError }
        guard deviceID == self.deviceID else {
            throw DeviceConnectionPreparationError.deviceUnavailable
        }
        return .pairingRequired
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
        return ProductDeviceSessionInfo(
            deviceID: deviceID,
            displayName: "Test Android",
            grantedCapabilities: [
                .fileList,
                .fileWrite,
                .resumableTransfer,
                .diagnostics,
            ]
        )
    }

    func directoryListingClient() -> any DirectoryListingClient {
        directoryClient
    }

    func transferScheduler() -> AsyncTransferScheduler {
        scheduler
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

    func connectCount() -> Int { connects }
    func pairCount() -> Int { pairs }
    func disconnectCount() -> Int { disconnects }
}

private enum DeviceSessionProbeError: Error {
    case unexpectedTransfer
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
