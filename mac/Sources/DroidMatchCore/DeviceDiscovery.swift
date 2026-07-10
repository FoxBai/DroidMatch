import Dispatch
import Foundation

public enum DeviceTransportKind: String, Sendable, Equatable {
    case adb
}

public enum DeviceConnectionState: String, Sendable, Equatable {
    case ready
    case unauthorized
    case offline
    case unavailable
}

/// Product-facing device identity deliberately excludes the ADB serial.
///
/// The UUID is stable only while a device remains visible to one discovery
/// actor. A future session factory can resolve it inside Core; presentation,
/// logs, and persistence must never use the underlying hardware identifier.
public struct DiscoveredDevice: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let modelName: String?
    public let productName: String?
    public let connectionState: DeviceConnectionState
    public let transport: DeviceTransportKind

    public init(
        id: UUID,
        modelName: String?,
        productName: String?,
        connectionState: DeviceConnectionState,
        transport: DeviceTransportKind
    ) {
        self.id = id
        self.modelName = modelName
        self.productName = productName
        self.connectionState = connectionState
        self.transport = transport
    }
}

public enum DeviceDiscoveryError: Error, Sendable, Equatable {
    case adbUnavailable
    case timedOut
    case unavailable
}

public protocol DeviceDiscovering: Sendable {
    func devices() async throws -> [DiscoveredDevice]
}

/// Async product boundary around the blocking `adb devices -l` process call.
///
/// Process execution is isolated to a private queue and capped at five seconds
/// by default. Raw serials exist only in this actor's private lookup and are
/// replaced by process-local UUIDs before values cross into presentation state.
public actor AdbDeviceDiscovery: DeviceDiscovering {
    public static let defaultTimeoutSeconds: TimeInterval = 5

    typealias Loader = @Sendable () async throws -> [AdbDevice]

    private let loader: Loader
    private var identifiersBySerial: [String: UUID] = [:]

    public init(
        adbPath: String? = nil,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds
    ) {
        precondition(timeoutSeconds > 0, "device discovery timeout must be positive")
        let resolvedPath = adbPath ?? AdbClient.defaultAdbPath()
        let queue = DispatchQueue(label: "app.droidmatch.device-discovery")
        loader = {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let client = AdbClient(
                            adbPath: resolvedPath,
                            processRunner: ProcessRunner(timeoutSeconds: timeoutSeconds)
                        )
                        continuation.resume(returning: try client.devices())
                    } catch is ProcessRunnerError {
                        continuation.resume(throwing: DeviceDiscoveryError.timedOut)
                    } catch is AdbClientError {
                        continuation.resume(throwing: DeviceDiscoveryError.adbUnavailable)
                    } catch {
                        continuation.resume(throwing: DeviceDiscoveryError.unavailable)
                    }
                }
            }
        }
    }

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    public func devices() async throws -> [DiscoveredDevice] {
        let adbDevices = try await loader()
        let visibleSerials = Set(adbDevices.map(\.serial))
        identifiersBySerial = identifiersBySerial.filter {
            visibleSerials.contains($0.key)
        }

        var seenSerials = Set<String>()
        let discovered = adbDevices.compactMap { device -> DiscoveredDevice? in
            guard seenSerials.insert(device.serial).inserted else { return nil }
            let identifier = identifiersBySerial[device.serial] ?? UUID()
            identifiersBySerial[device.serial] = identifier
            return DiscoveredDevice(
                id: identifier,
                modelName: Self.displayValue(device.model),
                productName: Self.displayValue(device.product),
                connectionState: Self.connectionState(device.state),
                transport: .adb
            )
        }

        return discovered.sorted { lhs, rhs in
            let lhsRank = Self.sortRank(lhs.connectionState)
            let rhsRank = Self.sortRank(rhs.connectionState)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsName = lhs.modelName ?? lhs.productName ?? ""
            let rhsName = rhs.modelName ?? rhs.productName ?? ""
            let nameOrder = lhsName.localizedCaseInsensitiveCompare(rhsName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func displayValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func connectionState(_ adbState: String) -> DeviceConnectionState {
        switch adbState {
        case "device": return .ready
        case "unauthorized": return .unauthorized
        case "offline": return .offline
        default: return .unavailable
        }
    }

    private static func sortRank(_ state: DeviceConnectionState) -> Int {
        switch state {
        case .ready: return 0
        case .unauthorized: return 1
        case .offline: return 2
        case .unavailable: return 3
        }
    }
}
