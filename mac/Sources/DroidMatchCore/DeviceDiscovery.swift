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
    public let marketingName: String?
    public let modelName: String?
    public let productName: String?
    public let connectionState: DeviceConnectionState
    public let transport: DeviceTransportKind

    public init(
        id: UUID,
        marketingName: String? = nil,
        modelName: String?,
        productName: String?,
        connectionState: DeviceConnectionState,
        transport: DeviceTransportKind
    ) {
        self.id = id
        self.marketingName = marketingName
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

/// A product-owned ADB forwarding lease with no hardware identifier.
///
/// The random token identifies cleanup ownership only. Raw ADB serials stay in
/// `AdbDeviceDiscovery` and never cross into Presentation or SwiftUI state.
public struct DeviceConnectionLease: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let deviceID: UUID
    public let host: String
    public let port: Int
    public let displayName: String?

    init(
        id: UUID = UUID(),
        deviceID: UUID,
        host: String,
        port: Int,
        displayName: String? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.host = host
        self.port = port
        // One credential-safe projection keeps the authenticated session,
        // newly stored trust record, and trusted-device row text identical.
        self.displayName = PairingCredentialDisplayText.value(displayName)
    }
}

public enum DeviceConnectionPreparationError: Error, Sendable, Equatable {
    case deviceUnavailable
    case deviceNotReady
    case preparationInProgress
    case adbUnavailable
    case timedOut
    case unavailable
}

public protocol DeviceConnectionPreparing: Sendable {
    func prepareConnection(to deviceID: UUID) async throws -> DeviceConnectionLease
    func releaseConnection(_ lease: DeviceConnectionLease) async
}

