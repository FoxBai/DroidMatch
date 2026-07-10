import Foundation
import Testing
@testable import DroidMatchCore

@Test func asyncTransferSchedulerEnforcesTwoJobFifoAdmission() async throws {
    let probe = SchedulerExecutionProbe()
    let scheduler = makeScheduler(maxConcurrentJobs: 2, probe: probe)

    let first = await scheduler.submit(.download(downloadRequest("first")))
    let second = await scheduler.submit(.download(downloadRequest("second")))
    let third = await scheduler.submit(.download(downloadRequest("third")))

    #expect(await probe.waitForStartedCount(2))
    #expect(probe.maximumActiveCount == 2)
    #expect(try await scheduler.snapshot(for: first).state == .running)
    #expect(try await scheduler.snapshot(for: second).state == .running)
    #expect(try await scheduler.snapshot(for: third).state == .queued)

    probe.release("first")
    #expect(await probe.waitUntilStarted("third"))
    #expect(try await scheduler.snapshot(for: third).state == .running)
    #expect(probe.maximumActiveCount == 2)

    probe.release("second")
    probe.release("third")
    assertSuccess(try await scheduler.waitForCompletion(first))
    assertSuccess(try await scheduler.waitForCompletion(second))
    assertSuccess(try await scheduler.waitForCompletion(third))
    #expect(await scheduler.snapshots().map(\.state) == [
        .completed,
        .completed,
        .completed,
    ])
}

@Test func asyncTransferSchedulerCancelsQueuedAndRunningJobs() async throws {
    let probe = SchedulerExecutionProbe()
    let scheduler = makeScheduler(maxConcurrentJobs: 1, probe: probe)

    let running = await scheduler.submit(.download(downloadRequest("running")))
    let queued = await scheduler.submit(.download(downloadRequest("queued")))
    #expect(await probe.waitUntilStarted("running"))
    #expect(try await scheduler.snapshot(for: queued).state == .queued)

    #expect(await scheduler.cancel(queued))
    assertCancelled(try await scheduler.waitForCompletion(queued))
    let settledQueuedCancellation = try await scheduler.snapshot(for: queued)
    #expect(!settledQueuedCancellation.canCancel)
    #expect(settledQueuedCancellation.canRemove)
    #expect(!probe.hasStarted("queued"))

    let active = try await scheduler.snapshot(for: running)
    #expect(active.canCancel)
    #expect(!active.canRemove)
    #expect(await scheduler.cancel(running))
    assertCancelled(try await scheduler.waitForCompletion(running))
    let settledRunningCancellation = try await scheduler.snapshot(for: running)
    #expect(settledRunningCancellation.state == .cancelled)
    #expect(!settledRunningCancellation.canCancel)
    #expect(settledRunningCancellation.canRemove)
    #expect(!(await scheduler.cancel(running)))
    #expect(await probe.waitForActiveCount(0))
}

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

