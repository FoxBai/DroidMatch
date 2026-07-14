import Foundation

/// Actor-confined ownership for one product session's transfer scheduler.
///
/// The enclosing session coordinator still validates its authentication
/// generation and performs asynchronous cleanup. This value makes the related
/// synchronous transitions identity-guarded: an old in-flight build cannot
/// clear the retry-client gate or scheduler published by a replacement build.
/// 中文：会话 actor 仍负责 generation 与异步释放；此值原子管理单飞构建、
/// retry gate 和已发布 scheduler，避免旧构建清除新会话资源。
struct ProductTransferSchedulerLifecycle {
    struct Build {
        let id: UUID
        let generation: UInt64
        let task: Task<AsyncTransferScheduler, Error>
    }

    struct DetachedResources {
        let gate: ProductTransferSessionGate?
        let scheduler: AsyncTransferScheduler?
        let buildTask: Task<AsyncTransferScheduler, Error>?
    }

    private(set) var gate: ProductTransferSessionGate?
    private(set) var scheduler: AsyncTransferScheduler?
    private(set) var build: Build?

    func build(for generation: UInt64) -> Build? {
        guard build?.generation == generation else { return nil }
        return build
    }

    mutating func installTransient(
        gate: ProductTransferSessionGate,
        scheduler: AsyncTransferScheduler
    ) throws {
        guard self.gate == nil, self.scheduler == nil, build == nil else {
            throw CancellationError()
        }
        self.gate = gate
        self.scheduler = scheduler
    }

    mutating func beginBuild(
        id: UUID,
        generation: UInt64,
        task: Task<AsyncTransferScheduler, Error>
    ) throws -> Build {
        guard gate == nil, scheduler == nil, build == nil else {
            throw CancellationError()
        }
        let build = Build(id: id, generation: generation, task: task)
        self.build = build
        return build
    }

    func requireBuild(id: UUID) throws {
        guard build?.id == id else { throw CancellationError() }
    }

    mutating func publishGate(
        _ gate: ProductTransferSessionGate,
        buildID: UUID
    ) throws {
        try requireBuild(id: buildID)
        guard self.gate == nil else { throw CancellationError() }
        self.gate = gate
    }

    mutating func publishScheduler(
        _ scheduler: AsyncTransferScheduler,
        buildID: UUID
    ) throws {
        try requireBuild(id: buildID)
        guard self.scheduler == nil else { throw CancellationError() }
        self.scheduler = scheduler
    }

    func requirePublished(_ scheduler: AsyncTransferScheduler) throws {
        guard self.scheduler === scheduler else { throw CancellationError() }
    }

    mutating func clearBuild(id: UUID) {
        if build?.id == id { build = nil }
    }

    mutating func clearGateIfOwned(
        _ gate: ProductTransferSessionGate,
        buildID: UUID
    ) {
        guard build?.id == buildID, self.gate === gate else { return }
        self.gate = nil
    }

    /// Clears only resources published by the named build. The caller still
    /// invalidates/suspends the supplied resources even if ownership moved on.
    mutating func discardPublishedResources(
        scheduler: AsyncTransferScheduler,
        gate: ProductTransferSessionGate,
        buildID: UUID
    ) {
        guard build?.id == buildID else { return }
        if self.scheduler === scheduler { self.scheduler = nil }
        if self.gate === gate { self.gate = nil }
    }

    mutating func detach() -> DetachedResources {
        let resources = DetachedResources(
            gate: gate,
            scheduler: scheduler,
            buildTask: build?.task
        )
        gate = nil
        scheduler = nil
        build = nil
        return resources
    }
}
