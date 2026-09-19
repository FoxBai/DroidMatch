import Foundation
import Testing
@testable import DroidMatchCore
@testable import DroidMatchPresentation

@Test @MainActor func apkExportKeepsScopeAndAdmissionUntilCancelledTaskReallyExits() async throws {
    let probe = ExportPresentationProbe()
    let model = ApkExportModel(client: probe)
    let view = UUID(); model.attach(viewID: view)
    var releases = 0
    #expect(model.export(entry: exportEntry(), to: URL(fileURLWithPath: "/synthetic")) { releases += 1 })
    try #require(await exportEventually { await probe.started })
    model.detach(viewID: view); model.attach(viewID: view)
    #expect(!model.canExport && model.isBusy && releases == 0)
    await probe.finish()
    try #require(await exportEventually { model.canExport && releases == 1 })
    #expect(model.completedFilename == nil && model.failure == nil && model.progress == nil)
    model.deactivate()
    #expect(!model.canExport)
}

@Test @MainActor func apkExportReportsPublicationEvenWhenCancellationArrivesLate() async throws {
    let probe = ExportPresentationProbe()
    let model = ApkExportModel(client: probe)
    model.attach(viewID: UUID())
    var releases = 0
    #expect(model.export(entry: exportEntry(), to: URL(fileURLWithPath: "/synthetic")) { releases += 1 })
    try #require(await exportEventually { await probe.started })
    model.cancel()
    await probe.finish()
    try #require(await exportEventually { !model.isBusy && releases == 1 })
    #expect(model.completedFilename == "fixture.apk" && !model.wasCancelled)
    model.deactivate()
}

private func exportEntry() -> ApplicationLibraryEntry {
    .init(packageIdentifier: "fixture.app", displayName: "Fixture", versionName: "1", versionCode: 1,
          updatedUnixMillis: 1, isSystemApplication: false)
}
private actor ExportPresentationProbe: ApkExportClient {
    private var continuation: CheckedContinuation<ApkExportResult, Never>?
    var started: Bool { continuation != nil }
    func exportApk(packageIdentifier: String, directoryURL: URL,
                   progress: @escaping @Sendable (ApkExportProgress) async -> Void) async throws -> ApkExportResult {
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: .init(filename: "fixture.apk", componentCount: 1, totalBytes: 4))
        continuation = nil
    }
}
@MainActor private func exportEventually(_ condition: () async -> Bool) async -> Bool {
    let until = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < until {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
