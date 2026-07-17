import Foundation

enum AsyncRpcOneShotCancellationPolicy: Sendable {
    /// Task cancellation remains authoritative even when a success raced just
    /// ahead of the cancellation handler. This is the conservative RPC default.
    case cancellationWins

    /// Whichever result resolves the one-shot first owns the value. Consumable
    /// queue elements use this policy so a late cancellation cannot discard an
    /// element that has already left its buffer.
    case firstResolutionWins
}

enum AsyncRpcOneShotStateError: Error, Sendable, Equatable {
    case waitAlreadyClaimed
    case missingResolvedValue
}

/// Lock-backed one-shot used at the callback/async boundary.
///
/// The RPC reader can resolve a response before the sending task starts
/// waiting. Holding either the continuation or one pending result closes that
/// race without creating a second reader or blocking a cooperative executor.
final class AsyncRpcOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pendingResult: Result<Value, any Error>?
    private var resolved = false
    private var waitClaimed = false

    func wait(
        cancellationPolicy: AsyncRpcOneShotCancellationPolicy = .cancellationWins,
        onCancel: @escaping @Sendable () -> Void
    ) async throws -> Value {
        let claimed = lock.withLock { () -> Bool in
            guard !waitClaimed else { return false }
            waitClaimed = true
            return true
        }
        guard claimed else {
            throw AsyncRpcOneShotStateError.waitAlreadyClaimed
        }

        if case .cancellationWins = cancellationPolicy, Task.isCancelled {
            if resolve(.failure(CancellationError())) {
                onCancel()
            }
            throw CancellationError()
        }
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if resolved {
                    let result = pendingResult
                    pendingResult = nil
                    lock.unlock()
                    if let result {
                        continuation.resume(with: result)
                    } else {
                        continuation.resume(
                            throwing: AsyncRpcOneShotStateError.missingResolvedValue
                        )
                    }
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            if self.resolve(.failure(CancellationError())) {
                onCancel()
            }
        }
        if case .cancellationWins = cancellationPolicy {
            try Task.checkCancellation()
        }
        return value
    }

    @discardableResult
    func resolve(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
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
