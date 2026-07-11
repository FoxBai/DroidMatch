import Foundation

/// Encodes an allowlisted, machine-readable support report.
///
/// The report intentionally has no fields for ADB serials, pairing IDs,
/// fingerprints, ports, file names/paths, credentials, raw errors, or logs.
/// Adding a field here is therefore a privacy-boundary change, not a generic
/// Codable convenience.
public enum DiagnosticsSupportBundleEncoder {
    public static func encode(
        _ snapshot: ProductDeviceDiagnosticsSnapshot,
        generatedAt: Date = Date()
    ) throws -> Data {
        var permissions: [String: String] = [:]
        for permission in snapshot.permissions {
            permissions[permission.kind.rawValue] = permission.state.rawValue
        }
        let report = Report(
            schemaVersion: 1,
            generatedAt: generatedAt,
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

    private struct Report: Encodable {
        let schemaVersion: Int
        let generatedAt: Date
        let device: Device
        let health: Health
        let permissions: [String: String]
        let counters: [String: Int64]
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
