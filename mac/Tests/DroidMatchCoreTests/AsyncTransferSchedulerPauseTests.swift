import Foundation
import Testing
@testable import DroidMatchCore

@Test func asyncTransferSchedulerHoldsQueuedJobAndResumesAtFifoTail() async throws {
    let probe = SchedulerExecutionProbe()
    let scheduler = makeScheduler(maxConcurrentJobs: 1, probe: probe)
    let first = await scheduler.submit(.download(downloadRequest("hold-first")))
    let held = await scheduler.submit(.download(downloadRequest("held")))

    #expect(await probe.waitUntilStarted("hold-first"))
    let queued = try await scheduler.snapshot(for: held)
    #expect(queued.state == .queued)
    #expect(queued.canPause)
    #expect(!queued.canResume)
    #expect(await scheduler.pause(held))

    let paused = try await scheduler.snapshot(for: held)
    #expect(paused.state == .paused)
    #expect(!paused.canPause)
    #expect(paused.canResume)
    #expect(!(await scheduler.remove(held)))

    probe.release("hold-first")
    assertSuccess(try await scheduler.waitForCompletion(first))
    #expect(!probe.hasStarted("held"))

    #expect(await scheduler.resume(held))
    #expect(await probe.waitUntilStarted("held"))
    probe.release("held")
    assertSuccess(try await scheduler.waitForCompletion(held))
}

@Test func asyncTransferSchedulerResumesRunningDownloadWithSameIdentity() async throws {
    let firstAttempt = AsyncRpcOneShot<Void>()
    let observedRequests = LockedValue<[(resume: Bool, transferID: String)]>([])
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, _, progressObserver in
            observedRequests.update {
                $0.append((request.resume, request.freshTransferID))
            }
            let invocation = observedRequests.value().count
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 3,
                totalBytes: 10
            ))
            if invocation == 1 {
                try await firstAttempt.wait(onCancel: {})
            }
            return downloadResult(
                request.sourcePath,
                attemptCount: 1,
                totalBytes: 10,
                finalOffsetBytes: 10
            )
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    let job = await scheduler.submit(.download(downloadRequest("pause-resume")))

    let running = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.state == .running && $0.confirmedBytes == 3 }
    ))
    #expect(running.canPause)
    #expect(await scheduler.pause(job))
    let paused = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.state == .paused }
    ))
    #expect(paused.canResume)
    #expect(paused.recentBytesPerSecond == nil)

    #expect(await scheduler.resume(job))
    assertSuccess(try await scheduler.waitForCompletion(job))
    let completed = try await scheduler.snapshot(for: job)
    #expect(completed.state == .completed)
    #expect(completed.attemptNumber == 2)
    #expect(observedRequests.value().map(\.resume) == [false, true])
    #expect(Set(observedRequests.value().map(\.transferID)) == [
        "download-pause-resume",
    ])
}

@Test func asyncTransferSchedulerPauseWinsOverNonCooperativeCompletion() async throws {
    let gate = NonCooperativeSchedulerGate()
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, _, progressObserver in
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 3,
                totalBytes: 10
            ))
            await gate.wait()
            return downloadResult(
                request.sourcePath,
                attemptCount: 1,
                totalBytes: 10,
                finalOffsetBytes: 10
            )
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    let job = await scheduler.submit(.download(downloadRequest("pause-wins")))
    _ = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.canPause }
    ))

    #expect(await scheduler.pause(job))
    #expect(try await scheduler.snapshot(for: job).state == .pausing)
    gate.release()
    _ = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.state == .paused }
    ))
    #expect(!(await scheduler.remove(job)))

    #expect(await scheduler.cancel(job))
    assertCancelled(try await scheduler.waitForCompletion(job))
    #expect(try await scheduler.snapshot(for: job).state == .cancelled)
}

