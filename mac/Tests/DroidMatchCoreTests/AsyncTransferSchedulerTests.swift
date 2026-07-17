import Foundation
import Testing
@testable import DroidMatchCore

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
    #expect(snapshot.failureDescription == "transfer error")

    gate.resolve(.success(()))
    assertSuccess(try await scheduler.waitForCompletion(job))
    let completed = try await scheduler.snapshot(for: job)
    #expect(completed.state == .completed)
    #expect(completed.attemptNumber == 2)
    #expect(completed.retryDelayMilliseconds == nil)
    #expect(completed.failureDescription == nil)
}

@Test func asyncTransferSchedulerRedactsProviderDetailsFromFailureOutcome() async throws {
    let remoteError: Droidmatch_V1_DroidMatchError = {
        var value = Droidmatch_V1_DroidMatchError()
        value.code = .notFound
        value.message = "/private/provider/document-id/secret.jpg"
        return value
    }()
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { _, _, _ in
            throw RpcControlClientError.remoteError(remoteError)
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    let job = await scheduler.submit(.download(downloadRequest("privacy")))

    let outcome = try await scheduler.waitForCompletion(job)
    guard case let .failure(label) = outcome else {
        Issue.record("expected a failed scheduler outcome")
        return
    }
    #expect(label == "remote error: notFound")
    #expect(!label.contains("secret.jpg"))

    let snapshot = try await scheduler.snapshot(for: job)
    #expect(snapshot.failureDescription == "remote error: notFound")
}

@Test func schedulerRejectsDuplicateCanonicalDownloadDestinationBeforeExecution() async throws {
    let probe = SchedulerExecutionProbe()
    let scheduler = makeScheduler(maxConcurrentJobs: 2, probe: probe)
    let destination = URL(fileURLWithPath: "/tmp/droidmatch-admission/same.bin")
    let lexicalAlias = URL(
        fileURLWithPath: "/tmp/droidmatch-admission/nested/../same.bin"
    )
    let firstRequest = AsyncTransferJobRequest.download(
        AsyncDownloadCoordinatorRequest(
            sourcePath: "first-owner",
            destinationURL: lexicalAlias,
            freshTransferID: "first-owner"
        )
    )
    let duplicateRequest = AsyncTransferJobRequest.download(
        AsyncDownloadCoordinatorRequest(
            sourcePath: "strict-duplicate",
            destinationURL: destination,
            freshTransferID: "strict-duplicate"
        )
    )

    let first = try await scheduler.submitValidated(firstRequest)
    #expect(await probe.waitUntilStarted("first-owner"))
    do {
        _ = try await scheduler.submitValidated(duplicateRequest)
        Issue.record("duplicate destination must fail scheduler admission")
    } catch let error {
        #expect(error == .duplicateDownloadDestination)
        #expect(!error.description.contains(destination.path))
    }
    #expect(await scheduler.snapshots().map(\.id) == [first])
    #expect(!probe.hasStarted("strict-duplicate"))

    for reservedName in [
        "same.bin.droidmatch-part",
        "same.bin.droidmatch-transfer.json",
        ".same.bin.droidmatch-transfer.json.pending",
        ".same.bin.droidmatch-transfer.json.removing",
        ".same.bin.droidmatch-commit",
        ".same.bin.droidmatch-replaced",
    ] {
        let reservedRequest = AsyncTransferJobRequest.download(
            AsyncDownloadCoordinatorRequest(
                sourcePath: "reserved-namespace",
                destinationURL: destination.deletingLastPathComponent()
                    .appendingPathComponent(reservedName),
                freshTransferID: "reserved-namespace"
            )
        )
        await #expect(throws: AsyncTransferSchedulerError.duplicateDownloadDestination) {
            _ = try await scheduler.submitValidated(reservedRequest)
        }
    }

    for equivalentDestination in [
        URL(fileURLWithPath: "/private/tmp/droidmatch-admission/same.bin"),
        URL(fileURLWithPath: "/tmp/droidmatch-admission/SAME.BIN"),
    ] {
        await #expect(throws: AsyncTransferSchedulerError.duplicateDownloadDestination) {
            _ = try await scheduler.submitValidated(.download(
                AsyncDownloadCoordinatorRequest(
                    sourcePath: "filesystem-equivalent",
                    destinationURL: equivalentDestination,
                    freshTransferID: "filesystem-equivalent"
                )
            ))
        }
    }

    let compatibleDuplicate = await scheduler.submit(.download(
        AsyncDownloadCoordinatorRequest(
            sourcePath: "compatible-duplicate",
            destinationURL: destination,
            freshTransferID: "compatible-duplicate"
        )
    ))
    let rejected = try await scheduler.snapshot(for: compatibleDuplicate)
    #expect(rejected.state == .failed)
    #expect(rejected.canRemove)
    #expect(
        rejected.failureDescription
            == AsyncTransferSchedulerPolicy.duplicateDownloadDestinationFailureDescription
    )
    #expect(!probe.hasStarted("compatible-duplicate"))

    probe.release("first-owner")
    assertSuccess(try await scheduler.waitForCompletion(first))
    let replacement = try await scheduler.submitValidated(.download(
        AsyncDownloadCoordinatorRequest(
            sourcePath: "terminal-replacement",
            destinationURL: destination,
            freshTransferID: "terminal-replacement"
        )
    ))
    #expect(await probe.waitUntilStarted("terminal-replacement"))
    probe.release("terminal-replacement")
    assertSuccess(try await scheduler.waitForCompletion(replacement))
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

