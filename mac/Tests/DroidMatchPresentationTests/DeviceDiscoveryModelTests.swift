import DroidMatchCore
import DroidMatchPresentation
import Foundation
import Testing

@Test
@MainActor
func deviceDiscoveryModelDefaultRefreshCadencePreservesInsertionBudget() {
    #expect(
        DeviceDiscoveryModel.defaultAutomaticRefreshIntervalNanoseconds ==
            1_000_000_000
    )
}

@Test
@MainActor
func deviceDiscoveryModelReplacesSnapshotAndCountsReadyDevices() async throws {
    let discovery = DeviceDiscoveryProbe()
    let model = DeviceDiscoveryModel(discovery: discovery)
    let ready = discoveredDevice(
        state: .ready,
        model: " \u{202E}Ready\n\u{200B}phone\u{2069} ",
        marketingName: " Retail\u{202E}\nPhone "
    )
    let offline = discoveredDevice(state: .offline, model: "Offline phone")

    model.refresh()
    #expect(model.phase == .loading)
    #expect(await waitForDiscoveryCallCount(discovery, 1))
    await discovery.succeed(1, with: [ready, offline])

    #expect(await waitForDiscoveryPhase(model, .loaded))
    #expect(model.devices.map(\.id) == [ready.id, offline.id])
    #expect(model.devices.first?.modelName == "Ready phone")
    #expect(model.devices.first?.marketingName == "Retail Phone")
    #expect(model.devices.first?.displayName == "Retail Phone")
    #expect(model.devices.first?.technicalNames == ["Ready phone"])
    #expect(model.readyDeviceCount == 1)
    #expect(!model.isShowingStaleDevices)
}

@Test
@MainActor
func deviceDiscoveryModelSortsStateBandsByEveryDisplayedTitleFallback() async throws {
    let discovery = DeviceDiscoveryProbe()
    let unnamedTitle = "Bravo Device"
    let model = DeviceDiscoveryModel(
        discovery: discovery,
        unnamedDeviceLabel: unnamedTitle
    )
    let readyZulu = discoveredDevice(
        state: .ready,
        model: "A-technical",
        marketingName: "Zulu Phone"
    )
    let readyAlpha = discoveredDevice(
        state: .ready,
        model: "Z-technical",
        marketingName: "Alpha Phone"
    )
    let readyUnnamed = discoveredDevice(state: .ready, model: nil)
    let offline = discoveredDevice(state: .offline, model: "A Offline")

    model.refresh()
    #expect(await waitForDiscoveryCallCount(discovery, 1))
    await discovery.succeed(1, with: [offline, readyZulu, readyUnnamed, readyAlpha])
    #expect(await waitForDiscoveryPhase(model, .loaded))

    #expect(model.devices.map(\.id) == [
        readyAlpha.id, readyUnnamed.id, readyZulu.id, offline.id,
    ])
    #expect(model.devices.map { $0.displayName ?? unnamedTitle } == [
        "Alpha Phone", unnamedTitle, "Zulu Phone", "A Offline",
    ])
}

@Test
@MainActor
func deviceDiscoveryModelMarksRetainedSnapshotStaleAfterSafeFailure() async throws {
    let discovery = DeviceDiscoveryProbe()
    let model = DeviceDiscoveryModel(discovery: discovery)
    let ready = discoveredDevice(state: .ready, model: "Ready phone")

    model.refresh()
    #expect(await waitForDiscoveryCallCount(discovery, 1))
    await discovery.succeed(1, with: [ready])
    #expect(await waitForDiscoveryPhase(model, .loaded))

    model.refresh()
    #expect(model.phase == .refreshing)
    #expect(await waitForDiscoveryCallCount(discovery, 2))
    await discovery.fail(2, with: .timedOut)

    #expect(await waitForDiscoveryPhase(model, .failed))
    #expect(model.failure == .timedOut)
    #expect(model.devices.map(\.id) == [ready.id])
    #expect(model.isShowingStaleDevices)
}

@Test
@MainActor
func deviceDiscoveryModelRejectsLateNonCooperativeRefresh() async throws {
    let discovery = DeviceDiscoveryProbe()
    let model = DeviceDiscoveryModel(discovery: discovery)
    let stale = discoveredDevice(state: .offline, model: "Stale")
    let current = discoveredDevice(state: .ready, model: "Current")

    model.refresh()
    #expect(await waitForDiscoveryCallCount(discovery, 1))
    model.refresh()
    #expect(await waitForDiscoveryCallCount(discovery, 2))
    await discovery.succeed(2, with: [current])
    #expect(await waitForDiscoveryPhase(model, .loaded))

    await discovery.succeed(1, with: [stale])
    try await Task.sleep(nanoseconds: 20_000_000)

    #expect(model.devices.map(\.id) == [current.id])
    #expect(model.readyDeviceCount == 1)
}

