import Foundation

public enum FrameCodecError: Error, Equatable, Sendable {
    case emptyFrame
    case frameTooLarge(Int)
}

public struct FrameCodec: Sendable {
    public static let defaultMaxEnvelopeLength = 4 * 1024 * 1024

    public let maxEnvelopeLength: Int

    public init(maxEnvelopeLength: Int = Self.defaultMaxEnvelopeLength) {
        self.maxEnvelopeLength = maxEnvelopeLength
    }

    public func encode(payload: Data) throws -> Data {
        guard !payload.isEmpty else {
            throw FrameCodecError.emptyFrame
        }
        guard payload.count <= maxEnvelopeLength else {
            throw FrameCodecError.frameTooLarge(payload.count)
        }

        var length = UInt32(payload.count).bigEndian
        var frame = Data()
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    public func decodeNext(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else {
            return nil
        }

        let length = buffer.prefix(4).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }

        guard length > 0 else {
            throw FrameCodecError.emptyFrame
        }
        guard length <= UInt32(maxEnvelopeLength) else {
            throw FrameCodecError.frameTooLarge(Int(length))
        }

        let frameLength = 4 + Int(length)
        guard buffer.count >= frameLength else {
            return nil
        }

        let payload = buffer.subdata(in: 4..<frameLength)
        buffer.removeSubrange(0..<frameLength)
        return payload
    }
}
