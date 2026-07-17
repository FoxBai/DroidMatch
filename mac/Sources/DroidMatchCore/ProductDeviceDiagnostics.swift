import Foundation

public enum ProductPermissionKind: String, Sendable, Equatable, CaseIterable {
    case mediaRead
    case notifications
    case safRoots
}

public enum ProductPermissionState: String, Sendable, Equatable {
    case granted
    case denied
    case needsUserAction
    case notApplicable
    case unknown
}

public struct ProductPermissionSummary: Identifiable, Sendable, Equatable {
    public var id: ProductPermissionKind { kind }
    public let kind: ProductPermissionKind
    public let state: ProductPermissionState

    public init(kind: ProductPermissionKind, state: ProductPermissionState) {
        self.kind = kind
        self.state = state
    }
}

public enum ProductServiceState: String, Sendable, Equatable {
    case connected
    case available
    case unavailable
    case degraded
    case unknown
}

public enum ProductDiagnosticCounterKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case framesReceived
    case framesSent
    case handshakesAccepted
    case authenticationsAccepted
    case authenticationsRejected
    case directoryRequests
    case diagnosticRequests
    case transferBytesSent
    case transferBytesReceived
    case uploadsCompleted
}

/// Privacy-bounded device and service health for the native product UI.
///
/// Android's device_id, raw event/error strings, thread names, arbitrary counter
/// keys, ports, and protobuf values are intentionally omitted. Unknown or
/// malformed optional metadata becomes nil/unknown instead of crossing the UI
/// boundary as an untrusted display string.
public struct ProductDeviceDiagnosticsSnapshot: Sendable, Equatable {
    public let manufacturer: String?
    public let model: String?
    public let androidVersion: String?
    public let sdkLevel: Int?
    public let totalStorageBytes: Int64?
    public let freeStorageBytes: Int64?
    public let batteryPercent: Int?
    public let permissions: [ProductPermissionSummary]
    public let serviceState: ProductServiceState
    public let recentErrorCount: Int
    public let counters: [ProductDiagnosticCounterKind: Int64]

    public init(
        manufacturer: String?,
        model: String?,
        androidVersion: String?,
        sdkLevel: Int?,
        totalStorageBytes: Int64?,
        freeStorageBytes: Int64?,
        batteryPercent: Int?,
        permissions: [ProductPermissionSummary],
        serviceState: ProductServiceState,
        recentErrorCount: Int,
        counters: [ProductDiagnosticCounterKind: Int64]
    ) {
        self.manufacturer = manufacturer
        self.model = model
        self.androidVersion = androidVersion
        self.sdkLevel = sdkLevel
        self.totalStorageBytes = totalStorageBytes
        self.freeStorageBytes = freeStorageBytes
        self.batteryPercent = batteryPercent
        self.permissions = permissions
        self.serviceState = serviceState
        self.recentErrorCount = recentErrorCount
        self.counters = counters
    }
}

public enum ProductDeviceDiagnosticsError: Error, Sendable, Equatable {
    case sessionUnavailable
    case unsupported
    case invalidResponse
    case unavailable
}

public protocol ProductDeviceDiagnosticsLoading: Sendable {
    func diagnosticsSnapshot() async throws -> ProductDeviceDiagnosticsSnapshot
}

public protocol ProductDiagnosticsClient: Sendable {
    func productDiagnosticsSnapshot() async throws -> ProductDeviceDiagnosticsSnapshot
}

enum ProductDeviceDiagnosticsNormalization {
    static func displayValue(_ rawValue: String?) -> String? {
        guard let value = ProductDisplayText.value(rawValue),
              value.caseInsensitiveCompare("unknown") != .orderedSame else {
            return nil
        }
        return value
    }

    static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    static func totalStorage(_ value: Int64?) -> Int64? {
        guard let value, value > 0 else { return nil }
        return value
    }

    static func freeStorage(_ value: Int64?, totalStorage: Int64?) -> Int64? {
        guard let value,
              let totalStorage,
              value >= 0,
              value <= totalStorage else {
            return nil
        }
        return value
    }

    static func batteryPercent(_ value: Int?) -> Int? {
        guard let value, (0...100).contains(value) else { return nil }
        return value
    }

    static func recentErrorCount(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }

    static func counterValue(_ value: Int64?) -> Int64? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}

extension AsyncRpcControlClient: ProductDiagnosticsClient {
    public func productDiagnosticsSnapshot() async throws -> ProductDeviceDiagnosticsSnapshot {
        async let deviceInfo = deviceInfo()
        async let diagnostics = diagnostics()
        let values = try await (deviceInfo, diagnostics)
        return try ProductDeviceDiagnosticsCodec.snapshot(
            deviceInfo: values.0,
            diagnostics: values.1
        )
    }
}