@Test func asyncTransferSchedulerPublishesRetryStateAndFinalAttemptCount() async throws {
    let gate = AsyncRpcOneShot<Void>()
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, observer, _ in
            observer?(1, 250, SchedulerTestError.retryable)
            try await gate.wait(onCancel: {})
            return downloadResult(request.sourcePath, attemptCount: 2)
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    let job = await scheduler.submit(.download(downloadRequest("retrying")))

    var retrySnapshot: AsyncTransferJobSnapshot?
    for _ in 0..<200 {
        let candidate = try await scheduler.snapshot(for: job)
        if candidate.state == .retrying {
            retrySnapshot = candidate
            break
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let snapshot = try #require(retrySnapshot)
    #expect(snapshot.attemptNumber == 2)
    #expect(snapshot.retryDelayMilliseconds == 250)
    #expect(snapshot.failureDescription?.contains("retryable") == true)

    gate.resolve(.success(()))
    assertSuccess(try await scheduler.waitForCompletion(job))
    let completed = try await scheduler.snapshot(for: job)
    #expect(completed.state == .completed)
    #expect(completed.attemptNumber == 2)
    #expect(completed.retryDelayMilliseconds == nil)
    #expect(completed.failureDescription == nil)
}

@Test func asyncTransferSchedulerKeepsConfirmedProgressMonotonicAcrossRetry() async throws {
    let resumeAttempt = AsyncRpcOneShot<Void>()
    let finishAttempt = AsyncRpcOneShot<Void>()
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, retryObserver, progressObserver in
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 6,
                totalBytes: 10
            ))
            retryObserver?(1, 250, SchedulerTestError.retryable)
            try await resumeAttempt.wait(onCancel: {})
            // A reconnect may repeat the durable offset or deliver a stale
            // lower observation; neither may move product progress backwards.
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 4,
                totalBytes: 10
            ))
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 7,
                totalBytes: 11
            ))
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 6,
                totalBytes: 10
            ))
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 8,
                totalBytes: 10
            ))
            try await finishAttempt.wait(onCancel: {})
            return downloadResult(
                request.sourcePath,
                attemptCount: 2,
                totalBytes: 10,
                finalOffsetBytes: 10
            )
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    let job = await scheduler.submit(.download(downloadRequest("progress-retry")))

    let retrying = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.state == .retrying }
    ))
    #expect(retrying.confirmedBytes == 6)
    #expect(retrying.totalBytes == 10)
    #expect(retrying.fractionCompleted == 0.6)

    resumeAttempt.resolve(.success(()))
    let resumed = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.state == .running && $0.confirmedBytes == 8 }
    ))
    #expect(resumed.totalBytes == 10)
    #expect(resumed.retryDelayMilliseconds == nil)
    #expect(resumed.failureDescription == nil)

    finishAttempt.resolve(.success(()))
    assertSuccess(try await scheduler.waitForCompletion(job))
    let completed = try await scheduler.snapshot(for: job)
    #expect(completed.confirmedBytes == 10)
    #expect(completed.totalBytes == 10)
    #expect(completed.fractionCompleted == 1)
}

@Test func asyncTransferSchedulerOrdersImmediateReconnectProgressAfterRetry() async throws {
    let finishAttempt = AsyncRpcOneShot<Void>()
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, retryObserver, progressObserver in
            retryObserver?(1, 0, SchedulerTestError.retryable)
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 4,
                totalBytes: 10
            ))
            try await finishAttempt.wait(onCancel: {})
            return downloadResult(
                request.sourcePath,
                attemptCount: 2,
                totalBytes: 10,
                finalOffsetBytes: 10
            )
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    let job = await scheduler.submit(.download(downloadRequest("immediate-reconnect")))

    let running = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.state == .running && $0.confirmedBytes == 4 }
    ))
    #expect(running.attemptNumber == 2)
    #expect(running.retryDelayMilliseconds == nil)
    #expect(running.failureDescription == nil)

    finishAttempt.resolve(.success(()))
    assertSuccess(try await scheduler.waitForCompletion(job))
}

