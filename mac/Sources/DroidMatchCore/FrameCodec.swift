import Foundation

public enum FrameCodecError: Error, Equatable, Sendable {
    case emptyFrame
    case invalidMaximumEnvelopeLength(Int)
    case frameTooLarge(Int)
}

public struct FrameCodec: Sendable {
    public static let defaultMaxEnvelopeLength = RpcWireLimits.maximumEnvelopeLengthBytes

    public let maxEnvelopeLength: Int

    public init(maxEnvelopeLength: Int = Self.defaultMaxEnvelopeLength) {
        self.maxEnvelopeLength = maxEnvelopeLength
    }

    func validateConfiguration() throws {
        _ = try Self.validatedMaximumEnvelopeLength(maxEnvelopeLength).get()
    }

    public func encode(payload: Data) throws -> Data {
        let validatedMaximum = try Self.validatedMaximumEnvelopeLength(
            maxEnvelopeLength
        ).get()
        guard !payload.isEmpty else {
            throw FrameCodecError.emptyFrame
        }
        guard payload.count <= validatedMaximum else {
            throw FrameCodecError.frameTooLarge(payload.count)
        }

        var length = UInt32(payload.count).bigEndian
        var frame = Data()
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    public func decodeNext(from buffer: inout Data) throws -> Data? {
        let validatedMaximum = try Self.validatedMaximumEnvelopeLength(
            maxEnvelopeLength
        ).get()
        guard buffer.count >= 4 else {
            return nil
        }

        let length = buffer.prefix(4).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }

        guard length > 0 else {
            throw FrameCodecError.emptyFrame
        }
        guard Int(length) <= validatedMaximum else {
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

    static func validatedMaximumEnvelopeLength(
        _ configuredMaximum: Int
    ) -> Result<Int, FrameCodecError> {
        guard configuredMaximum > 0,
              configuredMaximum <= RpcWireLimits.maximumEnvelopeLengthBytes else {
            return .failure(.invalidMaximumEnvelopeLength(configuredMaximum))
        }
        // The override can tighten the production limit for tests or a stricter
        // caller, but it cannot widen the documented M1 admission boundary.
        return .success(configuredMaximum)
    }
}
