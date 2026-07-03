import Foundation

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        self.storedValue = value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        storedValue = newValue
    }

    func update(_ body: (inout Value) throws -> Void) rethrows {
        lock.lock()
        defer { lock.unlock() }
        try body(&storedValue)
    }

    func value() -> Value {
        lock.lock()
        defer { lock.unlock() }
        let current = storedValue
        return current
    }
}
