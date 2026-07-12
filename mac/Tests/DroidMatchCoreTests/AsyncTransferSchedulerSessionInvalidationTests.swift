import Foundation
import Testing
@testable import DroidMatchCore

@Test func suspendedSchedulerCannotOverwriteReplacementSessionManifest() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifestURL = directory.appendingPathComponent("queue.json")
    let store = try TransferQueuePersistenceStore(fileURL: manifestURL)
    let probe = SchedulerExecutionProbe()
    let staleScheduler = sessionInvalidationScheduler(store: store, probe: probe)
    let runningPath = "dm://app-sandbox/stale-session-running.bin"
    let pausedPath = "dm://app-sandbox/stale-session-paused.bin"
    let currentPath = "dm://app-sandbox/current-session-new.bin"

    let interruptedID = await staleScheduler.submit(.download(
        sessionInvalidationRequest(sourcePath: runningPath)
    ))
    let pausedID = await staleScheduler.submit(.download(
        sessionInvalidationRequest(sourcePath: pausedPath)
    ))
    #expect(await probe.waitUntilStarted(runningPath))
    await staleScheduler.suspendForSessionEnd()
    #expect(await probe.waitForActiveCount(0))
    #expect(try await staleScheduler.snapshot(for: interruptedID).state == .interrupted)
    #expect(try await staleScheduler.snapshot(for: pausedID).state == .paused)
    #expect(await staleScheduler.persistenceStatus() == .writeFailed)
    #expect(await staleScheduler.authoritativeLocalFileAccessURLs() == nil)

    let currentScheduler = try await AsyncTransferScheduler.restoring(
        maxConcurrentJobs: 1,
        persistenceStore: store,
        downloadExecutor: sessionInvalidationDownloadExecutor(probe: probe),
        uploadExecutor: sessionInvalidationUploadExecutor(probe: probe),
        startQueuedJobs: false
    )
    let currentID = await currentScheduler.submit(.download(
        sessionInvalidationRequest(sourcePath: currentPath)
    ))
    let currentManifest = try Data(contentsOf: manifestURL)
    await staleScheduler.suspendForSessionEnd()
    await staleScheduler.shutdown()
    #expect(try Data(contentsOf: manifestURL) == currentManifest)

    #expect(!(await staleScheduler.pause(pausedID)))
    #expect(!(await staleScheduler.resume(pausedID)))
    #expect(!(await staleScheduler.cancel(pausedID)))
    #expect(!(await staleScheduler.remove(interruptedID)))
    #expect(!(await staleScheduler.retryPersistence()))
    #expect(!(await staleScheduler.retryPersistence(startQueuedJobs: false)))
    #expect(!(await staleScheduler.activateExecution()))
    #expect(await probe.waitForActiveCount(0))
    #expect(try Data(contentsOf: manifestURL) == currentManifest)

    let currentSnapshots = await currentScheduler.snapshots()
    #expect(currentSnapshots.first(where: { $0.id == pausedID })?.state == .paused)
    #expect(currentSnapshots.first(where: { $0.id == currentID })?.state == .queued)
    #expect(!probe.hasStarted(pausedPath))
    #expect(!probe.hasStarted(currentPath))
    await currentScheduler.suspendForSessionEnd()
}

private func sessionInvalidationRequest(sourcePath: String) -> AsyncDownloadCoordinatorRequest {
    AsyncDownloadCoordinatorRequest(
        sourcePath: sourcePath,
        destinationURL: URL(fileURLWithPath: "/tmp/\(sourcePath.replacingOccurrences(of: "/", with: "_"))")
    )
}

private func sessionInvalidationScheduler(
    store: TransferQueuePersistenceStore,
    probe: SchedulerExecutionProbe
) -> AsyncTransferScheduler {
    AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: sessionInvalidationDownloadExecutor(probe: probe),
        uploadExecutor: sessionInvalidationUploadExecutor(probe: probe),
        persistenceStore: store
    )
}

private func sessionInvalidationDownloadExecutor(
    probe: SchedulerExecutionProbe
) -> AsyncDownloadJobExecutor {
    { request, _, _ in
        try await probe.execute(request.sourcePath)
        return downloadResult(request.sourcePath, attemptCount: 1)
    }
}

private func sessionInvalidationUploadExecutor(
    probe: SchedulerExecutionProbe
) -> AsyncUploadJobExecutor {
    { request, _, _ in
        try await probe.execute(request.sourceURL.lastPathComponent)
        return uploadResult(request.sourceURL.path, attemptCount: 1)
    }
}
