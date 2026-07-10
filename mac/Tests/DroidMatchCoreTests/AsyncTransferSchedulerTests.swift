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
    #expect(!probe.hasStarted("queued"))

    #expect(await scheduler.cancel(running))
    assertCancelled(try await scheduler.waitForCompletion(running))
    #expect(try await scheduler.snapshot(for: running).state == .cancelled)
    #expect(!(await scheduler.cancel(running)))
    #expect(await probe.waitForActiveCount(0))
}

@Test func asyncTransferSchedulerPublishesRetryStateAndFinalAttemptCount() async throws {
    let gate = AsyncRpcOneShot<Void>()
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, observer in
            observer?(1, 250, SchedulerTestError.retryable)
            try await gate.wait(onCancel: {})
            return downloadResult(request.sourcePath, attemptCount: 2)
        },
        uploadExecutor: { request, _ in
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

@Test func asyncTransferSchedulerKeepsCancellationAuthoritativeForSlowUnwind() async throws {
    let gate = NonCooperativeSchedulerGate()
    let scheduler = AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { request, _ in
            await gate.wait()
            return downloadResult(request.sourcePath, attemptCount: 1)
        },
        uploadExecutor: { request, _ in
            uploadResult(request.sourceURL.path, attemptCount: 1)
        }
    )
    let job = await scheduler.submit(.download(downloadRequest("slow-cancel")))
    #expect(await gate.waitUntilStarted())

    #expect(await scheduler.cancel(job))
    #expect(!(await scheduler.remove(job)))
    gate.release()
    assertCancelled(try await scheduler.waitForCompletion(job))
    #expect(try await scheduler.snapshot(for: job).state == .cancelled)
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

private enum SchedulerTestError: Error {
    case retryable
}

private func makeScheduler(
    maxConcurrentJobs: Int,
    probe: SchedulerExecutionProbe
) -> AsyncTransferScheduler {
    AsyncTransferScheduler(
        maxConcurrentJobs: maxConcurrentJobs,
        downloadExecutor: { request, _ in
            try await probe.execute(request.sourcePath)
            return downloadResult(request.sourcePath, attemptCount: 1)
        },
        uploadExecutor: { request, _ in
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
    attemptCount: Int
) -> AsyncDownloadCoordinatorResult {
    var response = Droidmatch_V1_OpenTransferResponse()
    response.transferID = label
    return AsyncDownloadCoordinatorResult(
        download: DownloadResult(
            openResponse: response,
            chunkCount: 0,
            bytesReceived: 0,
            finalOffsetBytes: 0
        ),
        attemptCount: attemptCount
    )
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
