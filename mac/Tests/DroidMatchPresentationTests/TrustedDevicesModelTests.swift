import DroidMatchPresentation
import Foundation
import Testing

@Test
@MainActor
func trustedDevicesModelLoadsAndRevokesWithoutExposingStoreIdentity() async throws {
    let first = TrustedDeviceItem(
        id: UUID(),
        displayName: " \u{202E}Test\n\u{200B}Android\u{2069} ",
        createdAt: Date(timeIntervalSince1970: 10),
        lastUsedAt: Date(timeIntervalSince1970: 20)
    )
    let source = TrustedDeviceDataSourceProbe(items: [first])
    let model = TrustedDevicesModel(dataSource: source)

    #expect(first.displayName == "Test Android")
    #expect(model.refresh())
    #expect(await waitForTrustedDevices { !model.isLoading && model.items == [first] })
    #expect(await model.revoke(id: first.id, disconnect: {}))
    #expect(model.items.isEmpty)
    #expect(await source.revokedIDs() == [first.id])
}

@Test
@MainActor
func trustedDevicesModelFailsClosedAndKeepsExistingSnapshot() async throws {
    let first = TrustedDeviceItem(
        id: UUID(),
        displayName: "Test Android",
        createdAt: .distantPast,
        lastUsedAt: .now
    )
    let source = TrustedDeviceDataSourceProbe(items: [first])
    let model = TrustedDevicesModel(dataSource: source)
    #expect(model.refresh())
    #expect(await waitForTrustedDevices { model.items == [first] })

    await source.setFailure(true)
    #expect(model.refresh())
    #expect(await waitForTrustedDevices { !model.isLoading && model.isUnavailable })
    #expect(model.canRefresh)
    #expect(!model.isRefreshOutstanding)
    #expect(model.items == [first])
    #expect(!(await model.revoke(id: first.id, disconnect: {})))
    #expect(model.items == [first])
    #expect(model.isUnavailable)
}

@Test
@MainActor
func trustedDevicesModelReservesRevokeBeforeDisconnectAndBlocksRefresh() async throws {
    let first = TrustedDeviceItem(
        id: UUID(),
        displayName: "Reserved Android",
        createdAt: .distantPast,
        lastUsedAt: .now
    )
    let source = TrustedDeviceDataSourceProbe(items: [first])
    let model = TrustedDevicesModel(dataSource: source)
    #expect(model.refresh())
    #expect(await waitForTrustedDevices { model.items == [first] })

    #expect(!(await model.revoke(id: first.id, disconnect: {
        throw TrustedDeviceProbeError.unavailable
    })))
    #expect(!model.isMutating)
    #expect(model.canRevoke)
    #expect(await source.revokeCallCount() == 0)

    let cancelledDisconnect = TrustedDeviceDisconnectProbe()
    let cancelledRevoke = Task { @MainActor in
        await model.revoke(id: first.id, disconnect: {
            await cancelledDisconnect.waitUntilReleased()
        })
    }
    #expect(await waitForTrustedDevices { model.isMutating })
    #expect(await waitForDisconnectCall(cancelledDisconnect))
    cancelledRevoke.cancel()
    await cancelledDisconnect.release()
    #expect(!(await cancelledRevoke.value))
    #expect(!model.isMutating)
    #expect(model.canRevoke)
    #expect(await source.revokeCallCount() == 0)

    let heldDisconnect = TrustedDeviceDisconnectProbe()
    let revoke = Task { @MainActor in
        await model.revoke(id: first.id, disconnect: {
            await heldDisconnect.waitUntilReleased()
        })
    }
    #expect(await waitForTrustedDevices { model.isMutating })
    #expect(await waitForDisconnectCall(heldDisconnect))
    #expect(!model.canRefresh)
    #expect(!model.canRevoke)

    let listCalls = await source.listCallCount()
    #expect(!model.refresh())
    #expect(await source.listCallCount() == listCalls)
    let rejectedDisconnect = TrustedDeviceDisconnectProbe()
    #expect(!(await model.revoke(id: first.id, disconnect: {
        await rejectedDisconnect.record()
    })))
    #expect(await rejectedDisconnect.callCount() == 0)
    #expect(await source.revokeCallCount() == 0)

    await heldDisconnect.release()
    #expect(await revoke.value)
    #expect(!model.isMutating)
    #expect(model.items.isEmpty)
    #expect(await source.revokeCallCount() == 1)
    #expect(await source.revokedIDs() == [first.id])
}

