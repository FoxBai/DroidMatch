import Combine
import DroidMatchCore
import Foundation

public enum DeviceDiagnosticsPhase: String, Sendable, Equatable {
    case idle
    case loading
    case loaded
    case refreshing
    case failed
}

public enum DeviceDiagnosticsFailure: String, Sendable, Equatable {
    case sessionUnavailable
    case unsupported
    case invalidResponse
    case unavailable
}

/// Main-actor state for the authenticated diagnostics page.
///
/// The injected Core loader already strips device IDs, event/error text,
/// arbitrary counter keys, and platform exceptions. Refresh preserves the last
/// good snapshot as stale content so a transient transport failure does not
/// erase useful, clearly marked health information.
@MainActor
public final class DeviceDiagnosticsModel: ObservableObject {
    @Published public private(set) var snapshot: ProductDeviceDiagnosticsSnapshot?
    @Published public private(set) var phase: DeviceDiagnosticsPhase = .idle
    @Published public private(set) var failure: DeviceDiagnosticsFailure?

    public var isShowingStaleSnapshot: Bool {
        phase == .failed && snapshot != nil
    }

    private let loader: any ProductDeviceDiagnosticsLoading
    private var refreshTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(loader: any ProductDeviceDiagnosticsLoading) {
        self.loader = loader
    }

    deinit {
        refreshTask?.cancel()
    }

    public func refresh() {
        generation &+= 1
        let operationGeneration = generation
        refreshTask?.cancel()
        failure = nil
        phase = snapshot == nil ? .loading : .refreshing
        let loader = loader

        refreshTask = Task { [weak self] in
            do {
                let value = try await loader.diagnosticsSnapshot()
                guard !Task.isCancelled else { return }
                self?.apply(value, generation: operationGeneration)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.applyFailure(error, generation: operationGeneration)
            }
        }
    }

    private func apply(
        _ value: ProductDeviceDiagnosticsSnapshot,
        generation: UInt64
    ) {
        guard generation == self.generation else { return }
        refreshTask = nil
        snapshot = value
        failure = nil
        phase = .loaded
    }

    private func applyFailure(_ error: Error, generation: UInt64) {
        guard generation == self.generation else { return }
        refreshTask = nil
        failure = Self.presentationFailure(error)
        phase = .failed
    }

    private static func presentationFailure(_ error: Error) -> DeviceDiagnosticsFailure {
        guard let error = error as? ProductDeviceDiagnosticsError else {
            return .unavailable
        }
        switch error {
        case .sessionUnavailable: return .sessionUnavailable
        case .unsupported: return .unsupported
        case .invalidResponse: return .invalidResponse
        case .unavailable: return .unavailable
        }
    }
}
