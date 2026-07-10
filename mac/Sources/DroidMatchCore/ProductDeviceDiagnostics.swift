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
    private static let permissionKeys: [ProductPermissionKind: String] = [
        .mediaRead: "media_read",
        .notifications: "notifications",
        .safRoots: "saf_roots",
    ]

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

        let totalStorage = deviceInfo.totalStorageBytes > 0
            ? deviceInfo.totalStorageBytes
            : nil
        let freeStorage: Int64?
        if let totalStorage,
           deviceInfo.freeStorageBytes >= 0,
           deviceInfo.freeStorageBytes <= totalStorage {
            freeStorage = deviceInfo.freeStorageBytes
        } else {
            freeStorage = nil
        }
        let battery = (0...100).contains(deviceInfo.batteryPercent)
            ? Int(deviceInfo.batteryPercent)
            : nil
        let sdkLevel = deviceInfo.sdkInt > 0 ? Int(deviceInfo.sdkInt) : nil

        let permissions = ProductPermissionKind.allCases.map { kind in
            let key = permissionKeys[kind]!
            return ProductPermissionSummary(
                kind: kind,
                state: permissionState(deviceInfo.permissions[key] ?? .unspecified)
            )
        }

        var counters: [ProductDiagnosticCounterKind: Int64] = [:]
        for kind in ProductDiagnosticCounterKind.allCases {
            guard let key = counterKeys[kind],
                  let value = diagnostics.counters[key],
                  let parsed = Int64(value),
                  parsed >= 0 else {
                continue
            }
            counters[kind] = parsed
        }

        return ProductDeviceDiagnosticsSnapshot(
            manufacturer: displayValue(deviceInfo.manufacturer),
            model: displayValue(deviceInfo.model),
            androidVersion: displayValue(deviceInfo.androidVersion),
            sdkLevel: sdkLevel,
            totalStorageBytes: totalStorage,
            freeStorageBytes: freeStorage,
            batteryPercent: battery,
            permissions: permissions,
            serviceState: serviceState(diagnostics.serviceState),
            recentErrorCount: min(diagnostics.recentErrors.count, 100),
            counters: counters
        )
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

    private static func displayValue(_ rawValue: String) -> String? {
        let allowedScalars = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(.punctuationCharacters)
            .union(.symbols)
        let value = rawValue
            .precomposedStringWithCanonicalMapping
            .unicodeScalars
            .filter { allowedScalars.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.caseInsensitiveCompare("unknown") != ComparisonResult.orderedSame else {
            return nil
        }
        return String(value.prefix(120))
    }
}