@Test func asyncTransferSchedulerCompletesIrreversibleDownloadWhilePausing() async throws {
    let gate = NonCooperativeSchedulerGate()
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, _, progressObserver in
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 3,
                totalBytes: 10
            ))
            await gate.wait()
            return downloadResult(
                request.sourcePath,
                attemptCount: 1,
                totalBytes: 10,
                finalOffsetBytes: 10,
                completionIsIrreversible: true
            )
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    let job = await scheduler.submit(.download(downloadRequest("pause-after-commit")))
    _ = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.canPause }
    ))

    #expect(await scheduler.pause(job))
    #expect(try await scheduler.snapshot(for: job).state == .pausing)
    gate.release()
    assertSuccess(try await scheduler.waitForCompletion(job))
    let completed = try await scheduler.snapshot(for: job)
    #expect(completed.state == .completed)
    #expect(completed.confirmedBytes == 10)
    #expect(!completed.canResume)
}

@Test func asyncTransferSchedulerRejectsUnsafeRunningPause() async throws {
    let downloadGate = AsyncRpcOneShot<Void>()
    let fullyConfirmedGate = AsyncRpcOneShot<Void>()
    let mediaStoreGate = AsyncRpcOneShot<Void>()
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 3,
        downloadExecutor: { request, _, progressObserver in
            if request.sourcePath == "fully-confirmed" {
                await progressObserver?(AsyncTransferProgress(
                    confirmedBytes: 10,
                    totalBytes: 10
                ))
                try await fullyConfirmedGate.wait(onCancel: {})
            } else {
                try await downloadGate.wait(onCancel: {})
            }
            return downloadResult(request.sourcePath, attemptCount: 1)
        },
        uploadExecutor: { request, _, progressObserver in
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 2,
                totalBytes: 10
            ))
            try await mediaStoreGate.wait(onCancel: {})
            return uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    let uncheckpointed = await scheduler.submit(.download(
        downloadRequest("uncheckpointed")
    ))
    let mediaStore = await scheduler.submit(.upload(AsyncUploadCoordinatorRequest(
        sourceURL: URL(fileURLWithPath: "/tmp/media-store-source"),
        destinationPath: "dm://media-images/new-item",
        freshTransferID: "media-store-upload"
    )))
    let fullyConfirmed = await scheduler.submit(.download(
        downloadRequest("fully-confirmed")
    ))

    let runningDownload = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: uncheckpointed,
        matching: { $0.state == .running }
    ))
    #expect(!runningDownload.canPause)
    #expect(!(await scheduler.pause(uncheckpointed)))
    let runningUpload = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: mediaStore,
        matching: { $0.totalBytes == 10 }
    ))
    #expect(!runningUpload.canPause)
    #expect(!(await scheduler.pause(mediaStore)))
    let finalizing = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: fullyConfirmed,
        matching: { $0.confirmedBytes == 10 }
    ))
    #expect(!finalizing.canPause)
    #expect(!(await scheduler.pause(fullyConfirmed)))

    #expect(await scheduler.cancel(uncheckpointed))
    #expect(await scheduler.cancel(mediaStore))
    #expect(await scheduler.cancel(fullyConfirmed))
    assertCancelled(try await scheduler.waitForCompletion(uncheckpointed))
    assertCancelled(try await scheduler.waitForCompletion(mediaStore))
    assertCancelled(try await scheduler.waitForCompletion(fullyConfirmed))
}

@Test func asyncTransferSchedulerKeepsAttemptNumberAcrossPausedBackoff() async throws {
    let retryGate = AsyncRpcOneShot<Void>()
    let invocations = LockedValue<[Bool]>([])
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, retryObserver, progressObserver in
            invocations.update { $0.append(request.resume) }
            if invocations.value().count == 1 {
                await progressObserver?(AsyncTransferProgress(
                    confirmedBytes: 2,
                    totalBytes: 10
                ))
                retryObserver?(1, 250, SchedulerTestError.retryable)
                try await retryGate.wait(onCancel: {})
            }
            return downloadResult(
                request.sourcePath,
                attemptCount: 1,
                totalBytes: 10,
                finalOffsetBytes: 10
            )
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    let job = await scheduler.submit(.download(downloadRequest("pause-backoff")))
    let retrying = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.state == .retrying }
    ))
    #expect(retrying.attemptNumber == 2)
    #expect(retrying.canPause)

    #expect(await scheduler.pause(job))
    _ = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.state == .paused }
    ))
    #expect(await scheduler.resume(job))
    assertSuccess(try await scheduler.waitForCompletion(job))
    #expect(try await scheduler.snapshot(for: job).attemptNumber == 2)
    #expect(invocations.value() == [false, true])
}
