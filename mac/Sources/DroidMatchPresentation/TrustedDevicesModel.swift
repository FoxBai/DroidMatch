import Combine
import Foundation

public struct TrustedDeviceItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let displayName: String
    public let createdAt: Date
    public let lastUsedAt: Date

    public init(id: UUID, displayName: String, createdAt: Date, lastUsedAt: Date) {
        self.id = id
        self.displayName = displayName
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

    private let dataSource: any TrustedDeviceDataSource
    private let loadTimeoutNanoseconds: UInt64
    private var generation: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var loadDeadlineTask: Task<Void, Never>?

    public init(
        dataSource: any TrustedDeviceDataSource,
        loadTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.dataSource = dataSource
        self.loadTimeoutNanoseconds = max(1, loadTimeoutNanoseconds)
    }

    public func refresh() {
        // A Security.framework query can wait for user interaction. Keep only
        // one request alive so repeated view tasks cannot stack Keychain work.
        guard loadTask == nil else { return }
        generation &+= 1
        let operationGeneration = generation
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
    }

    private func completeRefresh(
        _ loadedItems: [TrustedDeviceItem]?,
        generation operationGeneration: UInt64
    ) {
        guard generation == operationGeneration else { return }
        loadTask = nil
        loadDeadlineTask?.cancel()
        loadDeadlineTask = nil
        isLoading = false
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
        guard !isMutating else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            guard try await dataSource.revoke(id: id) else { return false }
            items.removeAll { $0.id == id }
            isUnavailable = false
            return true
        } catch {
            isUnavailable = true
            return false
        }
    }
}
