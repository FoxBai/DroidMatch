import Foundation
@preconcurrency import Network

public enum AsyncFramedTcpSessionModeError: Error, CustomStringConvertible, Sendable {
    case incompatibleAccessMode
    case multiplexingOwnerMismatch
    case concurrentReceive

    public var description: String {
        switch self {
        case .incompatibleAccessMode:
            return "async framed session cannot mix FIFO round trips with multiplexed I/O"
        case .multiplexingOwnerMismatch:
            return "multiplexed I/O owner does not match the active session owner"
        case .concurrentReceive:
            return "multiplexed sessions require exactly one active frame reader"
        }
    }
}

/// A non-blocking framed TCP session intended for product-facing async code.
///
/// Every product and command-line network path enters through this actor. The
/// former semaphore-based session was deleted after async parity was established.
public actor AsyncFramedTcpSession {
    private enum AccessMode {
        case unclaimed
        case roundTrip
        case multiplexed(UUID)
    }

    private struct OperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let timeoutSeconds: TimeInterval
    private let codec: FrameCodec
    private let reader: FrameReader
    private let queue = DispatchQueue(label: "app.droidmatch.async-framed-tcp-session")
    private let connectionHandle: NetworkConnectionHandle

    private var isClosed = false
    private var accessMode = AccessMode.unclaimed
    private var multiplexedReceiveInProgress = false
    private var operationOwner: UUID?
    private var operationWaiters: [OperationWaiter] = []

    private init(
        connection: NWConnection,
        timeoutSeconds: TimeInterval,
        codec: FrameCodec
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.codec = codec
        self.reader = FrameReader(maxEnvelopeLength: codec.maxEnvelopeLength)
        self.connectionHandle = NetworkConnectionHandle(connection)
    }

    deinit {
        connectionHandle.cancel()
    }

    /// Connects without blocking the caller's cooperative Swift concurrency thread.
    public static func connect(
        host: String = "127.0.0.1",
        port: Int,
        timeoutSeconds: TimeInterval = 5,
        codec: FrameCodec = FrameCodec()
    ) async throws -> AsyncFramedTcpSession {
        guard let portValue = UInt16(exactly: port),
              let nwPort = NWEndpoint.Port(rawValue: portValue) else {
            throw FramedTcpClientError.invalidPort(port)
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let session = AsyncFramedTcpSession(
            connection: connection,
            timeoutSeconds: timeoutSeconds,
            codec: codec
        )
        try await session.start()
        return session
    }

    /// Sends one frame and receives its matching response as one FIFO operation.
    ///
    /// An actor alone is not sufficient here because actors are re-entrant at every
    /// `await`. The explicit operation queue prevents concurrent callers from sending
    /// two requests before either response is consumed.
    public func roundTrip(payload: Data) async throws -> Data {
        // Encoding errors do not touch the connection and therefore must not poison it.
        let frame = try codec.encode(payload: payload)
        try claimRoundTripMode()
        let operationID = UUID()
        try await acquireOperation(operationID)
        defer {
            releaseOperation(operationID)
        }

        guard !isClosed else {
            throw FramedTcpClientError.connectionClosed(stage: "round trip")
        }

        do {
            try Task.checkCancellation()
            try await send(frame)
            return try await receivePayload(timeoutSeconds: timeoutSeconds)
        } catch {
            // A timeout, cancellation, malformed frame, or transport error makes the
            // request/response boundary ambiguous. Do not reuse that TCP session.
            isClosed = true
            connectionHandle.cancel()
            throw error
        }
    }

    public func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        connectionHandle.cancel()
        let waiters = operationWaiters
        operationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.continuation.resume(
                throwing: FramedTcpClientError.connectionClosed(stage: "waiting for I/O lease")
            )
        }
    }

    /// Permanently selects full-duplex framed I/O for one RPC router.
    ///
    /// The UUID is an ownership token, not a credential. It prevents two higher
    /// layers from accidentally starting competing readers on the same byte stream.
    func activateMultiplexing(ownerID: UUID) throws {
        guard !isClosed else {
            throw FramedTcpClientError.connectionClosed(stage: "activating multiplexed I/O")
        }
        switch accessMode {
        case .unclaimed:
            accessMode = .multiplexed(ownerID)
        case let .multiplexed(activeOwner) where activeOwner == ownerID:
            return
        case .multiplexed:
            throw AsyncFramedTcpSessionModeError.multiplexingOwnerMismatch
        case .roundTrip:
            throw AsyncFramedTcpSessionModeError.incompatibleAccessMode
        }
    }

    /// Sends one multiplexed frame. Sends remain FIFO, while the sole reader may
    /// wait independently so control requests can progress during data streaming.
    func sendMultiplexedPayload(_ payload: Data, ownerID: UUID) async throws {
        try requireMultiplexingOwner(ownerID)
        let frame = try codec.encode(payload: payload)
        let operationID = UUID()
        try await acquireOperation(operationID)
        defer { releaseOperation(operationID) }
        guard !isClosed else {
            throw FramedTcpClientError.connectionClosed(stage: "multiplexed send")
        }
        do {
            try Task.checkCancellation()
            try await send(frame)
        } catch {
            isClosed = true
            connectionHandle.cancel()
            throw error
        }
    }

    /// Receives the next multiplexed frame without an idle timeout. Request-level
    /// deadlines belong to the RPC router; an idle persistent connection is not an
    /// ambiguous request/response round trip and must not expire just for silence.
    func receiveMultiplexedPayload(ownerID: UUID) async throws -> Data {
        try requireMultiplexingOwner(ownerID)
        guard !multiplexedReceiveInProgress else {
            throw AsyncFramedTcpSessionModeError.concurrentReceive
        }
        multiplexedReceiveInProgress = true
        defer { multiplexedReceiveInProgress = false }
        do {
            return try await receivePayload(timeoutSeconds: nil)
        } catch {
            isClosed = true
            connectionHandle.cancel()
            throw error
        }
    }

    private func start() async throws {
        let handle = connectionHandle
        let queue = queue
        let _: Void = try await awaitNetworkResult(
            timeoutSeconds: timeoutSeconds,
            stage: "connect",
            timeoutQueue: queue,
            cancel: handle.cancel
        ) { complete in
            handle.connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    complete(.success(()))
                case let .failed(error):
                    // Never publish Network.framework's raw failure text. It is
                    // platform-controlled and may include endpoint details.
                    _ = error
                    complete(.failure(FramedTcpClientError.networkFailure))
                case .cancelled:
                    complete(.failure(FramedTcpClientError.connectionClosed(stage: "connect")))
                default:
                    break
                }
            }
            handle.connection.start(queue: queue)
        }
    }

    private func send(_ data: Data) async throws {
        let handle = connectionHandle
        let _: Void = try await awaitNetworkResult(
            timeoutSeconds: timeoutSeconds,
            stage: "send",
            timeoutQueue: queue,
            cancel: handle.cancel
        ) { complete in
            handle.connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    // Keep transport failures stable and privacy-bounded.
                    _ = error
                    complete(.failure(FramedTcpClientError.networkFailure))
                } else {
                    complete(.success(()))
                }
            })
        }
    }

    private func receivePayload(timeoutSeconds: TimeInterval?) async throws -> Data {
        while true {
            try Task.checkCancellation()
            if let decoded = try reader.decodeNext() {
                return decoded
            }

            let chunk = try await receiveChunk(
                maxLength: codec.maxEnvelopeLength + 4,
                stage: "reading frame header",
                timeoutSeconds: timeoutSeconds
            )
            if !chunk.isEmpty {
                reader.append(chunk)
            }
        }
    }

    private func receiveChunk(
        maxLength: Int,
        stage: String,
        timeoutSeconds: TimeInterval?
    ) async throws -> Data {
        let handle = connectionHandle
        return try await awaitNetworkResult(
            timeoutSeconds: timeoutSeconds,
            stage: stage,
            timeoutQueue: queue,
            cancel: handle.cancel
        ) { complete in
            handle.connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maxLength
            ) { content, _, isComplete, error in
                if let error {
                    // Keep transport failures stable and privacy-bounded.
                    _ = error
                    complete(.failure(FramedTcpClientError.networkFailure))
                } else if let content, !content.isEmpty {
                    complete(.success(content))
                } else if isComplete {
                    complete(.failure(FramedTcpClientError.connectionClosed(stage: stage)))
                } else {
                    complete(.success(Data()))
                }
            }
        }
    }

    private func claimRoundTripMode() throws {
        switch accessMode {
        case .unclaimed:
            accessMode = .roundTrip
        case .roundTrip:
            return
        case .multiplexed:
            throw AsyncFramedTcpSessionModeError.incompatibleAccessMode
        }
    }

    private func requireMultiplexingOwner(_ ownerID: UUID) throws {
        guard !isClosed else {
            throw FramedTcpClientError.connectionClosed(stage: "multiplexed I/O")
        }
        guard case let .multiplexed(activeOwner) = accessMode else {
            throw AsyncFramedTcpSessionModeError.incompatibleAccessMode
        }
        guard activeOwner == ownerID else {
            throw AsyncFramedTcpSessionModeError.multiplexingOwnerMismatch
        }
    }

    private func acquireOperation(_ id: UUID) async throws {
        try Task.checkCancellation()
        guard !isClosed else {
            throw FramedTcpClientError.connectionClosed(stage: "acquiring I/O lease")
        }
        if operationOwner == nil {
            operationOwner = id
            return
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    operationWaiters.append(OperationWaiter(id: id, continuation: continuation))
                }
            } onCancel: { [weak self] in
                Task {
                    await self?.cancelOperationWaiter(id)
                }
            }
            try Task.checkCancellation()
        } catch {
            // Cancellation can race with a waiter being promoted to owner. Release
            // that ownership here because the caller has not installed its defer yet.
            if operationOwner == id {
                releaseOperation(id)
            }
            throw error
        }
    }

    private func cancelOperationWaiter(_ id: UUID) {
        guard let index = operationWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = operationWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseOperation(_ id: UUID) {
        guard operationOwner == id else {
            return
        }
        operationOwner = nil
        guard !operationWaiters.isEmpty else {
            return
        }
        let waiter = operationWaiters.removeFirst()
        operationOwner = waiter.id
        waiter.continuation.resume(returning: ())
    }
}

