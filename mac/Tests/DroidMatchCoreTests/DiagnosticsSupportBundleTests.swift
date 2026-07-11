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
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(Set(object.keys) == [
        "schemaVersion", "generatedAt", "device", "health", "permissions", "counters",
    ])
    #expect(object["schemaVersion"] as? Int == 1)
    let permissions = try #require(object["permissions"] as? [String: String])
    #expect(permissions["mediaRead"] == "denied")
    let encoded = try #require(String(data: data, encoding: .utf8))
    for forbidden in ["serial", "pairing", "fingerprint", "port", "path", "credential", "rawError"] {
        #expect(!encoded.localizedCaseInsensitiveContains(forbidden))
    }
}
