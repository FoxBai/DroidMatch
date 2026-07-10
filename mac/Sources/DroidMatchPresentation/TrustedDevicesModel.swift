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
    private var generation: UInt64 = 0

    public init(dataSource: any TrustedDeviceDataSource) {
        self.dataSource = dataSource
    }

    public func refresh() {
        generation &+= 1
        let operationGeneration = generation
        isLoading = true
        let dataSource = dataSource
        Task { [weak self] in
            do {
                let items = try await dataSource.list()
                guard self?.generation == operationGeneration else { return }
                self?.items = items
                self?.isUnavailable = false
                self?.isLoading = false
            } catch {
                guard self?.generation == operationGeneration else { return }
                self?.isUnavailable = true
                self?.isLoading = false
            }
        }
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
