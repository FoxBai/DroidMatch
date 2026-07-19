import DroidMatchCore
import DroidMatchPresentation
import Foundation
import Testing

@Test
@MainActor
func deviceDiagnosticsModelLoadsAndRetainsStaleSnapshotOnFailure() async throws {
    let loader = DeviceDiagnosticsLoaderProbe()
    let model = DeviceDiagnosticsModel(loader: loader)
    let snapshot = diagnosticsPresentationSnapshot(model: "Phone")

    model.refresh()
    #expect(model.phase == .loading)
    #expect(await waitForDiagnosticsCallCount(loader, 1))
    await loader.succeed(1, with: snapshot)
    #expect(await waitForDiagnosticsPhase(model, .loaded))
    #expect(model.snapshot == snapshot)

    model.refresh()
    #expect(model.phase == .refreshing)
    #expect(await waitForDiagnosticsCallCount(loader, 2))
    await loader.fail(2, with: .unavailable)
    #expect(await waitForDiagnosticsPhase(model, .failed))
    #expect(model.failure == .unavailable)
    #expect(model.snapshot == snapshot)
    #expect(model.isShowingStaleSnapshot)
}

@Test
@MainActor
func deviceDiagnosticsModelRejectsLateNonCooperativeRefresh() async throws {
    let loader = DeviceDiagnosticsLoaderProbe()
    let model = DeviceDiagnosticsModel(loader: loader)
    model.refresh()
    #expect(await waitForDiagnosticsCallCount(loader, 1))
    model.refresh()
    #expect(await waitForDiagnosticsCallCount(loader, 2))

    let current = diagnosticsPresentationSnapshot(model: "Current")
    await loader.succeed(2, with: current)
    #expect(await waitForDiagnosticsPhase(model, .loaded))
    await loader.succeed(1, with: diagnosticsPresentationSnapshot(model: "Stale"))
    try await Task.sleep(nanoseconds: 20_000_000)

    #expect(model.snapshot == current)
}

@Test
func diagnosticsIdentityPrefersSessionRetailNameAndKeepsTechnicalContext() {
    let identity = DeviceDiagnosticsIdentityPresentation(
        sessionDisplayName: "シンプルスマホ4",
        snapshot: diagnosticsPresentationSnapshot(
            manufacturer: "SHARP",
            model: "704SH"
        )
    )

    #expect(identity.primaryName == "シンプルスマホ4")
    #expect(identity.technicalDetail == "SHARP · 704SH")
}

@Test
func diagnosticsIdentityFallsBackWithoutRepeatingPrimaryName() {
    let modelIdentity = DeviceDiagnosticsIdentityPresentation(
        sessionDisplayName: nil,
        snapshot: diagnosticsPresentationSnapshot(
            manufacturer: "SHARP",
            model: "704SH"
        )
    )
    let manufacturerIdentity = DeviceDiagnosticsIdentityPresentation(
        sessionDisplayName: nil,
        snapshot: diagnosticsPresentationSnapshot(
            manufacturer: "SHARP",
            model: nil
        )
    )

    #expect(modelIdentity.primaryName == "704SH")
    #expect(modelIdentity.technicalDetail == "SHARP")
    #expect(manufacturerIdentity.primaryName == "SHARP")
    #expect(manufacturerIdentity.technicalDetail == nil)
}

@Test
func diagnosticsIdentityReprojectsAndDeduplicatesExternalLabels() {
    let identity = DeviceDiagnosticsIdentityPresentation(
        sessionDisplayName: "  Simple\u{202E}\nPhone  ",
        snapshot: diagnosticsPresentationSnapshot(
            manufacturer: "SHARP",
            model: "simple phone"
        )
    )

    #expect(identity.primaryName == "Simple Phone")
    #expect(identity.technicalDetail == "SHARP")
}

private actor DeviceDiagnosticsLoaderProbe: ProductDeviceDiagnosticsLoading {
    private var calls = 0
    private var continuations:
        [Int: CheckedContinuation<ProductDeviceDiagnosticsSnapshot, any Error>] = [:]

    func diagnosticsSnapshot() async throws -> ProductDeviceDiagnosticsSnapshot {
        calls += 1
        let number = calls
        return try await withCheckedThrowingContinuation { continuation in
            continuations[number] = continuation
        }
    }

    func count() -> Int { calls }

    func succeed(_ number: Int, with snapshot: ProductDeviceDiagnosticsSnapshot) {
        continuations.removeValue(forKey: number)?.resume(returning: snapshot)
    }

    func fail(_ number: Int, with error: ProductDeviceDiagnosticsError) {
        continuations.removeValue(forKey: number)?.resume(throwing: error)
    }
}

private func diagnosticsPresentationSnapshot(
    manufacturer: String = "Example",
    model: String?
) -> ProductDeviceDiagnosticsSnapshot {
    ProductDeviceDiagnosticsSnapshot(
        manufacturer: manufacturer,
        model: model,
        androidVersion: "14",
        sdkLevel: 34,
        totalStorageBytes: 1_000,
        freeStorageBytes: 400,
        batteryPercent: 70,
        permissions: [
            ProductPermissionSummary(kind: .mediaRead, state: .granted),
        ],
        serviceState: .connected,
        recentErrorCount: 0,
        counters: [.framesReceived: 1]
    )
}

@MainActor
private func waitForDiagnosticsPhase(
    _ model: DeviceDiagnosticsModel,
    _ expected: DeviceDiagnosticsPhase
) async -> Bool {
    for _ in 0..<200 {
        if model.phase == expected { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

private func waitForDiagnosticsCallCount(
    _ loader: DeviceDiagnosticsLoaderProbe,
    _ expected: Int
) async -> Bool {
    for _ in 0..<200 {
        if await loader.count() == expected { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}
