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
    case secureEndpointRequired
    case credentialsUnavailable
    case authenticationFailed
    case connectionUnavailable
}

/// Minimal UI state for the visible SAS decision.
///
/// Core's device-identity fingerprint remains below Presentation; the user
/// decision needs only a safe display label and the six-digit code.
public struct DevicePairingPresentation: Sendable, Equatable {
    public let androidDisplayName: String?
    public let shortAuthenticationString: String

    init(_ presentation: PairingPresentation) {
        androidDisplayName = ProductDisplayText.value(presentation.androidDisplayName)
        shortAuthenticationString = presentation.shortAuthenticationString
    }
}

/// Main-actor product state for one selected Android device.
///
/// Raw ADB identity, ports, pairing keys, protobuf errors, and platform error
/// strings never enter this object. The model owns operation cancellation and a
/// one-shot approval gate; Core owns sockets, credentials, and forward cleanup.
@MainActor
public final class DeviceSessionModel: ObservableObject {
    /// One coordinator teardown that may be awaited by both the operation that
    /// detected a ready-assembly failure and a replacement UI operation.
    ///
    /// The ID lets either waiter clear only the teardown it observed. The task
    /// itself captures Core, not this model, so cleanup remains authoritative if
    /// the originating operation is cancelled while `disconnect()` is running.
    private struct SessionTeardown {
        let id: UUID
        let task: Task<Void, Never>
    }

    @Published public private(set) var phase: DeviceSessionPhase = .idle
    @Published public private(set) var selectedDeviceID: UUID?
    @Published public private(set) var sessionInfo: ProductDeviceSessionInfo?
    @Published public private(set) var pairingPresentation: DevicePairingPresentation?
    @Published public private(set) var failure: DeviceSessionFailure?
    @Published public private(set) var directoryBrowser: DirectoryBrowserModel?
    @Published public private(set) var mediaLibrary: MediaLibraryModel?
    @Published public private(set) var diagnostics: DeviceDiagnosticsModel?
    @Published public private(set) var transferQueue: TransferQueueModel?

    public var canUploadFiles: Bool {
        sessionInfo?.grantedCapabilities.contains(.fileWrite) == true
    }

    public var sessionDisplayName: String? {
        guard let displayName = sessionInfo?.displayName, !displayName.isEmpty else {
            return nil
        }
        return displayName
    }

    private let coordinator: any ProductDeviceSessionCoordinating
    private let transferDataSourceFactory:
        @Sendable (AsyncTransferScheduler) -> any TransferQueueDataSource
    private var operationTask: Task<Void, Never>?
    private var disconnectTask: Task<Void, Never>?
    private var sessionTeardown: SessionTeardown?
    private var sessionEventTask: Task<Void, Never>?
    private var approvalGate: PairingApprovalGate?
    private var generation: UInt64 = 0
    private var runtimeInvalidated = false

    public init(
        coordinator: any ProductDeviceSessionCoordinating,
        transferDataSourceFactory: @escaping @Sendable (AsyncTransferScheduler) -> any TransferQueueDataSource = {
            AsyncTransferSchedulerDataSource(scheduler: $0)
        }
    ) {
        self.coordinator = coordinator
        self.transferDataSourceFactory = transferDataSourceFactory
    }

    deinit {
        operationTask?.cancel()
        disconnectTask?.cancel()
        sessionEventTask?.cancel()
        let gate = approvalGate
        let coordinator = coordinator
        let pendingTeardown = sessionTeardown
        Task {
            await gate?.cancel()
            if let pendingTeardown {
                await pendingTeardown.task.value
            } else {
                await coordinator.disconnect()
            }
        }
    }

