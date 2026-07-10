import Combine
import DroidMatchCore
import Foundation

public enum DeviceSessionPhase: String, Sendable, Equatable {
    case idle
    case connecting
    case pairingRequired
    case startingPairing
    case awaitingApproval
    case finalizingPairing
    case ready
    case disconnecting
    case failed
}

public enum DeviceSessionFailure: String, Sendable, Equatable {
    case deviceUnavailable
    case deviceNotReady
    case adbUnavailable
    case timedOut
    case pairingRejected
    case identityChanged
    case credentialsUnavailable
    case authenticationFailed
    case connectionUnavailable
}

/// Main-actor product state for one selected Android device.
///
/// Raw ADB identity, ports, pairing keys, protobuf errors, and platform error
/// strings never enter this object. The model owns operation cancellation and a
/// one-shot approval gate; Core owns sockets, credentials, and forward cleanup.
@MainActor
public final class DeviceSessionModel: ObservableObject {
    @Published public private(set) var phase: DeviceSessionPhase = .idle
    @Published public private(set) var selectedDeviceID: UUID?
    @Published public private(set) var sessionInfo: ProductDeviceSessionInfo?
    @Published public private(set) var pairingPresentation: PairingPresentation?
    @Published public private(set) var failure: DeviceSessionFailure?
    @Published public private(set) var directoryBrowser: DirectoryBrowserModel?
    @Published public private(set) var diagnostics: DeviceDiagnosticsModel?
    @Published public private(set) var transferQueue: TransferQueueModel?

    public var canUploadFiles: Bool {
        sessionInfo?.grantedCapabilities.contains(.fileWrite) == true
    }

    private let coordinator: any ProductDeviceSessionCoordinating
    private var operationTask: Task<Void, Never>?
    private var disconnectTask: Task<Void, Never>?
    private var approvalGate: PairingApprovalGate?
    private var generation: UInt64 = 0

    public init(coordinator: any ProductDeviceSessionCoordinating) {
        self.coordinator = coordinator
    }

    deinit {
        operationTask?.cancel()
        disconnectTask?.cancel()
        let gate = approvalGate
        let coordinator = coordinator
        Task {
            await gate?.cancel()
            await coordinator.disconnect()
        }
    }

