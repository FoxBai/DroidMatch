@testable import DroidMatchCore
import Foundation
import Testing

@Test func transferSchedulerLifecycleLooksUpOnlyTheMatchingGeneration() throws {
    var lifecycle = ProductTransferSchedulerLifecycle()
    let scheduler = transferLifecycleScheduler()
    let buildID = UUID()
    let task = transferLifecycleBuildTask(returning: scheduler)

    let build = try lifecycle.beginBuild(id: buildID, generation: 7, task: task)

    #expect(build.id == buildID)
    #expect(lifecycle.build(for: 7)?.id == buildID)
    #expect(lifecycle.build(for: 8) == nil)
    lifecycle.clearBuild(id: UUID())
    #expect(lifecycle.build(for: 7)?.id == buildID)
    lifecycle.clearBuild(id: buildID)
    #expect(lifecycle.build == nil)
}

@Test func transferSchedulerLifecyclePublishesOnlyThroughTheCurrentBuild() throws {
    var lifecycle = ProductTransferSchedulerLifecycle()
    let scheduler = transferLifecycleScheduler()
    let gate = try transferLifecycleGate(marker: 0x11)
    let buildID = UUID()

    #expect(throws: CancellationError.self) {
        try lifecycle.publishGate(gate, buildID: buildID)
    }
    _ = try lifecycle.beginBuild(
        id: buildID,
        generation: 1,
        task: transferLifecycleBuildTask(returning: scheduler)
    )
    try lifecycle.publishGate(gate, buildID: buildID)
    try lifecycle.publishScheduler(scheduler, buildID: buildID)

    #expect(lifecycle.gate === gate)
    #expect(lifecycle.scheduler === scheduler)
    #expect(throws: CancellationError.self) {
        try lifecycle.publishScheduler(
            transferLifecycleScheduler(),
            buildID: buildID
        )
    }
}

@Test func staleTransferSchedulerBuildCannotClearReplacementResources() throws {
    var lifecycle = ProductTransferSchedulerLifecycle()
    let staleScheduler = transferLifecycleScheduler()
    let staleGate = try transferLifecycleGate(marker: 0x21)
    let staleBuildID = UUID()
    _ = try lifecycle.beginBuild(
        id: staleBuildID,
        generation: 1,
        task: transferLifecycleBuildTask(returning: staleScheduler)
    )
    try lifecycle.publishGate(staleGate, buildID: staleBuildID)
    try lifecycle.publishScheduler(staleScheduler, buildID: staleBuildID)
    _ = lifecycle.detach()

    let replacementScheduler = transferLifecycleScheduler()
    let replacementGate = try transferLifecycleGate(marker: 0x22)
    let replacementBuildID = UUID()
    _ = try lifecycle.beginBuild(
        id: replacementBuildID,
        generation: 2,
        task: transferLifecycleBuildTask(returning: replacementScheduler)
    )
    try lifecycle.publishGate(replacementGate, buildID: replacementBuildID)
    try lifecycle.publishScheduler(replacementScheduler, buildID: replacementBuildID)

    lifecycle.discardPublishedResources(
        scheduler: staleScheduler,
        gate: staleGate,
        buildID: staleBuildID
    )
    lifecycle.clearGateIfOwned(staleGate, buildID: staleBuildID)

    #expect(lifecycle.build?.id == replacementBuildID)
    #expect(lifecycle.gate === replacementGate)
    #expect(lifecycle.scheduler === replacementScheduler)
}

@Test func transferSchedulerLifecycleDetachesOneCompleteResourceSet() throws {
    var lifecycle = ProductTransferSchedulerLifecycle()
    let scheduler = transferLifecycleScheduler()
    let gate = try transferLifecycleGate(marker: 0x31)
    let buildID = UUID()
    let task = transferLifecycleBuildTask(returning: scheduler)
    _ = try lifecycle.beginBuild(id: buildID, generation: 3, task: task)
    try lifecycle.publishGate(gate, buildID: buildID)
    try lifecycle.publishScheduler(scheduler, buildID: buildID)

    let resources = lifecycle.detach()

    #expect(resources.gate === gate)
    #expect(resources.scheduler === scheduler)
    #expect(resources.buildTask != nil)
    #expect(lifecycle.gate == nil)
    #expect(lifecycle.scheduler == nil)
    #expect(lifecycle.build == nil)
}

private func transferLifecycleBuildTask(
    returning scheduler: AsyncTransferScheduler
) -> Task<AsyncTransferScheduler, Error> {
    Task {
        try Task.checkCancellation()
        return scheduler
    }
}

private func transferLifecycleScheduler() -> AsyncTransferScheduler {
    AsyncTransferScheduler(
        maxConcurrentJobs: 1,
        downloadExecutor: { _, _, _ in throw CancellationError() },
        uploadExecutor: { _, _, _ in throw CancellationError() }
    )
}

private func transferLifecycleGate(marker: UInt8) throws -> ProductTransferSessionGate {
    let credentials = try PairingCredentials(
        pairingID: Data(repeating: marker, count: SessionAuthenticator.pairingIDLength),
        pairingKey: Data(repeating: marker, count: SessionAuthenticator.pairingKeyLength),
        deviceIdentityFingerprint: Data(
            repeating: marker,
            count: PairingAuthenticator.digestLength
        )
    )
    return ProductTransferSessionGate(
        lease: DeviceConnectionLease(
            deviceID: UUID(),
            host: "127.0.0.1",
            port: Int(marker) + 1
        ),
        credentials: credentials,
        sessionConnector: { _, _, _ in throw CancellationError() }
    )
}
