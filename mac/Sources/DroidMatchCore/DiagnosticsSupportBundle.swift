import Foundation

public enum DiagnosticsSnapshotFreshness: String, Sendable, Equatable {
    case fresh
    case stale
    case unknown
}

public struct DiagnosticsSupportBundleContext: Sendable, Equatable {
    public let appVersion: String?
    public let buildVersion: String?
    public let macOSVersion: String?
    public let snapshotFreshness: DiagnosticsSnapshotFreshness

    public init(
        appVersion: String?,
        buildVersion: String?,
        macOSVersion: String?,
        snapshotFreshness: DiagnosticsSnapshotFreshness
    ) {
        self.appVersion = appVersion
        self.buildVersion = buildVersion
        self.macOSVersion = macOSVersion
        self.snapshotFreshness = snapshotFreshness
    }

    public static let unspecified = DiagnosticsSupportBundleContext(
        appVersion: nil,
        buildVersion: nil,
        macOSVersion: nil,
        snapshotFreshness: .unknown
    )
}

/// Encodes an allowlisted, machine-readable support report.
///
/// The report intentionally has no fields for ADB serials, pairing IDs,
/// fingerprints, ports, file names/paths, credentials, raw errors, or logs.
/// Adding a field here is therefore a privacy-boundary change, not a generic
/// Codable convenience.
public enum DiagnosticsSupportBundleEncoder {
    public static func encode(
        _ snapshot: ProductDeviceDiagnosticsSnapshot,
        context: DiagnosticsSupportBundleContext = .unspecified,
        generatedAt: Date = Date()
    ) throws -> Data {
        var permissions: [String: String] = [:]
        for permission in snapshot.permissions {
            permissions[permission.kind.rawValue] = permission.state.rawValue
        }
        let report = Report(
            schemaVersion: 1,
            generatedAt: generatedAt,
            environment: Environment(
                appVersion: boundedVersion(context.appVersion),
                buildVersion: boundedVersion(context.buildVersion),
                macOSVersion: boundedVersion(context.macOSVersion),
                snapshotFreshness: context.snapshotFreshness.rawValue
            ),
            device: Device(
                manufacturer: snapshot.manufacturer,
                model: snapshot.model,
                androidVersion: snapshot.androidVersion,
                sdkLevel: snapshot.sdkLevel
            ),
            health: Health(
                totalStorageBytes: snapshot.totalStorageBytes,
                freeStorageBytes: snapshot.freeStorageBytes,
                batteryPercent: snapshot.batteryPercent,
                serviceState: snapshot.serviceState.rawValue,
                recentErrorCount: snapshot.recentErrorCount
            ),
            permissions: permissions,
            counters: Dictionary(uniqueKeysWithValues: snapshot.counters.map {
                ($0.key.rawValue, $0.value)
            })
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    private static func boundedVersion(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = value.unicodeScalars.filter {
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122)
                || " .()_-".unicodeScalars.contains($0)
        }
        let normalized = String(String.UnicodeScalarView(allowed))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : String(normalized.prefix(120))
    }

    private struct Report: Encodable {
        let schemaVersion: Int
        let generatedAt: Date
        let environment: Environment
        let device: Device
        let health: Health
        let permissions: [String: String]
        let counters: [String: Int64]
    }

    private struct Environment: Encodable {
        let appVersion: String?
        let buildVersion: String?
        let macOSVersion: String?
        let snapshotFreshness: String
    }

    private struct Device: Encodable {
        let manufacturer: String?
        let model: String?
        let androidVersion: String?
        let sdkLevel: Int?
    }

    private struct Health: Encodable {
        let totalStorageBytes: Int64?
        let freeStorageBytes: Int64?
        let batteryPercent: Int?
        let serviceState: String
        let recentErrorCount: Int
    }
}
