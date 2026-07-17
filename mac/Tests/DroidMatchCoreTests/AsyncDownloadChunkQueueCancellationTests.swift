import Foundation
import Testing
@testable import DroidMatchCore

@Test func oneShotFirstResolutionRetainsConsumableValueForPreCancelledWaiter() async throws {
    let oneShot = AsyncRpcOneShot<Int>()
    #expect(oneShot.resolve(.success(42)))
    let begin = QueueCancellationTestGate()
    let consumer = Task { () async throws -> Int in
        await begin.wait()
        return try await oneShot.wait(
            cancellationPolicy: .firstResolutionWins,
            onCancel: {}
        )
    }

    consumer.cancel()
    await begin.open()

    #expect(try await consumer.value == 42)
}

@Test func oneShotRejectsASecondWaitInsteadOfCrashingOrReplacingTheConsumer() async throws {
    let oneShot = AsyncRpcOneShot<Int>()
    #expect(oneShot.resolve(.success(42)))
    #expect(try await oneShot.wait(onCancel: {}) == 42)

    await #expect(throws: AsyncRpcOneShotStateError.waitAlreadyClaimed) {
        _ = try await oneShot.wait(onCancel: {})
    }
}

@Test func downloadChunkQueuePreservesChunkWhenCancellationResolvesFirst() async throws {
    let queue = AsyncDownloadChunkQueue(capacity: 4)
    let begin = QueueCancellationTestGate()
    let consumer = Task { () async throws -> Droidmatch_V1_TransferChunk? in
        await begin.wait()
        return try await queue.next()
    }

    consumer.cancel()
    await begin.open()
    await #expect(throws: CancellationError.self) {
        _ = try await consumer.value
    }

    let chunk = queueCancellationTestChunk()
    #expect(queue.yield(chunk))
    #expect(try await queue.next() == chunk)
}

@Test func downloadChunkQueueReturnsChunkWhenYieldResolvesBeforeCancellation() async throws {
    let queue = AsyncDownloadChunkQueue(capacity: 4)
    let begin = QueueCancellationTestGate()
    let consumer = Task { () async throws -> Droidmatch_V1_TransferChunk? in
        await begin.wait()
        return try await queue.next()
    }
    let chunk = queueCancellationTestChunk()

    await begin.open()
    #expect(queue.yield(chunk))
    consumer.cancel()

    #expect(try await consumer.value == chunk)
}

private func queueCancellationTestChunk() -> Droidmatch_V1_TransferChunk {
    var chunk = Droidmatch_V1_TransferChunk()
    chunk.transferID = "queue-cancellation"
    chunk.offsetBytes = 0
    chunk.data = Data([0x01, 0x02, 0x03])
    chunk.crc32 = Crc32.checksum(chunk.data)
    chunk.finalChunk = true
    return chunk
}

private actor QueueCancellationTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}
