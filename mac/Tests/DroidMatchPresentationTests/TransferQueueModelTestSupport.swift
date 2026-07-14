@testable import DroidMatchCore
import DroidMatchPresentation
import Foundation
import Testing

// Shared test-target probes keep synchronization and fixture semantics identical across suites.
// 中文：共享测试 target probe 统一同步与 fixture 语义，行为套件不各自复制时序状态。

actor TransferQueueDataSourceProbe: TransferQueueDataSource {
    enum Action: Equatable, Sendable {
        case submitDownload(String, String, String?)
        case submitUpload(String, String)
        case pause(UUID)
        case resume(UUID)
        case cancel(UUID)
        case remove(UUID)
        case retryPersistence
    }

    private var subscriptionNumber = 0
    private var continuations: [Int: AsyncStream<[AsyncTransferJobSnapshot]>.Continuation] = [:]
    private var actions: [Action] = []
    private var currentPersistenceStatus: AsyncTransferQueuePersistenceStatus = .healthy
    private var rejectsNextSubmissionWithPersistenceFailure = false
    private var failsPersistenceAfterNextMutation = false
    private var blocksNextPersistenceStatusRead = false
    private var persistenceStatusReadBlocked = false

    func updates() async -> AsyncStream<[AsyncTransferJobSnapshot]> {
        subscriptionNumber += 1
        let number = subscriptionNumber
        let pair = AsyncStream<[AsyncTransferJobSnapshot]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[number] = pair.continuation
        return pair.stream
    }

    func persistenceStatus() async -> AsyncTransferQueuePersistenceStatus {
        let capturedStatus = currentPersistenceStatus
        if blocksNextPersistenceStatusRead {
            blocksNextPersistenceStatusRead = false
            persistenceStatusReadBlocked = true
            while persistenceStatusReadBlocked {
                await Task.yield()
            }
        }
        return capturedStatus
    }

    func setPersistenceStatus(_ status: AsyncTransferQueuePersistenceStatus) {
        currentPersistenceStatus = status
    }

    func rejectNextSubmissionWithPersistenceFailure() {
        rejectsNextSubmissionWithPersistenceFailure = true
    }

    func failPersistenceAfterNextMutation() {
        failsPersistenceAfterNextMutation = true
    }

    func blockNextPersistenceStatusRead() {
        blocksNextPersistenceStatusRead = true
    }

    func isPersistenceStatusReadBlocked() -> Bool {
        persistenceStatusReadBlocked
    }

    func releaseBlockedPersistenceRead() {
        persistenceStatusReadBlocked = false
    }

    func retryPersistence() -> Bool {
        actions.append(.retryPersistence)
        currentPersistenceStatus = .healthy
        return true
    }

    func submitDownload(
        sourcePath: String,
        destinationURL: URL,
        authorizationURL: URL?
    ) -> UUID? {
        actions.append(.submitDownload(
            sourcePath,
            destinationURL.path,
            authorizationURL?.path
        ))
        if rejectsNextSubmissionWithPersistenceFailure {
            rejectsNextSubmissionWithPersistenceFailure = false
            currentPersistenceStatus = .writeFailed
            return nil
        }
        return UUID()
    }

    func submitUpload(sourceURL: URL, directoryPath: String) -> UUID? {
        actions.append(.submitUpload(sourceURL.path, directoryPath))
        if rejectsNextSubmissionWithPersistenceFailure {
            rejectsNextSubmissionWithPersistenceFailure = false
            currentPersistenceStatus = .writeFailed
            return nil
        }
        return UUID()
    }

    func pause(_ id: UUID) async -> Bool {
        actions.append(.pause(id))
        failPersistenceIfRequested()
        return true
    }

    func resume(_ id: UUID) async -> Bool {
        actions.append(.resume(id))
        failPersistenceIfRequested()
        return true
    }

    func cancel(_ id: UUID) async -> Bool {
        actions.append(.cancel(id))
        failPersistenceIfRequested()
        return true
    }

    func remove(_ id: UUID) async -> Bool {
        actions.append(.remove(id))
        failPersistenceIfRequested()
        return true
    }

    private func failPersistenceIfRequested() {
        if failsPersistenceAfterNextMutation {
            failsPersistenceAfterNextMutation = false
            currentPersistenceStatus = .writeFailed
        }
    }

    func count() -> Int {
        subscriptionNumber
    }

    func yield(_ snapshots: [AsyncTransferJobSnapshot], to subscription: Int) {
        continuations[subscription]?.yield(snapshots)
    }

    func finish(subscription: Int) {
        continuations[subscription]?.finish()
    }

    func recordedActions() -> [Action] {
        actions
    }
}

enum PresentationTestError: Error {
    case expectedFailure
}

enum QueueMutationProbe: CaseIterable {
    case pause
    case resume
    case cancel
    case remove
}

func makeSnapshot(
    id: UUID = UUID(),
    kind: AsyncTransferJobKind = .download,
    state: AsyncTransferJobState = .running,
    source: String = "dm://app-sandbox/source.bin",
    destination: String = "/tmp/destination.bin",
    failureDescription: String? = nil,
    canPause: Bool = false,
    canResume: Bool = false,
    canCancel: Bool = true,
    canRemove: Bool = false
) -> AsyncTransferJobSnapshot {
    AsyncTransferJobSnapshot(
        id: id,
        kind: kind,
        state: state,
        source: source,
        destination: destination,
        attemptNumber: 2,
        confirmedBytes: 4,
        totalBytes: 10,
        recentBytesPerSecond: 2,
        retryDelayMilliseconds: state == .retrying ? 250 : nil,
        failureDescription: failureDescription,
        canPause: canPause,
        canResume: canResume,
        canCancel: canCancel,
        canRemove: canRemove
    )
}

func waitForSubscriptionCount(
    _ source: TransferQueueDataSourceProbe,
    expected: Int
) async -> Bool {
    for _ in 0..<200 {
        if await source.count() == expected { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

func waitForBlockedPersistenceRead(
    _ source: TransferQueueDataSourceProbe
) async -> Bool {
    for _ in 0..<200 {
        if await source.isPersistenceStatusReadBlocked() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@MainActor
func waitForItems(
    _ model: TransferQueueModel,
    matching predicate: ([TransferQueuePresentationItem]) -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if predicate(model.items) { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@MainActor
func waitForPersistenceStatus(
    _ model: TransferQueueModel,
    _ expected: AsyncTransferQueuePersistenceStatus
) async -> Bool {
    for _ in 0..<200 {
        if model.persistenceStatus == expected { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@MainActor
func waitForObservationToEnd(_ model: TransferQueueModel) async -> Bool {
    for _ in 0..<200 {
        if !model.isObserving { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}
