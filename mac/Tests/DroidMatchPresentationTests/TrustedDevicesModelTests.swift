import DroidMatchPresentation
import Foundation
import Testing

@Test
@MainActor
func trustedDevicesModelLoadsAndRevokesWithoutExposingStoreIdentity() async throws {
    let first = TrustedDeviceItem(
        id: UUID(),
        displayName: "Test Android",
        createdAt: Date(timeIntervalSince1970: 10),
        lastUsedAt: Date(timeIntervalSince1970: 20)
    )
    let source = TrustedDeviceDataSourceProbe(items: [first])
    let model = TrustedDevicesModel(dataSource: source)

    model.refresh()
    #expect(await waitForTrustedDevices { !model.isLoading && model.items == [first] })
    #expect(await model.revoke(id: first.id))
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
    model.refresh()
    #expect(await waitForTrustedDevices { model.items == [first] })

    await source.setFailure(true)
    model.refresh()
    #expect(await waitForTrustedDevices { !model.isLoading && model.isUnavailable })
    #expect(model.items == [first])
}

private actor TrustedDeviceDataSourceProbe: TrustedDeviceDataSource {
    private var items: [TrustedDeviceItem]
    private var revoked: [UUID] = []
    private var shouldFail = false

    init(items: [TrustedDeviceItem]) { self.items = items }

    func list() throws -> [TrustedDeviceItem] {
        if shouldFail { throw TrustedDeviceProbeError.unavailable }
        return items
    }

    func revoke(id: UUID) throws -> Bool {
        if shouldFail { throw TrustedDeviceProbeError.unavailable }
        guard items.contains(where: { $0.id == id }) else { return false }
        items.removeAll { $0.id == id }
        revoked.append(id)
        return true
    }

    func setFailure(_ value: Bool) { shouldFail = value }
    func revokedIDs() -> [UUID] { revoked }
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