    public func connect(to deviceID: UUID) {
        generation &+= 1
        let operationGeneration = generation
        operationTask?.cancel()
        cancelApprovalGate()
        selectedDeviceID = deviceID
        sessionInfo = nil
        pairingPresentation = nil
        directoryBrowser = nil
        diagnostics = nil
        transferQueue?.stop()
        transferQueue = nil
        failure = nil
        phase = .connecting

        let coordinator = coordinator
        let pendingDisconnect = disconnectTask
        operationTask = Task { [weak self] in
            do {
                // A previous UI disconnect must finish before a new connect can
                // enter the coordinator. Otherwise its late teardown could close
                // the newly prepared lease and leave this generation stuck.
                await pendingDisconnect?.value
                try Task.checkCancellation()
                let outcome = try await coordinator.connect(to: deviceID)
                guard !Task.isCancelled else { return }
                switch outcome {
                case .pairingRequired:
                    self?.applyPairingRequired(generation: operationGeneration)
                case let .ready(info):
                    try await self?.applyReady(
                        info,
                        coordinator: coordinator,
                        generation: operationGeneration
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.applyFailure(error, generation: operationGeneration)
            }
        }
    }

    /// Begins first pairing only after Android has visibly opened its pairing
    /// window. The Android endpoint remains default-closed and is authoritative.
    @discardableResult
    public func beginPairing() -> Bool {
        guard phase == .pairingRequired, selectedDeviceID != nil else { return false }
        generation &+= 1
        let operationGeneration = generation
        operationTask?.cancel()
        cancelApprovalGate()
        failure = nil
        phase = .startingPairing
        let gate = PairingApprovalGate()
        approvalGate = gate
        let coordinator = coordinator

        operationTask = Task { [weak self] in
            do {
                let info = try await coordinator.pair(
                    clientDisplayName: "DroidMatch Mac",
                    approve: { [weak self, gate] presentation in
                        guard let self else { return false }
                        await self.presentPairingApproval(
                            presentation,
                            gate: gate,
                            generation: operationGeneration
                        )
                        return try await gate.wait()
                    }
                )
                guard !Task.isCancelled else { return }
                try await self?.applyReady(
                    info,
                    coordinator: coordinator,
                    generation: operationGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.applyFailure(error, generation: operationGeneration)
            }
        }
        return true
    }

    public func approvePairing() {
        resolvePairingApproval(approved: true)
    }

    public func rejectPairing() {
        resolvePairingApproval(approved: false)
    }

    public func disconnect() {
        generation &+= 1
        let operationGeneration = generation
        operationTask?.cancel()
        operationTask = nil
        cancelApprovalGate()
        pairingPresentation = nil
        directoryBrowser = nil
        diagnostics = nil
        transferQueue?.stop()
        transferQueue = nil
        failure = nil
        phase = .disconnecting
        let coordinator = coordinator
        disconnectTask = Task { [weak self] in
            await coordinator.disconnect()
            self?.applyDisconnected(generation: operationGeneration)
        }
    }

    private func presentPairingApproval(
        _ presentation: PairingPresentation,
        gate: PairingApprovalGate,
        generation: UInt64
    ) {
        guard generation == self.generation, approvalGate === gate else {
            Task { await gate.cancel() }
            return
        }
        pairingPresentation = presentation
        phase = .awaitingApproval
    }

    private func resolvePairingApproval(approved: Bool) {
        guard phase == .awaitingApproval, let gate = approvalGate else { return }
        approvalGate = nil
        pairingPresentation = nil
        phase = .finalizingPairing
        Task { await gate.resolve(approved: approved) }
    }

    private func cancelApprovalGate() {
        guard let gate = approvalGate else { return }
        approvalGate = nil
        Task { await gate.cancel() }
    }

    private func applyPairingRequired(generation: UInt64) {
        guard generation == self.generation else { return }
        operationTask = nil
        phase = .pairingRequired
    }

    private func applyReady(
        _ info: ProductDeviceSessionInfo,
        coordinator: any ProductDeviceSessionCoordinating,
        generation: UInt64
    ) async throws {
        guard generation == self.generation else { return }
        let client = try await coordinator.directoryListingClient()
        let scheduler = try await coordinator.transferScheduler()
        guard generation == self.generation else { return }
        let browser = DirectoryBrowserModel(client: client)
        browser.load(DirectoryListingQuery(path: "dm://roots/"))
        let diagnostics = DeviceDiagnosticsModel(loader: coordinator)
        diagnostics.refresh()
        let transferQueue = TransferQueueModel(scheduler: scheduler)
        transferQueue.start()
        operationTask = nil
        approvalGate = nil
        pairingPresentation = nil
        directoryBrowser = browser
        self.diagnostics = diagnostics
        self.transferQueue = transferQueue
        sessionInfo = info
        failure = nil
        phase = .ready
    }

    private func applyFailure(_ error: Error, generation: UInt64) {
        guard generation == self.generation else { return }
        operationTask = nil
        approvalGate = nil
        pairingPresentation = nil
        directoryBrowser = nil
        diagnostics = nil
        transferQueue?.stop()
        transferQueue = nil
        sessionInfo = nil
        failure = Self.presentationFailure(error)
        phase = .failed
    }

    private func applyDisconnected(generation: UInt64) {
        guard generation == self.generation else { return }
        selectedDeviceID = nil
        sessionInfo = nil
        disconnectTask = nil
        phase = .idle
    }

    private static func presentationFailure(_ error: Error) -> DeviceSessionFailure {
        if let error = error as? DeviceConnectionPreparationError {
            switch error {
            case .deviceUnavailable: return .deviceUnavailable
            case .deviceNotReady: return .deviceNotReady
            case .preparationInProgress, .unavailable: return .connectionUnavailable
            case .adbUnavailable: return .adbUnavailable
            case .timedOut: return .timedOut
            }
        }
        guard let error = error as? ProductDeviceSessionError else {
            return .connectionUnavailable
        }
        switch error {
        case .identityChanged: return .identityChanged
        case .pairingRejected: return .pairingRejected
        case .credentialsUnavailable: return .credentialsUnavailable
        case .authenticationFailed: return .authenticationFailed
        case .noPreparedDevice, .pairingNotRequired, .identityUnavailable,
             .connectionUnavailable:
            return .connectionUnavailable
        }
    }
}

private actor PairingApprovalGate {
    private enum Resolution: Sendable {
        case approved
        case rejected
        case cancelled
    }

    private enum State {
        case idle
        case waiting(CheckedContinuation<Bool, any Error>)
        case resolved(Resolution)
        case finished
    }

    private var state = State.idle

    func wait() async throws -> Bool {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func resolve(approved: Bool) {
        resolve(approved ? .approved : .rejected)
    }

    func cancel() {
        resolve(.cancelled)
    }

    private func install(_ continuation: CheckedContinuation<Bool, any Error>) {
        switch state {
        case .idle:
            state = .waiting(continuation)
        case let .resolved(resolution):
            state = .finished
            resume(continuation, resolution: resolution)
        case .waiting, .finished:
            continuation.resume(throwing: CancellationError())
        }
    }

    private func resolve(_ resolution: Resolution) {
        switch state {
        case .idle:
            state = .resolved(resolution)
        case let .waiting(continuation):
            state = .finished
            resume(continuation, resolution: resolution)
        case .resolved, .finished:
            return
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<Bool, any Error>,
        resolution: Resolution
    ) {
        switch resolution {
        case .approved: continuation.resume(returning: true)
        case .rejected: continuation.resume(returning: false)
        case .cancelled: continuation.resume(throwing: CancellationError())
        }
    }
}
