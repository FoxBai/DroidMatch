@testable import DroidMatchCore
import Foundation
import Testing

@Test func productDiagnosticsCodecMapsOnlyAllowlistedPrivacyBoundedFields() throws {
    var device = Droidmatch_V1_DeviceInfoResponse()
    device.deviceID = "must-not-cross-product-boundary"
    device.manufacturer = "Example"
    device.model = "Phone"
    device.androidVersion = "14"
    device.sdkInt = 34
    device.totalStorageBytes = 1_000
    device.freeStorageBytes = 400
    device.batteryPercent = 73
    device.permissions = [
        "media_read": .granted,
        "notifications": .denied,
        "saf_roots": .needsUserAction,
        "future_private_permission": .granted,
    ]

    var diagnostics = Droidmatch_V1_DiagnosticsResponse()
    diagnostics.transport = .adb
    diagnostics.serviceState = "rpc.session.open"
    diagnostics.recentErrors = ["private:error:detail"]
    diagnostics.recentEvents = ["private:event:detail"]
    diagnostics.counters = [
        "rpc.frames.received": "12",
        "rpc.transfer.bytes.sent": "2048",
        "private.counter": "999",
    ]

    let snapshot = try ProductDeviceDiagnosticsCodec.snapshot(
        deviceInfo: device,
        diagnostics: diagnostics
    )

    #expect(snapshot.manufacturer == "Example")
    #expect(snapshot.model == "Phone")
    #expect(snapshot.androidVersion == "14")
    #expect(snapshot.sdkLevel == 34)
    #expect(snapshot.totalStorageBytes == 1_000)
    #expect(snapshot.freeStorageBytes == 400)
    #expect(snapshot.batteryPercent == 73)
    #expect(snapshot.serviceState == .connected)
    #expect(snapshot.recentErrorCount == 1)
    #expect(snapshot.permissions == [
        ProductPermissionSummary(kind: .mediaRead, state: .granted),
        ProductPermissionSummary(kind: .notifications, state: .denied),
        ProductPermissionSummary(kind: .safRoots, state: .needsUserAction),
    ])
    #expect(snapshot.counters == [
        .framesReceived: 12,
        .transferBytesSent: 2_048,
    ])
    let reflected = String(reflecting: snapshot)
    #expect(!reflected.contains(device.deviceID))
    #expect(!reflected.contains(diagnostics.recentErrors[0]))
    #expect(!reflected.contains(diagnostics.recentEvents[0]))
    #expect(!reflected.contains("private.counter"))
}

@Test func productDiagnosticsCodecNormalizesMalformedOptionalValues() throws {
    let emoji = "\u{1F600}"
    #expect(
        ProductDisplayText.value(String(repeating: emoji, count: 121))
            == String(repeating: emoji, count: 119) + "…"
    )

    var device = Droidmatch_V1_DeviceInfoResponse()
    device.manufacturer = "unknown"
    device.model = "  Bad\u{0007}\u{202E}Model\n\u{200B}Name\u{2069}  "
    device.androidVersion = ""
    device.sdkInt = -1
    device.totalStorageBytes = 100
    device.freeStorageBytes = 101
    device.batteryPercent = 101

    var diagnostics = Droidmatch_V1_DiagnosticsResponse()
    diagnostics.transport = .adb
    diagnostics.serviceState = "unrecognized:raw:value"
    diagnostics.counters = [
        "rpc.frames.sent": "-1",
        "rpc.frames.received": "not-a-number",
    ]

    let snapshot = try ProductDeviceDiagnosticsCodec.snapshot(
        deviceInfo: device,
        diagnostics: diagnostics
    )

    #expect(snapshot.manufacturer == nil)
    #expect(snapshot.model == "BadModel Name")
    #expect(snapshot.androidVersion == nil)
    #expect(snapshot.sdkLevel == nil)
    #expect(snapshot.totalStorageBytes == 100)
    #expect(snapshot.freeStorageBytes == nil)
    #expect(snapshot.batteryPercent == nil)
    #expect(snapshot.serviceState == .unknown)
    #expect(snapshot.counters.isEmpty)
}

@Test func productDiagnosticsCodecRejectsUnexpectedTransport() throws {
    var diagnostics = Droidmatch_V1_DiagnosticsResponse()
    diagnostics.transport = .aoa

    #expect(throws: ProductDeviceDiagnosticsError.invalidResponse) {
        try ProductDeviceDiagnosticsCodec.snapshot(
            deviceInfo: Droidmatch_V1_DeviceInfoResponse(),
            diagnostics: diagnostics
        )
    }
}
