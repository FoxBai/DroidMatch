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
        modelName = ProductDisplayText.value(device.modelName)
        productName = ProductDisplayText.value(device.productName)
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
    /// The foreground product refresh cadence. One second leaves more of the
    /// five-second USB-insertion budget for ADB and UI latency while the
    /// non-overlap guard below prevents active queries from multiplying.
    public static let defaultAutomaticRefreshIntervalNanoseconds: UInt64 =
        1_000_000_000

    @Published public private(set) var devices: [DeviceDiscoveryItem] = []
    @Published public private(set) var phase: DeviceDiscoveryPhase = .idle
    @Published public private(set) var failure: DeviceDiscoveryFailure?
    @Published public private(set) var isShowingStaleDevices = false

    public var readyDeviceCount: Int {
        devices.lazy.filter { $0.connectionState == .ready }.count
    }

    private let discovery: any DeviceDiscovering
    private var refreshTask: Task<Void, Never>?
    private var automaticRefreshTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var runtimeInvalidated = false

    public init(discovery: any DeviceDiscovering) {
        self.discovery = discovery
    }

    deinit {
        automaticRefreshTask?.cancel()
        refreshTask?.cancel()
    }

    /// Keeps the visible device snapshot fresh without overlapping ADB queries.
    ///
    /// A slow query is allowed to finish; periodic ticks never cancel and
    /// restart it. The interval is intentionally shorter than the five-second
    /// M1 target, but ADB and UI latency still require physical evidence.
    public func startAutomaticRefresh(
        intervalNanoseconds: UInt64 = defaultAutomaticRefreshIntervalNanoseconds
    ) {
        guard !runtimeInvalidated,
              automaticRefreshTask == nil,
              intervalNanoseconds > 0 else { return }
        if phase == .idle {
            refresh()
        }
        automaticRefreshTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                    guard let self else { return }
                    guard self.phase != .loading, self.phase != .refreshing else {
                        continue
                    }
                    self.refresh()
                }
            } catch is CancellationError {
                // Normal view-lifecycle teardown.
            } catch {
                // Task.sleep currently throws only cancellation. Keep teardown
                // quiet if its implementation gains another terminal error.
            }
        }
    }

    /// Stops future polling while allowing an already-started query to settle.
    public func stopAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
    }

    public func refresh() {
        guard !runtimeInvalidated else { return }
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

    /// Permanently closes every discovery entry point for a process whose App
    /// executable was replaced. An in-flight dependency may still unwind, but
    /// cancellation plus generation invalidation prevents stale publication.
    public func invalidateForRuntimeReplacement() {
        guard !runtimeInvalidated else { return }
        runtimeInvalidated = true
        generation &+= 1
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        devices = []
        phase = .idle
        failure = nil
        isShowingStaleDevices = false
    }

    private func apply(_ values: [DiscoveredDevice], generation: UInt64) {
        guard !runtimeInvalidated, generation == self.generation else { return }
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
        guard !runtimeInvalidated, generation == self.generation else { return }
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