@Test
@MainActor
func deviceDiscoveryModelAutomaticRefreshStartsImmediatelyAndDoesNotReenter() async throws {
    let discovery = DeviceDiscoveryProbe()
    let model = DeviceDiscoveryModel(discovery: discovery)

    model.startAutomaticRefresh(intervalNanoseconds: 1_000_000)
    model.startAutomaticRefresh(intervalNanoseconds: 1_000_000)
    #expect(await waitForDiscoveryCallCount(discovery, 1))

    // Several ticks may pass, but the unresolved ADB query remains the sole
    // owner until it settles.
    try await Task.sleep(nanoseconds: 10_000_000)
    #expect(await discovery.count() == 1)

    await discovery.succeed(1, with: [])
    // At a one-millisecond test interval, `.loaded` may immediately advance
    // to `.refreshing`. A second dependency call is durable proof that result
    // one settled before automatic polling advanced.
    #expect(await waitForAutomaticDiscoveryCallCount(discovery, 2))
    model.stopAutomaticRefresh()
    await discovery.succeed(2, with: [])
}

@Test
@MainActor
func deviceDiscoveryModelAutomaticRefreshStopsWithoutCancellingActiveQuery() async throws {
    let discovery = DeviceDiscoveryProbe()
    let model = DeviceDiscoveryModel(discovery: discovery)

    model.startAutomaticRefresh(intervalNanoseconds: 1_000_000)
    #expect(await waitForDiscoveryCallCount(discovery, 1))
    model.stopAutomaticRefresh()
    await discovery.succeed(1, with: [])
    #expect(await waitForDiscoveryPhase(model, .loaded))

    try await Task.sleep(nanoseconds: 10_000_000)
    #expect(await discovery.count() == 1)
}

@Test
@MainActor
func deviceDiscoveryRuntimeInvalidationRejectsLateAndFutureWork() async throws {
    let discovery = DeviceDiscoveryProbe()
    let model = DeviceDiscoveryModel(discovery: discovery)

    model.refresh()
    #expect(await waitForDiscoveryCallCount(discovery, 1))
    model.invalidateForRuntimeReplacement()
    model.refresh()
    model.startAutomaticRefresh(intervalNanoseconds: 1_000_000)
    await discovery.succeed(1, with: [discoveredDevice(state: .ready, model: "Late")])
    try await Task.sleep(nanoseconds: 10_000_000)

    #expect(await discovery.count() == 1)
    #expect(model.phase == .idle)
    #expect(model.devices.isEmpty)
    #expect(model.failure == nil)
}

private actor DeviceDiscoveryProbe: DeviceDiscovering {
    private var callCount = 0
    private var continuations:
        [Int: CheckedContinuation<[DiscoveredDevice], any Error>] = [:]

    func devices() async throws -> [DiscoveredDevice] {
        callCount += 1
        let number = callCount
        return try await withCheckedThrowingContinuation { continuation in
            continuations[number] = continuation
        }
    }

    func count() -> Int {
        callCount
    }

    func succeed(_ number: Int, with devices: [DiscoveredDevice]) {
        continuations.removeValue(forKey: number)?.resume(returning: devices)
    }

    func fail(_ number: Int, with error: DeviceDiscoveryError) {
        continuations.removeValue(forKey: number)?.resume(throwing: error)
    }
}

private func discoveredDevice(
    state: DeviceConnectionState,
    model: String?,
    marketingName: String? = nil
) -> DiscoveredDevice {
    DiscoveredDevice(
        id: UUID(),
        marketingName: marketingName,
        modelName: model,
        productName: nil,
        connectionState: state,
        transport: .adb
    )
}

@MainActor
private func waitForDiscoveryCallCount(
    _ discovery: DeviceDiscoveryProbe,
    _ expected: Int
) async -> Bool {
    for _ in 0..<100 {
        if await discovery.count() == expected { return true }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForDiscoveryPhase(
    _ model: DeviceDiscoveryModel,
    _ expected: DeviceDiscoveryPhase
) async -> Bool {
    for _ in 0..<100 {
        if model.phase == expected { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

private func waitForAutomaticDiscoveryCallCount(
    _ discovery: DeviceDiscoveryProbe,
    _ expected: Int
) async -> Bool {
    for _ in 0..<100 {
        if await discovery.count() == expected { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}