@Test func asyncTransferSchedulerRejectsOverflowingRetryBeforeLateSuccess() async throws {
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, retryObserver, _ in
            if request.sourcePath == "overflow-retry-success" {
                retryObserver?(Int.max, 0, SchedulerTestError.retryable)
            }
            return downloadResult(
                request.sourcePath,
                attemptCount: 1,
                completionIsIrreversible: true
            )
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    let job = await scheduler.submit(.download(downloadRequest("overflow-retry-success")))
    let following = await scheduler.submit(.download(downloadRequest("after-overflow")))

    let outcome = try await scheduler.waitForCompletion(job)
    if case let .failure(description) = outcome {
        #expect(description == AsyncTransferSchedulerPolicy.attemptAccountingFailureDescription)
    } else {
        Issue.record("late executor success must not replace an attempt fail-stop")
    }
    let snapshot = try await scheduler.snapshot(for: job)
    #expect(snapshot.state == .interrupted)
    #expect(snapshot.attemptNumber == 1)
    #expect(snapshot.canRemove)
    #expect(await scheduler.persistenceStatus() == .disabled)
    assertSuccess(try await scheduler.waitForCompletion(following))
    #expect(try await scheduler.snapshot(for: following).state == .completed)
}

@Test func asyncTransferSchedulerRejectsOverflowingRetryBeforeCancellation() async throws {
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { _, retryObserver, _ in
            retryObserver?(Int.max, 0, SchedulerTestError.retryable)
            while !Task.isCancelled { await Task.yield() }
            throw CancellationError()
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    let job = await scheduler.submit(.download(downloadRequest("overflow-retry-cancel")))

    let outcome = try await scheduler.waitForCompletion(job)
    if case let .failure(description) = outcome {
        #expect(description == AsyncTransferSchedulerPolicy.attemptAccountingFailureDescription)
    } else {
        Issue.record("executor cancellation must not replace an attempt fail-stop")
    }
    let snapshot = try await scheduler.snapshot(for: job)
    #expect(snapshot.state == .interrupted)
    #expect(snapshot.canRemove)
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

@Test func processLocalPersistenceReloadFailsWithoutTerminatingTheProcess() {
    var state = AsyncTransferSchedulerPersistenceState(store: nil)

    #expect(throws: TransferQueuePersistenceStoreError.ioFailure) {
        _ = try state.reload()
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
