@testable import DroidMatchCore
import Foundation
import Testing

@Test func adbDeviceDiscoveryRedactsSerialsAndKeepsVisibleIdentityStable() async throws {
    let snapshots = AdbDeviceSnapshotProbe([
        [
            adbDevice(serial: "private-ready-serial", state: "device", model: "Pixel_Example"),
            adbDevice(serial: "private-offline-serial", state: "offline", model: "Offline_Example"),
            adbDevice(serial: "private-ready-serial", state: "device", model: "duplicate"),
        ],
        [
            adbDevice(serial: "private-ready-serial", state: "device", model: "Pixel_Example"),
        ],
        [],
        [
            adbDevice(serial: "private-ready-serial", state: "device", model: "Pixel_Example"),
        ],
    ])
    let discovery = AdbDeviceDiscovery(loader: { try await snapshots.next() })

    let first = try await discovery.devices()
    #expect(first.count == 2)
    #expect(first.map(\.connectionState) == [.ready, .offline])
    #expect(first[0].modelName == "Pixel Example")
    #expect(!String(reflecting: first).contains("private-ready-serial"))
    #expect(!String(reflecting: first).contains("private-offline-serial"))

    let stableID = first[0].id
    let second = try await discovery.devices()
    #expect(second.count == 1)
    #expect(second[0].id == stableID)

    #expect(try await discovery.devices().isEmpty)
    let reappeared = try await discovery.devices()
    #expect(reappeared.count == 1)
    #expect(reappeared[0].id != stableID)
}

@Test func adbDeviceDiscoveryMapsAuthorizationStatesWithoutExposingRawState() async throws {
    let snapshots = AdbDeviceSnapshotProbe([[
        adbDevice(serial: "first", state: "unauthorized", model: nil),
        adbDevice(serial: "second", state: "recovery", model: nil),
    ]])
    let discovery = AdbDeviceDiscovery(loader: { try await snapshots.next() })

    let devices = try await discovery.devices()

    #expect(devices.map(\.connectionState) == [.unauthorized, .unavailable])
    #expect(devices.allSatisfy { $0.transport == .adb })
}

private actor AdbDeviceSnapshotProbe {
    private var snapshots: [[AdbDevice]]

    init(_ snapshots: [[AdbDevice]]) {
        self.snapshots = snapshots
    }

    func next() throws -> [AdbDevice] {
        guard !snapshots.isEmpty else {
            throw DeviceDiscoveryError.unavailable
        }
        return snapshots.removeFirst()
    }
}

private func adbDevice(
    serial: String,
    state: String,
    model: String?
) -> AdbDevice {
    AdbDevice(
        serial: serial,
        state: state,
        product: nil,
        model: model,
        device: nil
    )
}
