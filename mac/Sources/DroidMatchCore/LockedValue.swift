import Foundation

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        self.storedValue = value
    }

    func set(_ newValue: Value) {
        lock.lock()
        storedValue = newValue
        lock.unlock()
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storedValue)
        lock.unlock()
    }

    func value() -> Value {
        lock.lock()
        let current = storedValue
        lock.unlock()
        return current
    }
}
