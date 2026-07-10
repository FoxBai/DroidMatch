import Foundation

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

    func wait(onCancel: @escaping @Sendable () -> Void) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if resolved {
                    let result = pendingResult
                    pendingResult = nil
                    lock.unlock()
                    guard let result else {
                        preconditionFailure("resolved RPC waiter is missing its result")
                    }
                    continuation.resume(with: result)
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