@Test func asyncTransferSchedulerPublishesRecentRateAndResetsItOnRetry() async throws {
    let clock = SchedulerTestMonotonicClock()
    let emitFirstProgress = AsyncRpcOneShot<Void>()
    let beginRetry = AsyncRpcOneShot<Void>()
    let emitFinalProgress = AsyncRpcOneShot<Void>()
    let complete = AsyncRpcOneShot<Void>()
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, retryObserver, progressObserver in
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 0,
                totalBytes: 10
            ))
            try await emitFirstProgress.wait(onCancel: {})
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 4,
                totalBytes: 10
            ))
            try await beginRetry.wait(onCancel: {})
            retryObserver?(1, 0, SchedulerTestError.retryable)
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 4,
                totalBytes: 10
            ))
            try await emitFinalProgress.wait(onCancel: {})
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 10,
                totalBytes: 10
            ))
            try await complete.wait(onCancel: {})
            return downloadResult(
                request.sourcePath,
                attemptCount: 2,
                totalBytes: 10,
                finalOffsetBytes: 10
            )
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        },
        monotonicNow: { clock.now() }
    )
    let job = await scheduler.submit(.download(downloadRequest("rate")))

    let initial = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.totalBytes == 10 }
    ))
    #expect(initial.confirmedBytes == 0)
    #expect(initial.recentBytesPerSecond == nil)

    clock.set(1_000_000_000)
    emitFirstProgress.resolve(.success(()))
    let firstRate = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.recentBytesPerSecond == 4 }
    ))
    #expect(firstRate.confirmedBytes == 4)

    // Backoff/reconnect time is deliberately excluded from the next attempt's
    // rate. Its accepted offset only establishes a fresh baseline.
    clock.set(100_000_000_000)
    beginRetry.resolve(.success(()))
    let resumed = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: {
            $0.state == .running
                && $0.attemptNumber == 2
                && $0.confirmedBytes == 4
                && $0.recentBytesPerSecond == nil
        }
    ))
    #expect(resumed.retryDelayMilliseconds == nil)

    clock.set(102_000_000_000)
    emitFinalProgress.resolve(.success(()))
    let resumedRate = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.confirmedBytes == 10 && $0.recentBytesPerSecond == 3 }
    ))
    #expect(resumedRate.state == .running)

    complete.resolve(.success(()))
    assertSuccess(try await scheduler.waitForCompletion(job))
    let completed = try await scheduler.snapshot(for: job)
    #expect(completed.state == .completed)
    #expect(completed.recentBytesPerSecond == 3)
}

@Test func asyncTransferSchedulerRejectsLateProgressAfterCancellation() async throws {
    let gate = NonCooperativeSchedulerGate()
    let clock = SchedulerTestMonotonicClock()
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, _, progressObserver in
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 0,
                totalBytes: 10
            ))
            clock.set(1_000_000_000)
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 3,
                totalBytes: 10
            ))
            await gate.wait()
            clock.set(2_000_000_000)
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 9,
                totalBytes: 10
            ))
            return downloadResult(
                request.sourcePath,
                attemptCount: 1,
                totalBytes: 10,
                finalOffsetBytes: 10
            )
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        },
        monotonicNow: { clock.now() }
    )
    let job = await scheduler.submit(.download(downloadRequest("late-progress")))
    _ = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.confirmedBytes == 3 }
    ))

    #expect(await scheduler.cancel(job))
    gate.release()
    assertCancelled(try await scheduler.waitForCompletion(job))
    let cancelled = try await scheduler.snapshot(for: job)
    #expect(cancelled.state == .cancelled)
    #expect(cancelled.confirmedBytes == 3)
    #expect(cancelled.totalBytes == 10)
    #expect(cancelled.recentBytesPerSecond == 3)
}

@Test func asyncTransferSchedulerExpiresStalledRunningRate() async throws {
    let clock = SchedulerTestMonotonicClock()
    let expiryGate = AsyncRpcOneShot<Void>()
    let complete = AsyncRpcOneShot<Void>()
    let observedExpiryDelay = LockedValue<UInt64?>(nil)
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, _, progressObserver in
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 0,
                totalBytes: 10
            ))
            clock.set(1_000_000_000)
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 4,
                totalBytes: 10
            ))
            try await complete.wait(onCancel: {})
            return downloadResult(
                request.sourcePath,
                attemptCount: 1,
                totalBytes: 10,
                finalOffsetBytes: 10
            )
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        },
        monotonicNow: { clock.now() },
        rateExpirySleeper: { nanoseconds in
            observedExpiryDelay.set(nanoseconds)
            try await expiryGate.wait(onCancel: {})
        }
    )
    let job = await scheduler.submit(.download(downloadRequest("stalled-rate")))

    _ = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: { $0.recentBytesPerSecond == 4 }
    ))
    for _ in 0..<200 {
        if observedExpiryDelay.value() != nil { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(observedExpiryDelay.value() ==
        AsyncTransferRateEstimator.defaultWindowNanoseconds)

    expiryGate.resolve(.success(()))
    let expired = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: job,
        matching: {
            $0.state == .running
                && $0.confirmedBytes == 4
                && $0.recentBytesPerSecond == nil
        }
    ))
    #expect(expired.totalBytes == 10)

    complete.resolve(.success(()))
    assertSuccess(try await scheduler.waitForCompletion(job))
}