enum ProductDeviceDiagnosticsCodec {
    private static let counterKeys: [ProductDiagnosticCounterKind: String] = [
        .framesReceived: "rpc.frames.received",
        .framesSent: "rpc.frames.sent",
        .handshakesAccepted: "rpc.handshakes.accepted",
        .authenticationsAccepted: "rpc.authentication.accepted",
        .authenticationsRejected: "rpc.authentication.rejected",
        .directoryRequests: "rpc.list_dir.requests",
        .diagnosticRequests: "rpc.diagnostics.requests",
        .transferBytesSent: "rpc.transfer.bytes.sent",
        .transferBytesReceived: "rpc.transfer.bytes.received",
        .uploadsCompleted: "rpc.transfer.uploads.completed",
    ]

    static func snapshot(
        deviceInfo: Droidmatch_V1_DeviceInfoResponse,
        diagnostics: Droidmatch_V1_DiagnosticsResponse
    ) throws -> ProductDeviceDiagnosticsSnapshot {
        guard diagnostics.transport == .adb else {
            throw ProductDeviceDiagnosticsError.invalidResponse
        }

        let totalStorage = ProductDeviceDiagnosticsNormalization.totalStorage(
            deviceInfo.totalStorageBytes
        )
        let freeStorage = ProductDeviceDiagnosticsNormalization.freeStorage(
            deviceInfo.freeStorageBytes,
            totalStorage: totalStorage
        )
        let battery = ProductDeviceDiagnosticsNormalization.batteryPercent(
            Int(deviceInfo.batteryPercent)
        )
        let sdkLevel = ProductDeviceDiagnosticsNormalization.positive(
            Int(deviceInfo.sdkInt)
        )

        let permissions = ProductPermissionKind.allCases.map { kind in
            return ProductPermissionSummary(
                kind: kind,
                state: permissionState(
                    deviceInfo.permissions[permissionKey(for: kind)] ?? .unspecified
                )
            )
        }

        var counters: [ProductDiagnosticCounterKind: Int64] = [:]
        for kind in ProductDiagnosticCounterKind.allCases {
            guard let key = counterKeys[kind],
                  let value = diagnostics.counters[key],
                  let parsed = Int64(value),
                  let normalized = ProductDeviceDiagnosticsNormalization.counterValue(parsed) else {
                continue
            }
            counters[kind] = normalized
        }

        return ProductDeviceDiagnosticsSnapshot(
            manufacturer: ProductDeviceDiagnosticsNormalization.displayValue(
                deviceInfo.manufacturer
            ),
            model: ProductDeviceDiagnosticsNormalization.displayValue(deviceInfo.model),
            androidVersion: ProductDeviceDiagnosticsNormalization.displayValue(
                deviceInfo.androidVersion
            ),
            sdkLevel: sdkLevel,
            totalStorageBytes: totalStorage,
            freeStorageBytes: freeStorage,
            batteryPercent: battery,
            permissions: permissions,
            serviceState: serviceState(diagnostics.serviceState),
            recentErrorCount: ProductDeviceDiagnosticsNormalization.recentErrorCount(
                diagnostics.recentErrors.count
            ),
            counters: counters
        )
    }

    private static func permissionKey(for kind: ProductPermissionKind) -> String {
        switch kind {
        case .mediaRead:
            return "media_read"
        case .notifications:
            return "notifications"
        case .safRoots:
            return "saf_roots"
        }
    }

    private static func permissionState(
        _ state: Droidmatch_V1_PermissionState
    ) -> ProductPermissionState {
        switch state {
        case .granted: return .granted
        case .denied: return .denied
        case .needsUserAction: return .needsUserAction
        case .notApplicable: return .notApplicable
        case .unspecified, .UNRECOGNIZED: return .unknown
        }
    }

    private static func serviceState(_ rawValue: String) -> ProductServiceState {
        if rawValue.hasPrefix("rpc.session.open") { return .connected }
        if rawValue.hasPrefix("adb.endpoint.listening")
            || rawValue.hasPrefix("service.created") {
            return .available
        }
        if rawValue.contains("failed") || rawValue.contains("crashed") {
            return .degraded
        }
        if rawValue.hasPrefix("adb.endpoint.stopped")
            || rawValue.hasPrefix("service.destroyed") {
            return .unavailable
        }
        return .unknown
    }

}
