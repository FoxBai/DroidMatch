import Combine
import DroidMatchCore
import Foundation

public enum DeviceDiscoveryPhase: String, Sendable, Equatable {
    case idle
    case loading
    case refreshing
    case loaded
    case failed
}

public enum DeviceDiscoveryFailure: String, Sendable, Equatable {
    case adbUnavailable
    case timedOut
    case unavailable
}

/// Privacy-bounded row for the native device list.
///
/// The Core discovery actor replaces ADB serials with opaque UUIDs before this
/// value is created. Only model/product labels and coarse connection state are
/// allowed into SwiftUI state.
public struct DeviceDiscoveryItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let modelName: String?
    public let productName: String?
    public let connectionState: DeviceConnectionState
    public let transport: DeviceTransportKind

    init(_ device: DiscoveredDevice) {
        id = device.id
        modelName = device.modelName
        productName = device.productName
        connectionState = device.connectionState
        transport = device.transport
    }
}

/// Main-actor ownership boundary for product device discovery.
///
/// Refresh is replace-on-success. A failed refresh retains the last snapshot
/// but marks it stale, so the UI never silently presents old reachability as a
/// current fact. Generation checks also reject late dependencies that ignore
/// cooperative cancellation.
@MainActor
public final class DeviceDiscoveryModel: ObservableObject {
    @Published public private(set) var devices: [DeviceDiscoveryItem] = []
    @Published public private(set) var phase: DeviceDiscoveryPhase = .idle
    @Published public private(set) var failure: DeviceDiscoveryFailure?
    @Published public private(set) var isShowingStaleDevices = false

    public var readyDeviceCount: Int {
        devices.lazy.filter { $0.connectionState == .ready }.count
    }

    private let discovery: any DeviceDiscovering
    private var refreshTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(discovery: any DeviceDiscovering) {
        self.discovery = discovery
    }

    deinit {
        refreshTask?.cancel()
    }

    public func refresh() {
        generation &+= 1
        let currentGeneration = generation
        refreshTask?.cancel()
        failure = nil
        isShowingStaleDevices = false
        phase = devices.isEmpty ? .loading : .refreshing

        let discovery = self.discovery
        refreshTask = Task { [weak self] in
            do {
                let values = try await discovery.devices()
                guard !Task.isCancelled else { return }
                self?.apply(values, generation: currentGeneration)
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                self?.applyFailure(.unavailable, generation: currentGeneration)
            } catch let error as DeviceDiscoveryError {
                guard !Task.isCancelled else { return }
                self?.applyFailure(Self.presentationFailure(error), generation: currentGeneration)
            } catch {
                guard !Task.isCancelled else { return }
                self?.applyFailure(.unavailable, generation: currentGeneration)
            }
        }
    }

    private func apply(_ values: [DiscoveredDevice], generation: UInt64) {
        guard generation == self.generation else { return }
        refreshTask = nil
        devices = values.map(DeviceDiscoveryItem.init)
        phase = .loaded
        failure = nil
        isShowingStaleDevices = false
    }

    private func applyFailure(
        _ failure: DeviceDiscoveryFailure,
        generation: UInt64
    ) {
        guard generation == self.generation else { return }
        refreshTask = nil
        phase = .failed
        self.failure = failure
        isShowingStaleDevices = !devices.isEmpty
    }

    private static func presentationFailure(
        _ error: DeviceDiscoveryError
    ) -> DeviceDiscoveryFailure {
        switch error {
        case .adbUnavailable: return .adbUnavailable
        case .timedOut: return .timedOut
        case .unavailable: return .unavailable
        }
    }
}