    public func connect(to deviceID: UUID) {
        guard !runtimeInvalidated else { return }
        generation &+= 1
        let operationGeneration = generation
        operationTask?.cancel()
        sessionEventTask?.cancel()
        sessionEventTask = nil
        cancelApprovalGate()
        selectedDeviceID = deviceID
        sessionInfo = nil
        pairingPresentation = nil
        directoryBrowser = nil
        mediaLibrary = nil
        diagnostics = nil
        transferQueue?.stop()
        transferQueue = nil
        failure = nil
        phase = .connecting

        let coordinator = coordinator
        let pendingDisconnect = disconnectTask
        let pendingTeardown = sessionTeardown
        operationTask = Task { [weak self] in
            do {
                // A previous UI disconnect must finish before a new connect can
                // enter the coordinator. A ready-assembly rollback is registered
                // separately because it can begin before `.failed` is published.
                // Both must finish before a replacement session is allowed in.
                await pendingDisconnect?.value
                await pendingTeardown?.task.value
                if let pendingTeardown {
                    self?.finishSessionTeardown(id: pendingTeardown.id)
                }
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
        guard !runtimeInvalidated,
              phase == .pairingRequired,
              selectedDeviceID != nil else { return false }
        generation &+= 1
        let operationGeneration = generation
        operationTask?.cancel()
        sessionEventTask?.cancel()
        sessionEventTask = nil
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
        guard !runtimeInvalidated else { return }
        resolvePairingApproval(approved: true)
    }

    public func rejectPairing() {
        guard !runtimeInvalidated else { return }
        resolvePairingApproval(approved: false)
    }

    public func disconnect() {
        guard !runtimeInvalidated || (phase != .idle && phase != .disconnecting) else {
            return
        }
        generation &+= 1
        let operationGeneration = generation
        operationTask?.cancel()
        operationTask = nil
        sessionEventTask?.cancel()
        sessionEventTask = nil
        cancelApprovalGate()
        pairingPresentation = nil
        directoryBrowser = nil
        mediaLibrary = nil
        diagnostics = nil
        transferQueue?.stop()
        transferQueue = nil
        failure = nil
        phase = .disconnecting
        let coordinator = coordinator
        // If ready assembly is already rolling this same session back, reuse its
        // teardown instead of issuing a concurrent disconnect. The wrapper still
        // owns the UI transition to `.idle` for this explicit operation.
        let teardown = beginSessionTeardown(using: coordinator)
        disconnectTask = Task { [weak self] in
            await teardown.task.value
            self?.finishSessionTeardown(id: teardown.id)
            self?.applyDisconnected(generation: operationGeneration)
        }
    }

    /// Irreversibly closes this Presentation session when the running process no
    /// longer matches the published App. Repeated notifications share the same
    /// gate and cannot start a second disconnect or a replacement connection.
    public func invalidateForRuntimeReplacement() {
        guard !runtimeInvalidated else { return }
        runtimeInvalidated = true
        disconnect()
    }

    /// Trust-management actions use this strict boundary before deleting a
    /// credential, ensuring the authenticated client and forward are gone first.
    public func disconnectAndWaitIfNeeded() async {
        guard phase != .idle else { return }
        if phase == .disconnecting {
            await disconnectTask?.value
            return
        }
        disconnect()
        await disconnectTask?.value
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
        pairingPresentation = DevicePairingPresentation(presentation)
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
        let presentationInfo = ProductDeviceSessionInfo(
            deviceID: info.deviceID,
            displayName: ProductDisplayText.value(info.displayName) ?? "",
            grantedCapabilities: info.grantedCapabilities
        )
        let events: AsyncStream<ProductDeviceSessionEvent>
        let client: any DirectoryBrowserClient
        let scheduler: AsyncTransferScheduler
        do {
            events = try await coordinator.sessionInvalidationEvents()
            client = try await coordinator.directoryListingClient()
            scheduler = try await coordinator.transferScheduler()
        } catch {
            try await rollbackReadyAssembly(
                after: error,
                coordinator: coordinator,
                generation: generation
            )
            return
        }
        guard generation == self.generation else { return }
        let browser = DirectoryBrowserModel(
            client: client,
            excludedRootPaths: Set(MediaLibrarySection.allCases.map(\.rootPath))
        )
        browser.load(DirectoryListingQuery(path: "dm://roots/"))
        let mediaLibrary = MediaLibraryModel(client: client)
        mediaLibrary.start()
        let diagnostics = DeviceDiagnosticsModel(loader: coordinator)
        diagnostics.refresh()
        let transferQueue = TransferQueueModel(
            dataSource: transferDataSourceFactory(scheduler)
        )
        transferQueue.start()
        operationTask = nil
        approvalGate = nil
        pairingPresentation = nil
        directoryBrowser = browser
        self.mediaLibrary = mediaLibrary
        self.diagnostics = diagnostics
        self.transferQueue = transferQueue
        sessionInfo = presentationInfo
        failure = nil
        phase = .ready
        observeSessionEvents(events, generation: generation)
    }

    /// Makes authenticated Presentation setup all-or-nothing.
    ///
    /// An explicit replacement/disconnect cancels the owning operation and owns
    /// Core cleanup itself, so that cancellation remains silent. A dependency may
    /// also throw `CancellationError` because Core invalidated its scheduler build;
    /// when the caller task is still current, that is a connection failure and the
    /// authenticated client/queue/forward must be released before failure appears.
    private func rollbackReadyAssembly(
        after error: Error,
        coordinator: any ProductDeviceSessionCoordinating,
        generation operationGeneration: UInt64
    ) async throws {
        guard !Task.isCancelled, operationGeneration == generation else {
            throw CancellationError()
        }
        let teardown = beginSessionTeardown(using: coordinator)
        await teardown.task.value
        finishSessionTeardown(id: teardown.id)
        guard !Task.isCancelled, operationGeneration == generation else {
            throw CancellationError()
        }
        if error is CancellationError {
            throw ProductDeviceSessionError.connectionUnavailable
        }
        throw error
    }

    private func beginSessionTeardown(
        using coordinator: any ProductDeviceSessionCoordinating
    ) -> SessionTeardown {
        if let sessionTeardown { return sessionTeardown }
        let teardown = SessionTeardown(
            id: UUID(),
            task: Task { await coordinator.disconnect() }
        )
        sessionTeardown = teardown
        return teardown
    }

    private func finishSessionTeardown(id: UUID) {
        guard sessionTeardown?.id == id else { return }
        sessionTeardown = nil
    }

    private func applyFailure(_ error: Error, generation: UInt64) {
        guard generation == self.generation else { return }
        operationTask = nil
        sessionEventTask?.cancel()
        sessionEventTask = nil
        approvalGate = nil
        pairingPresentation = nil
        directoryBrowser = nil
        mediaLibrary = nil
        diagnostics = nil
        transferQueue?.stop()
        transferQueue = nil
        sessionInfo = nil
        failure = Self.presentationFailure(error)
        phase = .failed
    }

    private func observeSessionEvents(
        _ events: AsyncStream<ProductDeviceSessionEvent>,
        generation: UInt64
    ) {
        sessionEventTask?.cancel()
        sessionEventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.applySessionEvent(event, generation: generation)
            }
        }
    }

    private func applySessionEvent(_ event: ProductDeviceSessionEvent, generation: UInt64) {
        guard generation == self.generation, phase == .ready else { return }
        self.generation &+= 1
        operationTask?.cancel()
        operationTask = nil
        sessionEventTask = nil
        approvalGate = nil
        pairingPresentation = nil
        directoryBrowser = nil
        mediaLibrary = nil
        diagnostics = nil
        transferQueue?.stop()
        transferQueue = nil
        sessionInfo = nil
        switch event {
        case .connectionUnavailable:
            failure = .connectionUnavailable
        }
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
        case .secureEndpointRequired: return .secureEndpointRequired
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