@Test func asyncTransferSchedulerUsesTerminalStateForEmptyTransferCompletion() async throws {
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, _, progressObserver in
            await progressObserver?(AsyncTransferProgress(
                confirmedBytes: 0,
                totalBytes: 0
            ))
            return downloadResult(request.sourcePath, attemptCount: 1)
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    let job = await scheduler.submit(.download(downloadRequest("empty")))

    assertSuccess(try await scheduler.waitForCompletion(job))
    let completed = try await scheduler.snapshot(for: job)
    #expect(completed.state == .completed)
    #expect(completed.confirmedBytes == 0)
    #expect(completed.totalBytes == 0)
    #expect(completed.fractionCompleted == 1)
}

@Test func asyncTransferSchedulerKeepsCancellationAuthoritativeForSlowUnwind() async throws {
    let gate = NonCooperativeSchedulerGate()
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, _, _ in
            await gate.wait()
            return downloadResult(request.sourcePath, attemptCount: 1)
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    let job = await scheduler.submit(.download(downloadRequest("slow-cancel")))
    #expect(await gate.waitUntilStarted())

    #expect(await scheduler.cancel(job))
    let cancelling = try await scheduler.snapshot(for: job)
    #expect(cancelling.state == .cancelled)
    #expect(!cancelling.canCancel)
    #expect(!cancelling.canRemove)
    #expect(!(await scheduler.remove(job)))
    gate.release()
    assertCancelled(try await scheduler.waitForCompletion(job))
    let settled = try await scheduler.snapshot(for: job)
    #expect(settled.state == .cancelled)
    #expect(settled.canRemove)
    #expect(await scheduler.remove(job))
}

@Test func asyncTransferSchedulerUpdateStreamStartsWithCurrentOrderedSnapshot() async throws {
    let probe = SchedulerExecutionProbe()
    let scheduler = makeScheduler(maxConcurrentJobs: 1, probe: probe)
    let first = await scheduler.submit(.download(downloadRequest("stream-first")))
    let second = await scheduler.submit(.upload(uploadRequest("stream-second")))

    let updates = await scheduler.updates()
    var iterator = updates.makeAsyncIterator()
    let initial = try #require(await iterator.next())
    #expect(initial.map(\.id) == [first, second])
    #expect(initial.map(\.kind) == [.download, .upload])
    #expect(initial.map(\.state) == [.running, .queued])

    probe.release("stream-first")
    #expect(await probe.waitUntilStarted("stream-second"))
    probe.release("stream-second")
    _ = try await scheduler.waitForCompletion(first)
    _ = try await scheduler.waitForCompletion(second)
}

