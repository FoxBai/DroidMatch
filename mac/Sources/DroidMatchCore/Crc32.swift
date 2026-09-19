import Foundation

public enum Crc32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            if value & 1 == 1 {
                value = 0xedb88320 ^ (value >> 1)
            } else {
                value >>= 1
            }
        }
        return value
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var accumulator = Accumulator()
        accumulator.update(data)
        return accumulator.checksum
    }

    public struct Accumulator: Sendable {
        private var state: UInt32 = 0xffffffff
        public init() {}
        public mutating func update(_ data: Data) {
            for byte in data {
                let index = Int((state ^ UInt32(byte)) & 0xff)
                state = Crc32.table[index] ^ (state >> 8)
            }
        }
        public var checksum: UInt32 { state ^ 0xffffffff }
    }
}
