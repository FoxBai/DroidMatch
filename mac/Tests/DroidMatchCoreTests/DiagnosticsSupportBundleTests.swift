import Foundation
import Testing
@testable import DroidMatchCore

@Test
func diagnosticsSupportBundleContainsOnlyAllowlistedStructuredState() throws {
    let snapshot = ProductDeviceDiagnosticsSnapshot(
        manufacturer: "Acme",
        model: "Phone",
        androidVersion: "14",
        sdkLevel: 34,
        totalStorageBytes: 1_000,
        freeStorageBytes: 400,
        batteryPercent: 75,
        permissions: [
            ProductPermissionSummary(kind: .mediaRead, state: .granted),
            ProductPermissionSummary(kind: .safRoots, state: .needsUserAction),
            ProductPermissionSummary(kind: .mediaRead, state: .denied),
        ],
        serviceState: .connected,
        recentErrorCount: 2,
        counters: [.framesReceived: 10, .directoryRequests: 3]
    )
    let data = try DiagnosticsSupportBundleEncoder.encode(
        snapshot,
        context: DiagnosticsSupportBundleContext(
            appVersion: "0.1.0",
            buildVersion: "1",
            macOSVersion: "macOS 15.5 (Build 24F74) /Users/private",
            snapshotFreshness: .stale
        ),
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(Set(object.keys) == [
        "schemaVersion", "generatedAt", "environment", "device", "health", "permissions", "counters",
    ])
    #expect(object["schemaVersion"] as? Int == 1)
    let permissions = try #require(object["permissions"] as? [String: String])
    #expect(permissions["mediaRead"] == "denied")
    let environment = try #require(object["environment"] as? [String: Any])
    #expect(environment["appVersion"] as? String == "0.1.0")
    #expect(environment["snapshotFreshness"] as? String == "stale")
    let encoded = try #require(String(data: data, encoding: .utf8))
    for forbidden in ["serial", "pairing", "fingerprint", "port", "path", "credential", "rawError"] {
        #expect(!encoded.localizedCaseInsensitiveContains(forbidden))
    }
}

@Test
func diagnosticsSupportBundleRevalidatesConstructedSnapshotValues() throws {
    let snapshot = ProductDeviceDiagnosticsSnapshot(
        manufacturer: "  unknown  ",
        model: "Model\u{0007}\u{202E}\nName " + String(repeating: "Z", count: 140),
        androidVersion: "\u{0000}\u{2069}",
        sdkLevel: 0,
        totalStorageBytes: 100,
        freeStorageBytes: 101,
        batteryPercent: -1,
        permissions: [
            ProductPermissionSummary(kind: .notifications, state: .denied),
        ],
        serviceState: .degraded,
        recentErrorCount: -7,
        counters: [.framesReceived: 2, .framesSent: -1]
    )

    let data = try DiagnosticsSupportBundleEncoder.encode(snapshot)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let device = try #require(object["device"] as? [String: Any])
    let model = try #require(device["model"] as? String)
    let health = try #require(object["health"] as? [String: Any])
    let counters = try #require(object["counters"] as? [String: Int])

    #expect(device["manufacturer"] == nil)
    #expect(device["androidVersion"] == nil)
    #expect(device["sdkLevel"] == nil)
    #expect(model.hasPrefix("Model Name "))
    #expect(model.hasSuffix("…"))
    #expect(model.unicodeScalars.count == 120)
    #expect(health["totalStorageBytes"] as? Int == 100)
    #expect(health["freeStorageBytes"] == nil)
    #expect(health["batteryPercent"] == nil)
    #expect(health["recentErrorCount"] as? Int == 0)
    #expect(counters == ["framesReceived": 2])
}