/// `NWConnection` is thread-safe, but its older callback API is not annotated as
/// `Sendable`. This narrow wrapper documents the single capability callbacks need:
/// operate on and cancel the same connection.
private final class NetworkConnectionHandle: @unchecked Sendable {
    let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func cancel() {
        connection.cancel()
    }
}

/// Resumes a checked continuation exactly once across completion, timeout, and
/// task-cancellation races. Cancellation may arrive before the continuation is
/// installed, so the first result is retained until installation.
private final class AsyncNetworkResultGate<Success: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Success, any Error>?
    private var isResolved = false
    private var pendingResult: Result<Success, any Error>?

    func install(_ continuation: CheckedContinuation<Success, any Error>) -> Bool {
        lock.lock()
        if isResolved {
            let result = pendingResult
            pendingResult = nil
            lock.unlock()
            // A result exists here only when cancellation beat continuation setup.
            guard let result else {
                preconditionFailure("resolved network gate is missing its pending result")
            }
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    @discardableResult
    func resolve(_ result: Result<Success, any Error>) -> Bool {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return false
        }
        isResolved = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}

private func awaitNetworkResult<Success: Sendable>(
    timeoutSeconds: TimeInterval?,
    stage: String,
    timeoutQueue: DispatchQueue,
    cancel: @escaping @Sendable () -> Void,
    start: @escaping @Sendable (
        @escaping @Sendable (Result<Success, any Error>) -> Void
    ) -> Void
) async throws -> Success {
    let gate = AsyncNetworkResultGate<Success>()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            guard gate.install(continuation) else {
                return
            }

            if let timeoutSeconds {
                timeoutQueue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    let error = FramedTcpClientError.timedOut(
                        stage: stage,
                        seconds: timeoutSeconds
                    )
                    if gate.resolve(.failure(error)) {
                        cancel()
                    }
                }
            }
            start { result in
                gate.resolve(result)
            }
        }
    } onCancel: {
        if gate.resolve(.failure(CancellationError())) {
            cancel()
        }
    }
}
