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
        var crc: UInt32 = 0xffffffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }
}
