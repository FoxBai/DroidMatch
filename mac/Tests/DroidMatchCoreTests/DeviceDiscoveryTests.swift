@testable import DroidMatchCore
import Foundation
import Testing

@Test func adbClientBuildsDeterministicEmbeddedProductPath() {
    let bundle = URL(fileURLWithPath: "/Applications/DroidMatch.app", isDirectory: true)
    #expect(AdbClient.bundledAdbPath(bundleURL: bundle)
            == "/Applications/DroidMatch.app/Contents/Resources/platform-tools/adb")
}

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

@Test func adbDeviceDiscoveryOwnsRedactedForwardLeaseAndReleasesItOnce() async throws {
    let privateSerial = "never-cross-product-boundary"
    let snapshots = AdbDeviceSnapshotProbe([
        [adbDevice(serial: privateSerial, state: "device", model: "Pixel")],
        [adbDevice(serial: privateSerial, state: "device", model: "Pixel")],
    ])
    let forwards = AdbForwardProbe(port: 45_555)
    let discovery = AdbDeviceDiscovery(
        loader: { try await snapshots.next() },
        forwarder: { serial in try await forwards.create(serial: serial) },
        forwardRemover: { serial, port in await forwards.remove(serial: serial, port: port) }
    )

    let device = try #require(await discovery.devices().first)
    let lease = try await discovery.prepareConnection(to: device.id)

    #expect(lease.deviceID == device.id)
    #expect(lease.host == "127.0.0.1")
    #expect(lease.port == 45_555)
    #expect(!String(reflecting: lease).contains(privateSerial))
    #expect(await forwards.createdSerials() == [privateSerial])

    await discovery.releaseConnection(lease)
    await discovery.releaseConnection(lease)
    #expect(await forwards.removedValues() == ["\(privateSerial):45555"])
}

@Test func adbDeviceDiscoveryRejectsStaleOrUnreadyDeviceBeforeForwarding() async throws {
    let snapshots = AdbDeviceSnapshotProbe([
        [adbDevice(serial: "private", state: "device", model: nil)],
        [adbDevice(serial: "private", state: "offline", model: nil)],
    ])
    let forwards = AdbForwardProbe(port: 45_555)
    let discovery = AdbDeviceDiscovery(
        loader: { try await snapshots.next() },
        forwarder: { serial in try await forwards.create(serial: serial) }
    )
    let device = try #require(await discovery.devices().first)

    do {
        _ = try await discovery.prepareConnection(to: device.id)
        Issue.record("expected an unready device to be rejected")
    } catch DeviceConnectionPreparationError.deviceNotReady {
        // Expected: only an authorized ADB state may own a product forward.
    }
    #expect(await forwards.createdSerials().isEmpty)
}

@Test func adbDeviceDiscoveryRemovesInvalidAllocatedForwardBeforeFailing() async throws {
    let snapshots = AdbDeviceSnapshotProbe([
        [adbDevice(serial: "private", state: "device", model: nil)],
        [adbDevice(serial: "private", state: "device", model: nil)],
    ])
    let forwards = AdbForwardProbe(port: 0)
    let discovery = AdbDeviceDiscovery(
        loader: { try await snapshots.next() },
        forwarder: { serial in try await forwards.create(serial: serial) },
        forwardRemover: { serial, port in await forwards.remove(serial: serial, port: port) }
    )
    let device = try #require(await discovery.devices().first)

    do {
        _ = try await discovery.prepareConnection(to: device.id)
        Issue.record("expected an invalid allocated port to be rejected")
    } catch DeviceConnectionPreparationError.unavailable {
        // Expected: even malformed ADB output must not leave a forward behind.
    }
    #expect(await forwards.removedValues() == ["private:0"])
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

private actor AdbForwardProbe {
    private let port: Int
    private var created: [String] = []
    private var removed: [String] = []

    init(port: Int) {
        self.port = port
    }

    func create(serial: String) throws -> Int {
        created.append(serial)
        return port
    }

    func remove(serial: String, port: Int) {
        removed.append("\(serial):\(port)")
    }

    func createdSerials() -> [String] { created }
    func removedValues() -> [String] { removed }
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
