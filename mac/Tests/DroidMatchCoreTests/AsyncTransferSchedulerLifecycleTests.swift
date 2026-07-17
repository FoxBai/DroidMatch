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

@Test func asyncTransferSchedulerShutdownSettlesEveryActiveJob() async throws {
    let probe = SchedulerExecutionProbe()
    let scheduler = makeScheduler(maxConcurrentJobs: 1, probe: probe)
    let running = await scheduler.submit(.download(downloadRequest("shutdown-running")))
    let queued = await scheduler.submit(.download(downloadRequest("shutdown-queued")))
    #expect(await probe.waitUntilStarted("shutdown-running"))

    await scheduler.shutdown()

    assertCancelled(try await scheduler.waitForCompletion(running))
    assertCancelled(try await scheduler.waitForCompletion(queued))
    #expect(await scheduler.snapshots().allSatisfy {
        $0.state == .cancelled && $0.canRemove
    })
    #expect(!(probe.hasStarted("shutdown-queued")))
    #expect(await probe.waitForActiveCount(0))

    let late = await scheduler.submit(.download(downloadRequest("shutdown-late")))
    assertCancelled(try await scheduler.waitForCompletion(late))
    #expect(!(probe.hasStarted("shutdown-late")))
}

@Test func asyncTransferSchedulerSuspendsSessionWithoutReplayingUnsafeWork() async throws {
    let probe = SchedulerExecutionProbe()
    let scheduler = makeScheduler(maxConcurrentJobs: 1, probe: probe)
    let running = await scheduler.submit(.download(downloadRequest("detach-running")))
    let queued = await scheduler.submit(.download(downloadRequest("detach-queued")))
    #expect(await probe.waitUntilStarted("detach-running"))

    await scheduler.suspendForSessionEnd()

    let snapshots = await scheduler.snapshots()
    #expect(snapshots.map(\.id) == [running, queued])
    #expect(snapshots.map(\.state) == [.interrupted, .paused])
    #expect(snapshots[0].canRemove)
    #expect(snapshots[1].canResume)
    #expect(!probe.hasStarted("detach-queued"))
    #expect(await probe.waitForActiveCount(0))
    guard case let .failure(description) = try await scheduler.waitForCompletion(running) else {
        Issue.record("unsafe suspended work must settle as interrupted")
        return
    }
    #expect(description == AsyncTransferSchedulerPolicy.interruptedFailureDescription)

    let late = await scheduler.submit(.download(downloadRequest("detach-late")))
    assertCancelled(try await scheduler.waitForCompletion(late))
}

@Test func sessionSuspensionPreservesIrreversibleEmptyAndUnknownTotalDownloads() async throws {
    let emptyGate = NonCooperativeSchedulerGate()
    let unknownGate = NonCooperativeSchedulerGate()
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 2,
        downloadExecutor: { request, _, progressObserver in
            if request.sourcePath == "empty-finalize" {
                await progressObserver?(AsyncTransferProgress(
                    confirmedBytes: 0,
                    totalBytes: 0
                ))
                await emptyGate.wait()
                return downloadResult(
                    request.sourcePath,
                    attemptCount: 1,
                    completionIsIrreversible: true
                )
            }
            await unknownGate.wait()
            return downloadResult(
                request.sourcePath,
                attemptCount: 1,
                totalBytes: -1,
                completionIsIrreversible: true
            )
        },
        uploadExecutor: { request, _, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    let empty = await scheduler.submit(.download(downloadRequest("empty-finalize")))
    let unknown = await scheduler.submit(.download(downloadRequest("unknown-finalize")))
    #expect(await emptyGate.waitUntilStarted())
    #expect(await unknownGate.waitUntilStarted())
    _ = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: empty,
        matching: { $0.state == .running && $0.totalBytes == 0 }
    ))

    let emptyOutcome = Task { try await scheduler.waitForCompletion(empty) }
    let unknownOutcome = Task { try await scheduler.waitForCompletion(unknown) }
    let suspension = Task { await scheduler.suspendForSessionEnd() }
    let interruptedEmpty = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: empty,
        matching: { $0.state == .interrupted }
    ))
    let interruptedUnknown = try #require(await waitForSchedulerSnapshot(
        scheduler: scheduler,
        id: unknown,
        matching: { $0.state == .interrupted }
    ))
    #expect(!interruptedEmpty.canRemove)
    #expect(!interruptedUnknown.canRemove)

    emptyGate.release()
    unknownGate.release()
    await suspension.value
    assertSuccess(try await emptyOutcome.value)
    assertSuccess(try await unknownOutcome.value)

    let completedEmpty = try await scheduler.snapshot(for: empty)
    let completedUnknown = try await scheduler.snapshot(for: unknown)
    #expect(completedEmpty.state == .completed)
    #expect(completedUnknown.state == .completed)
    #expect(completedEmpty.fractionCompleted == 1)
    #expect(completedUnknown.fractionCompleted == 1)
    #expect(completedEmpty.canRemove)
    #expect(completedUnknown.canRemove)
}
