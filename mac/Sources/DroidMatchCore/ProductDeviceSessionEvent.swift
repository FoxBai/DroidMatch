import Foundation

/// A privacy-bounded terminal event for one authenticated product session.
///
/// Core publishes this only after the affected session resources are detached
/// and released. Presentation can therefore leave ready state without learning
/// transport details or racing a second teardown against a replacement session.
public enum ProductDeviceSessionEvent: Sendable, Equatable {
    case connectionUnavailable
}

/// Session-scoped fan-out with one cached terminal event.
///
/// Authentication can finish before Presentation installs its observer. Caching
/// the terminal event closes that gap, while `finish()` lets explicit disconnect
/// and replacement end old observers without presenting a connection failure.
final class ProductDeviceSessionEventChannel: @unchecked Sendable {
    private struct State {
        var terminalEvent: ProductDeviceSessionEvent?
        var isFinished = false
        var continuations:
            [UUID: AsyncStream<ProductDeviceSessionEvent>.Continuation] = [:]
    }

    private enum Registration {
        case open
        case terminal(ProductDeviceSessionEvent)
        case finished
    }

    private let state = LockedValue(State())

    func stream() -> AsyncStream<ProductDeviceSessionEvent> {
        let pair = AsyncStream<ProductDeviceSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let observerID = UUID()
        let registration = state.withLock { state in
            if let terminalEvent = state.terminalEvent {
                return Registration.terminal(terminalEvent)
            }
            guard !state.isFinished else { return .finished }
            state.continuations[observerID] = pair.continuation
            return .open
        }
        switch registration {
        case let .terminal(terminalEvent):
            pair.continuation.yield(terminalEvent)
            pair.continuation.finish()
        case .finished:
            pair.continuation.finish()
        case .open:
            pair.continuation.onTermination = { [weak self] _ in
                self?.removeObserver(observerID)
            }
        }
        return pair.stream
    }

    func sendTerminal(_ event: ProductDeviceSessionEvent) {
        let continuations: [AsyncStream<ProductDeviceSessionEvent>.Continuation] =
            state.withLock { state in
                guard state.terminalEvent == nil, !state.isFinished else { return [] }
                state.terminalEvent = event
                let continuations = Array(state.continuations.values)
                state.continuations.removeAll()
                return continuations
            }
        for continuation in continuations {
            continuation.yield(event)
            continuation.finish()
        }
    }

    func finish() {
        let continuations: [AsyncStream<ProductDeviceSessionEvent>.Continuation] =
            state.withLock { state in
                guard state.terminalEvent == nil, !state.isFinished else { return [] }
                state.isFinished = true
                let continuations = Array(state.continuations.values)
                state.continuations.removeAll()
                return continuations
            }
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func removeObserver(_ observerID: UUID) {
        _ = state.withLock { $0.continuations.removeValue(forKey: observerID) }
    }
}
