import Combine
import DroidMatchCore
import Foundation

public struct TrustedDeviceItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let displayName: String?
    public let createdAt: Date
    public let lastUsedAt: Date

    public init(id: UUID, displayName: String, createdAt: Date, lastUsedAt: Date) {
        self.id = id
        self.displayName = ProductDisplayText.value(displayName)
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public protocol TrustedDeviceDataSource: Sendable {
    func list() async throws -> [TrustedDeviceItem]
    func revoke(id: UUID) async throws -> Bool
}

@MainActor
public final class TrustedDevicesModel: ObservableObject {
    @Published public private(set) var items: [TrustedDeviceItem] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var isMutating = false
    @Published public private(set) var isUnavailable = false
    @Published public private(set) var isRefreshOutstanding = false

    public var canRefresh: Bool {
        !runtimeInvalidated && !isRefreshOutstanding && !isMutating
    }

    private let dataSource: any TrustedDeviceDataSource
    private let loadTimeoutNanoseconds: UInt64
    private var generation: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var activeLoadGeneration: UInt64?
    private var loadDeadlineTask: Task<Void, Never>?
    private var runtimeInvalidated = false

    public init(
        dataSource: any TrustedDeviceDataSource,
        loadTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.dataSource = dataSource
        self.loadTimeoutNanoseconds = max(1, loadTimeoutNanoseconds)
    }

    @discardableResult
    public func refresh() -> Bool {
        // A Security.framework query can wait for user interaction. Keep only
        // one request alive so repeated view tasks cannot stack Keychain work.
        guard canRefresh, loadTask == nil else { return false }
        generation &+= 1
        let operationGeneration = generation
        activeLoadGeneration = operationGeneration
        isRefreshOutstanding = true
        isLoading = true
        let dataSource = dataSource
        loadTask = Task { @MainActor [weak self] in
            let loadedItems: [TrustedDeviceItem]?
            do {
                loadedItems = try await dataSource.list()
            } catch {
                loadedItems = nil
            }
            guard !Task.isCancelled else { return }
            self?.completeRefresh(loadedItems, generation: operationGeneration)
        }
        let timeout = loadTimeoutNanoseconds
        loadDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.markRefreshUnavailable(generation: operationGeneration)
        }
        return true
    }

    private func completeRefresh(
        _ loadedItems: [TrustedDeviceItem]?,
        generation operationGeneration: UInt64
    ) {
        guard activeLoadGeneration == operationGeneration else { return }
        loadTask = nil
        activeLoadGeneration = nil
        isRefreshOutstanding = false
        loadDeadlineTask?.cancel()
        loadDeadlineTask = nil
        isLoading = false
        guard generation == operationGeneration else { return }
        if let loadedItems {
            items = loadedItems
            isUnavailable = false
        } else {
            isUnavailable = true
        }
    }

    private func markRefreshUnavailable(generation operationGeneration: UInt64) {
        guard generation == operationGeneration, loadTask != nil, isLoading else { return }
        // The underlying Keychain request remains alive and may recover after
        // the user responds; its late result is still applied by completeRefresh.
        loadDeadlineTask = nil
        isLoading = false
        isUnavailable = true
    }

    @discardableResult
    public func revoke(id: UUID) async -> Bool {
        guard !runtimeInvalidated, !isMutating else { return false }
        invalidateRefreshForMutation()
        isMutating = true
        defer { isMutating = false }
        do {
            let revoked = try await dataSource.revoke(id: id)
            guard !runtimeInvalidated else { return false }
            guard revoked else {
                isUnavailable = true
                return false
            }
            items.removeAll { $0.id == id }
            isUnavailable = false
            return true
        } catch {
            guard !runtimeInvalidated else { return false }
            isUnavailable = true
            return false
        }
    }

    /// Permanently rejects display and mutation work after this running App was
    /// replaced. Security.framework itself may finish a request already inside
    /// the OS, but its task is cancelled and its generation can never publish.
    public func invalidateForRuntimeReplacement() {
        guard !runtimeInvalidated else { return }
        runtimeInvalidated = true
        generation &+= 1
        activeLoadGeneration = nil
        loadTask?.cancel()
        loadTask = nil
        loadDeadlineTask?.cancel()
        loadDeadlineTask = nil
        isLoading = false
        isRefreshOutstanding = false
    }

    private func invalidateRefreshForMutation() {
        // A list already inside Security.framework cannot be cancelled safely.
        // Invalidate only its publication so a late snapshot cannot undo a
        // completed mutation; the task still clears itself when it returns.
        generation &+= 1
        loadDeadlineTask?.cancel()
        loadDeadlineTask = nil
        isLoading = false
    }
}
