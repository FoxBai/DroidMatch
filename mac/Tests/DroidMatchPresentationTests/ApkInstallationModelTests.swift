import Foundation
import Testing
@testable import DroidMatchCore
@testable import DroidMatchPresentation

@Test @MainActor func apkInstallationDropsStaleUploadsAndReleasesScopeAfterCompletion() async throws {
    let probe = ApkPresentationProbe()
    let model = ApkInstallationModel(client: probe, pollInterval: .seconds(60))
    let view = UUID()
    model.attach(viewID: view)
    try #require(await apkEventually { model.canChooseFile })
    var releases = 0
    #expect(model.upload(sourceURL: URL(fileURLWithPath: "/synthetic/Fixture.apk")) { releases += 1 })
    try #require(await apkEventually { await probe.started })
    model.deactivate()
    #expect(model.snapshot == nil && !model.isUploading)
    #expect(releases == 0)
    await probe.finish()
    try #require(await apkEventually { releases == 1 })
    #expect(model.snapshot == nil && model.uploadProgress == nil && model.selectedFilename == nil)
    #expect(!model.canChooseFile)
}

@Test @MainActor func apkInstallationCancellationThatFinishesLateStillClearsBusyState() async throws {
    let probe = ApkPresentationProbe()
    let model = ApkInstallationModel(client: probe, pollInterval: .seconds(60))
    let view = UUID()
    model.attach(viewID: view)
    defer { model.deactivate() }
    try #require(await apkEventually { model.canChooseFile })
    var releases = 0
    #expect(model.upload(sourceURL: URL(fileURLWithPath: "/synthetic/Fixture.apk")) { releases += 1 })
    try #require(await apkEventually { await probe.started })
    model.cancelUpload()
    await probe.finish()
    try #require(await apkEventually { !model.isUploading && releases == 1 })
    #expect(model.uploadFailure == .cancelled)
}

private actor ApkPresentationProbe: ApkInstallationClient {
    private var continuation: CheckedContinuation<ApkInstallationOperation, Never>?
    var started: Bool { continuation != nil }
    private var progress: (@Sendable (ApkInstallUploadProgress) async -> Void)?
    private var id = ""
    func installationSnapshot() async throws -> ApkInstallationSnapshot {
        .init(operations: [], incomingRequestsEnabled: true, systemSourceTrusted: true, canStartInstall: true)
    }
    func uploadApk(sourceURL: URL, operationID: String,
                   progress: @escaping @Sendable (ApkInstallUploadProgress) async -> Void) async throws
        -> ApkInstallationOperation {
        self.progress = progress; self.id = operationID
        return await withCheckedContinuation { continuation = $0 }
    }
    func cancelInstallation(id: String) async throws -> ApkInstallationOperation { throw ApkInstallationError.notFound }
    func finish() async {
        await progress?(.init(stage: .sending, completedBytes: 4, totalBytes: 4))
        continuation?.resume(returning: .init(id: id, displayName: "Fixture.apk", sizeBytes: 4,
            uploadedBytes: 4, state: .waitingForAndroidApproval))
        continuation = nil
    }
}

@MainActor private func apkEventually(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