/// Async product boundary around the blocking `adb devices -l` process call.
///
/// Process execution is isolated to a private queue and capped at five seconds
/// by default. Raw serials exist only in this actor's private lookup and are
/// replaced by process-local UUIDs before values cross into presentation state.
public actor AdbDeviceDiscovery: DeviceDiscovering, DeviceConnectionPreparing {
    public static let defaultTimeoutSeconds: TimeInterval = 5
    public static let productEndpointPort = 39_001

    typealias Loader = @Sendable () async throws -> [AdbDevice]
    typealias Forwarder = @Sendable (_ serial: String) async throws -> Int
    typealias ForwardRemover = @Sendable (_ serial: String, _ localPort: Int) async -> Void
    typealias MarketingNameResolver = @Sendable (
        _ model: String?, _ device: String?, _ product: String?
    ) async -> String?

    private struct PrivateLease {
        let deviceID: UUID
        let serial: String
        let localPort: Int
    }

    private let loader: Loader
    private let forwarder: Forwarder
    private let forwardRemover: ForwardRemover
    private let marketingNameResolver: MarketingNameResolver
    private var identifiersBySerial: [String: UUID] = [:]
    private var leasesByID: [UUID: PrivateLease] = [:]
    private var preparingDeviceIDs = Set<UUID>()

    public init(
        adbPath: String? = nil,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds
    ) {
        let resolvedPath = adbPath ?? AdbClient.defaultAdbPath()
        let queue = DispatchQueue(label: "app.droidmatch.device-discovery")
        let nameResolver = DeviceMarketingNameResolver()
        let makeClient: @Sendable () -> AdbClient = {
            AdbClient(
                adbPath: resolvedPath,
                processRunner: ProcessRunner(timeoutSeconds: timeoutSeconds)
            )
        }
        loader = {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        continuation.resume(returning: try makeClient().devices())
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
        forwarder = { serial in
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let port = try makeClient().forward(
                            serial: serial,
                            localPort: 0,
                            remotePort: Self.productEndpointPort
                        )
                        continuation.resume(returning: port)
                    } catch is ProcessRunnerError {
                        continuation.resume(throwing: DeviceConnectionPreparationError.timedOut)
                    } catch is AdbClientError {
                        continuation.resume(throwing: DeviceConnectionPreparationError.adbUnavailable)
                    } catch {
                        continuation.resume(throwing: DeviceConnectionPreparationError.unavailable)
                    }
                }
            }
        }
        forwardRemover = { serial, localPort in
            await withCheckedContinuation { continuation in
                queue.async {
                    // Cleanup is intentionally best effort and idempotent. The
                    // actor forgets ownership before this command is attempted.
                    try? makeClient().removeForward(serial: serial, localPort: localPort)
                    continuation.resume()
                }
            }
        }
        marketingNameResolver = { model, device, product in
            await nameResolver.marketingName(model: model, device: device, product: product)
        }
    }

    init(
        loader: @escaping Loader,
        marketingNameResolver: @escaping MarketingNameResolver = { _, _, _ in nil },
        forwarder: @escaping Forwarder = { _ in
            throw DeviceConnectionPreparationError.unavailable
        },
        forwardRemover: @escaping ForwardRemover = { _, _ in }
    ) {
        self.loader = loader
        self.marketingNameResolver = marketingNameResolver
        self.forwarder = forwarder
        self.forwardRemover = forwardRemover
    }

    public func devices() async throws -> [DiscoveredDevice] {
        let adbDevices = try await loader()
        var marketingNamesBySerial: [String: String] = [:]
        for device in adbDevices {
            marketingNamesBySerial[device.serial] = await marketingNameResolver(
                device.model,
                device.device,
                device.product
            )
        }
        return reconcile(adbDevices, marketingNamesBySerial: marketingNamesBySerial)
    }

    public func prepareConnection(to deviceID: UUID) async throws -> DeviceConnectionLease {
        guard preparingDeviceIDs.insert(deviceID).inserted else {
            throw DeviceConnectionPreparationError.preparationInProgress
        }
        defer { preparingDeviceIDs.remove(deviceID) }

        let adbDevices: [AdbDevice]
        do {
            adbDevices = try await loader()
        } catch DeviceDiscoveryError.timedOut {
            throw DeviceConnectionPreparationError.timedOut
        } catch DeviceDiscoveryError.adbUnavailable {
            throw DeviceConnectionPreparationError.adbUnavailable
        } catch {
            throw DeviceConnectionPreparationError.unavailable
        }

        _ = reconcile(adbDevices, marketingNamesBySerial: [:])
        guard let serial = identifiersBySerial.first(where: { $0.value == deviceID })?.key,
              let device = adbDevices.first(where: { $0.serial == serial }) else {
            throw DeviceConnectionPreparationError.deviceUnavailable
        }
        guard device.state == "device" else {
            throw DeviceConnectionPreparationError.deviceNotReady
        }

        let marketingName = await marketingNameResolver(
            device.model,
            device.device,
            device.product
        )
        let displayName = Self.displayValue(marketingName)
            ?? Self.displayValue(device.model)
            ?? Self.displayValue(device.product)

        let localPort = try await forwarder(serial)
        guard (1...65_535).contains(localPort) else {
            await forwardRemover(serial, localPort)
            throw DeviceConnectionPreparationError.unavailable
        }
        do {
            try Task.checkCancellation()
        } catch {
            await forwardRemover(serial, localPort)
            throw error
        }
        let lease = DeviceConnectionLease(
            deviceID: deviceID,
            host: "127.0.0.1",
            port: localPort,
            displayName: displayName
        )
        leasesByID[lease.id] = PrivateLease(
            deviceID: deviceID,
            serial: serial,
            localPort: localPort
        )
        return lease
    }

    public func releaseConnection(_ lease: DeviceConnectionLease) async {
        guard let privateLease = leasesByID[lease.id],
              privateLease.deviceID == lease.deviceID,
              privateLease.localPort == lease.port else {
            return
        }
        // Validate the public capability before consuming private cleanup
        // ownership. A mismatched release must not make the real lease leak.
        // 中文：先校验公开 lease，再消费私有清理所有权。
        leasesByID.removeValue(forKey: lease.id)
        await forwardRemover(privateLease.serial, privateLease.localPort)
    }

    private func reconcile(
        _ adbDevices: [AdbDevice],
        marketingNamesBySerial: [String: String]
    ) -> [DiscoveredDevice] {
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
                marketingName: Self.displayValue(marketingNamesBySerial[device.serial]),
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
        return ProductDisplayText.value(value.replacingOccurrences(of: "_", with: " "))
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