private final class SchedulerExecutionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String] = []
    private var activeCount = 0
    private var maxActiveCount = 0
    private var gates: [String: AsyncRpcOneShot<Void>] = [:]
    private var earlyReleases: Set<String> = []

    var maximumActiveCount: Int {
        lock.withLock { maxActiveCount }
    }

    func execute(_ label: String) async throws {
        let (gate, releaseImmediately) = lock.withLock {
            let gate = AsyncRpcOneShot<Void>()
            gates[label] = gate
            started.append(label)
            activeCount += 1
            maxActiveCount = max(maxActiveCount, activeCount)
            return (gate, earlyReleases.remove(label) != nil)
        }
        if releaseImmediately { gate.resolve(.success(())) }
        defer {
            lock.withLock { activeCount -= 1 }
        }
        try await gate.wait(onCancel: {})
    }

    func release(_ label: String) {
        let gate: AsyncRpcOneShot<Void>? = lock.withLock {
            if let gate = gates[label] { return gate }
            earlyReleases.insert(label)
            return nil
        }
        gate?.resolve(.success(()))
    }

    func hasStarted(_ label: String) -> Bool {
        lock.withLock { started.contains(label) }
    }

    func waitForStartedCount(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if lock.withLock({ started.count >= count }) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitUntilStarted(_ label: String) async -> Bool {
        for _ in 0..<200 {
            if hasStarted(label) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitForActiveCount(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if lock.withLock({ activeCount == count }) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

private final class NonCooperativeSchedulerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                started = true
                self.continuation = continuation
            }
        }
    }

    func release() {
        let continuation = lock.withLock {
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume()
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 {
            if lock.withLock({ started }) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

private final class SchedulerTestMonotonicClock: @unchecked Sendable {
    private let uptimeNanoseconds = LockedValue<UInt64>(0)

    func now() -> UInt64 {
        uptimeNanoseconds.value()
    }

    func set(_ value: UInt64) {
        uptimeNanoseconds.set(value)
    }
}

private enum SchedulerTestError: Error {
    case retryable
}

private func makeScheduler(
    maxConcurrentJobs: Int,
    probe: SchedulerExecutionProbe
) -> AsyncTransferScheduler {
    AsyncTransferScheduler(
        maxConcurrentJobs: maxConcurrentJobs,
        downloadExecutor: { request, _, _ in
            try await probe.execute(request.sourcePath)
            return downloadResult(request.sourcePath, attemptCount: 1)
        },
        uploadExecutor: { request, _, _ in
            try await probe.execute(request.sourceURL.lastPathComponent)
            return uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
}

private func downloadRequest(_ label: String) -> AsyncDownloadCoordinatorRequest {
    AsyncDownloadCoordinatorRequest(
        sourcePath: label,
        destinationURL: URL(fileURLWithPath: "/tmp/\(label).bin"),
        freshTransferID: "download-\(label)"
    )
}

private func uploadRequest(_ label: String) -> AsyncUploadCoordinatorRequest {
    AsyncUploadCoordinatorRequest(
        sourceURL: URL(fileURLWithPath: "/tmp/\(label)"),
        destinationPath: "dm://app-sandbox/\(label)",
        freshTransferID: "upload-\(label)"
    )
}

private func downloadResult(
    _ label: String,
    attemptCount: Int,
    totalBytes: Int64 = 0,
    finalOffsetBytes: Int64 = 0
) -> AsyncDownloadCoordinatorResult {
    var response = Droidmatch_V1_OpenTransferResponse()
    response.transferID = label
    response.totalSizeBytes = totalBytes
    return AsyncDownloadCoordinatorResult(
        download: DownloadResult(
            openResponse: response,
            chunkCount: 0,
            bytesReceived: 0,
            finalOffsetBytes: finalOffsetBytes
        ),
        attemptCount: attemptCount
    )
}

private func waitForSchedulerSnapshot(
    scheduler: AsyncTransferScheduler,
    id: UUID,
    matching predicate: (AsyncTransferJobSnapshot) -> Bool
) async throws -> AsyncTransferJobSnapshot? {
    for _ in 0..<200 {
        let snapshot = try await scheduler.snapshot(for: id)
        if predicate(snapshot) { return snapshot }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return nil
}

private func uploadResult(
    _ label: String,
    attemptCount: Int
) -> AsyncUploadCoordinatorResult {
    var response = Droidmatch_V1_OpenTransferResponse()
    response.transferID = label
    return AsyncUploadCoordinatorResult(
        upload: UploadResult(
            openResponse: response,
            chunkCount: 0,
            bytesSent: 0,
            finalOffsetBytes: 0
        ),
        attemptCount: attemptCount
    )
}

private func assertSuccess(
    _ outcome: AsyncTransferJobOutcome,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard case .success = outcome else {
        Issue.record("expected successful scheduler outcome", sourceLocation: sourceLocation)
        return
    }
}

private func assertCancelled(
    _ outcome: AsyncTransferJobOutcome,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard case .cancelled = outcome else {
        Issue.record("expected cancelled scheduler outcome", sourceLocation: sourceLocation)
        return
    }
}