@Test
@MainActor
func trustedDevicesModelBoundsHungLoadAndGuardsRevokeUntilLateRecovery() async throws {
    let recovered = TrustedDeviceItem(
        id: UUID(),
        displayName: "Recovered Android",
        createdAt: .distantPast,
        lastUsedAt: .now
    )
    let source = SuspendedTrustedDeviceDataSourceProbe()
    let model = TrustedDevicesModel(
        dataSource: source,
        loadTimeoutNanoseconds: 20_000_000
    )

    #expect(model.refresh())
    #expect(await waitForTrustedDevices { !model.isLoading && model.isUnavailable })
    #expect(model.isRefreshOutstanding)
    #expect(!model.canRefresh)

    #expect(!model.refresh())
    try await Task.sleep(nanoseconds: 25_000_000)
    #expect(await source.listCallCount() == 1)

    await source.resume(with: [recovered])
    #expect(await waitForTrustedDevices {
        !model.isLoading && !model.isUnavailable && model.items == [recovered]
    })
    #expect(!model.isRefreshOutstanding)
    #expect(model.canRefresh)

    #expect(model.refresh())
    #expect(await waitForTrustedDevices { !model.isLoading && model.isUnavailable })
    #expect(await source.listCallCount() == 2)

    #expect(!model.canRevoke)
    let rejectedDisconnect = TrustedDeviceDisconnectProbe()
    #expect(!(await model.revoke(id: recovered.id, disconnect: {
        await rejectedDisconnect.record()
    })))
    #expect(!model.isMutating)
    #expect(model.items == [recovered])
    #expect(model.isRefreshOutstanding)
    #expect(await rejectedDisconnect.callCount() == 0)
    #expect(await source.revokeCallCount() == 0)
    #expect((await source.revokedIDs()).isEmpty)

    await source.resume(with: [recovered])
    #expect(await waitForTrustedDevices {
        !model.isLoading && !model.isUnavailable && model.items == [recovered]
    })
    #expect(model.canRevoke)
    #expect(await model.revoke(id: recovered.id, disconnect: {}))
    #expect(model.items.isEmpty)
    #expect(!model.isUnavailable)
    #expect(!model.isRefreshOutstanding)
    #expect(model.canRefresh)
    #expect(await source.revokeCallCount() == 1)
    #expect(await source.revokedIDs() == [recovered.id])
}

@Test
@MainActor
func trustedDevicesRuntimeInvalidationRejectsLateAndFutureKeychainWork() async throws {
    let late = TrustedDeviceItem(
        id: UUID(),
        displayName: "Late Android",
        createdAt: .distantPast,
        lastUsedAt: .now
    )
    let source = SuspendedTrustedDeviceDataSourceProbe()
    let model = TrustedDevicesModel(dataSource: source)

    #expect(model.refresh())
    for _ in 0..<100 {
        if await source.listCallCount() == 1 { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(await source.listCallCount() == 1)
    model.invalidateForRuntimeReplacement()
    #expect(!model.canRefresh)
    #expect(!model.refresh())
    #expect(!(await model.revoke(id: late.id, disconnect: {})))

    await source.resume(with: [late])
    try await Task.sleep(nanoseconds: 10_000_000)
    #expect(model.items.isEmpty)
    #expect(!model.isLoading)
    #expect(!model.isRefreshOutstanding)
    #expect(await source.listCallCount() == 1)
    #expect((await source.revokedIDs()).isEmpty)
}

private actor TrustedDeviceDataSourceProbe: TrustedDeviceDataSource {
    private var items: [TrustedDeviceItem]
    private var revoked: [UUID] = []
    private var shouldFail = false
    private var listCalls = 0
    private var revokeCalls = 0

    init(items: [TrustedDeviceItem]) { self.items = items }

    func list() throws -> [TrustedDeviceItem] {
        listCalls += 1
        if shouldFail { throw TrustedDeviceProbeError.unavailable }
        return items
    }

    func revoke(id: UUID) throws -> Bool {
        revokeCalls += 1
        if shouldFail { throw TrustedDeviceProbeError.unavailable }
        guard items.contains(where: { $0.id == id }) else { return false }
        items.removeAll { $0.id == id }
        revoked.append(id)
        return true
    }

    func setFailure(_ value: Bool) { shouldFail = value }
    func listCallCount() -> Int { listCalls }
    func revokeCallCount() -> Int { revokeCalls }
    func revokedIDs() -> [UUID] { revoked }
}

private actor TrustedDeviceDisconnectProbe {
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func record() { calls += 1 }
    func callCount() -> Int { calls }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SuspendedTrustedDeviceDataSourceProbe: TrustedDeviceDataSource {
    private var continuation: CheckedContinuation<[TrustedDeviceItem], any Error>?
    private var listCalls = 0
    private var storedItems: [TrustedDeviceItem] = []
    private var revoked: [UUID] = []
    private var revokeCalls = 0

    func list() async throws -> [TrustedDeviceItem] {
        listCalls += 1
        let items = try await withCheckedThrowingContinuation { continuation = $0 }
        return items
    }

    func revoke(id: UUID) async throws -> Bool {
        revokeCalls += 1
        guard storedItems.contains(where: { $0.id == id }) else { return false }
        storedItems.removeAll { $0.id == id }
        revoked.append(id)
        return true
    }

    func listCallCount() -> Int { listCalls }
    func revokeCallCount() -> Int { revokeCalls }
    func revokedIDs() -> [UUID] { revoked }

    func resume(with items: [TrustedDeviceItem]) {
        storedItems = items
        continuation?.resume(returning: items)
        continuation = nil
    }

}

private enum TrustedDeviceProbeError: Error { case unavailable }

@MainActor
private func waitForTrustedDevices(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

private func waitForDisconnectCall(_ probe: TrustedDeviceDisconnectProbe) async -> Bool {
    for _ in 0..<200 {
        if await probe.callCount() == 1 { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}
