@testable import DroidMatchCore
import Foundation
import Testing

@Test func adbClientBuildsDeterministicEmbeddedProductPath() {
    let bundle = URL(fileURLWithPath: "/Applications/DroidMatch.app", isDirectory: true)
    #expect(AdbClient.bundledAdbPath(bundleURL: bundle)
            == "/Applications/DroidMatch.app/Contents/Resources/platform-tools/adb")
}

@Test func adbDeviceDiscoveryRejectsInvalidTimeoutWithoutLaunchingAdb() async {
    let invalidTimeouts: [TimeInterval] = [0, -1, .nan, .infinity, -.infinity]
    for timeout in invalidTimeouts {
        let discovery = AdbDeviceDiscovery(
            adbPath: "/definitely/not/a/real/adb",
            timeoutSeconds: timeout
        )
        await #expect(throws: DeviceDiscoveryError.timedOut) {
            _ = try await discovery.devices()
        }
    }
}

@Test func adbDeviceDiscoveryRedactsSerialsAndKeepsVisibleIdentityStable() async throws {
    let snapshots = AdbDeviceSnapshotProbe([
        [
            adbDevice(
                serial: "private-ready-serial",
                state: "device",
                model: " \u{202E}Pixel_\n\u{200B}Example\u{2069} "
            ),
            adbDevice(serial: "private-offline-serial", state: "offline", model: "Offline_Example"),
            adbDevice(serial: "private-ready-serial", state: "device", model: "duplicate"),
        ],
        [
            adbDevice(
                serial: "private-ready-serial",
                state: "device",
                model: " \u{202E}Pixel_\n\u{200B}Example\u{2069} "
            ),
        ],
        [],
        [
            adbDevice(
                serial: "private-ready-serial",
                state: "device",
                model: " \u{202E}Pixel_\n\u{200B}Example\u{2069} "
            ),
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

@Test func adbDeviceDiscoveryPublishesMarketingNameWithoutSharingSerial() async throws {
    let privateSerial = "must-never-reach-name-resolver"
    let received = MarketingNameQueryProbe()
    let snapshots = AdbDeviceSnapshotProbe([[
        AdbDevice(
            serial: privateSerial,
            state: "device",
            product: "S3",
            model: "704SH",
            device: "SG704SH"
        ),
    ]])
    let discovery = AdbDeviceDiscovery(
        loader: { try await snapshots.next() },
        marketingNameResolver: { model, device, product in
            await received.record(model: model, device: device, product: product)
            return "シンプルスマホ4"
        }
    )

    let device = try #require(await discovery.devices().first)

    #expect(device.marketingName == "シンプルスマホ4")
    #expect(device.modelName == "704SH")
    #expect(await received.values() == ["704SH|SG704SH|S3"])
    #expect(!String(reflecting: device).contains(privateSerial))
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

@Test func adbDeviceDiscoveryMapsPreparationLoaderFailures() async {
    #expect(await mappedPreparationFailure(from: .timedOut) == .timedOut)
    #expect(await mappedPreparationFailure(from: .adbUnavailable) == .adbUnavailable)
    #expect(await mappedPreparationFailure(from: .unavailable) == .unavailable)
}

@Test func adbDeviceDiscoveryRejectsDeviceThatDisappearsBeforePreparation() async throws {
    let snapshots = AdbDeviceSnapshotProbe([
        [adbDevice(serial: "private", state: "device", model: nil)],
        [],
    ])
    let discovery = AdbDeviceDiscovery(loader: { try await snapshots.next() })
    let device = try #require(await discovery.devices().first)

    var rejectedAsUnavailable = false
    do {
        _ = try await discovery.prepareConnection(to: device.id)
    } catch DeviceConnectionPreparationError.deviceUnavailable {
        rejectedAsUnavailable = true
    }
    #expect(rejectedAsUnavailable)
}

@Test func adbDeviceDiscoveryRejectsConcurrentPreparationForSameDevice() async throws {
    let snapshots = AdbDeviceSnapshotProbe([
        [adbDevice(serial: "private", state: "device", model: nil)],
        [adbDevice(serial: "private", state: "device", model: nil)],
    ])
    let forwards = AdbForwardHold(port: 45_555)
    let discovery = AdbDeviceDiscovery(
        loader: { try await snapshots.next() },
        forwarder: { serial in await forwards.create(serial: serial) },
        forwardRemover: { serial, port in await forwards.remove(serial: serial, port: port) }
    )
    let device = try #require(await discovery.devices().first)
    let firstPreparation = Task {
        try await discovery.prepareConnection(to: device.id)
    }
    await forwards.waitUntilEntered()

    var rejectedAsInProgress = false
    do {
        _ = try await discovery.prepareConnection(to: device.id)
    } catch DeviceConnectionPreparationError.preparationInProgress {
        rejectedAsInProgress = true
    }
    #expect(rejectedAsInProgress)

    await forwards.release()
    let lease = try await firstPreparation.value
    await discovery.releaseConnection(lease)
    #expect(await forwards.createdSerials() == ["private"])
    #expect(await forwards.removedValues() == ["private:45555"])
}

@Test func adbDeviceDiscoveryRemovesForwardWhenPreparationIsCancelled() async throws {
    let snapshots = AdbDeviceSnapshotProbe([
        [adbDevice(serial: "private", state: "device", model: nil)],
        [adbDevice(serial: "private", state: "device", model: nil)],
    ])
    let forwards = AdbForwardHold(port: 45_555)
    let discovery = AdbDeviceDiscovery(
        loader: { try await snapshots.next() },
        forwarder: { serial in await forwards.create(serial: serial) },
        forwardRemover: { serial, port in await forwards.remove(serial: serial, port: port) }
    )
    let device = try #require(await discovery.devices().first)
    let preparation = Task {
        try await discovery.prepareConnection(to: device.id)
    }
    await forwards.waitUntilEntered()

    preparation.cancel()
    await forwards.release()

    var rejectedAsCancellation = false
    do {
        _ = try await preparation.value
    } catch is CancellationError {
        rejectedAsCancellation = true
    }
    #expect(rejectedAsCancellation)
    #expect(await forwards.removedValues() == ["private:45555"])
}

@Test func adbDeviceDiscoveryMismatchedReleaseRetainsCleanupOwnership() async throws {
    let snapshots = AdbDeviceSnapshotProbe([
        [adbDevice(serial: "private", state: "device", model: nil)],
        [adbDevice(serial: "private", state: "device", model: nil)],
    ])
    let forwards = AdbForwardProbe(port: 45_555)
    let discovery = AdbDeviceDiscovery(
        loader: { try await snapshots.next() },
        forwarder: { serial in try await forwards.create(serial: serial) },
        forwardRemover: { serial, port in await forwards.remove(serial: serial, port: port) }
    )
    let device = try #require(await discovery.devices().first)
    let lease = try await discovery.prepareConnection(to: device.id)
    let mismatchedLease = DeviceConnectionLease(
        id: lease.id,
        deviceID: lease.deviceID,
        host: lease.host,
        port: lease.port + 1
    )

    await discovery.releaseConnection(mismatchedLease)
    #expect(await forwards.removedValues().isEmpty)
    await discovery.releaseConnection(lease)
    #expect(await forwards.removedValues() == ["private:45555"])
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

private actor MarketingNameQueryProbe {
    private var queries: [String] = []

    func record(model: String?, device: String?, product: String?) {
        queries.append("\(model ?? "")|\(device ?? "")|\(product ?? "")")
    }

    func values() -> [String] { queries }
}

private actor AdbForwardHold {
    private let port: Int
    private var created: [String] = []
    private var removed: [String] = []
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(port: Int) {
        self.port = port
    }

    func create(serial: String) async -> Int {
        created.append(serial)
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return port
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func remove(serial: String, port: Int) {
        removed.append("\(serial):\(port)")
    }

    func createdSerials() -> [String] { created }
    func removedValues() -> [String] { removed }
}

private func mappedPreparationFailure(
    from source: DeviceDiscoveryError
) async -> DeviceConnectionPreparationError? {
    let discovery = AdbDeviceDiscovery(loader: { throw source })
    do {
        _ = try await discovery.prepareConnection(to: UUID())
        return nil
    } catch let error as DeviceConnectionPreparationError {
        return error
    } catch {
        return nil
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
