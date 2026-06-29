import Foundation

public final class FrameReader {
    private var buffer = Data()
    private var cursor = 0
    private var poisonError: FrameCodecError?
    private let maxEnvelopeLength: Int
    private let compactThreshold: Int

    /// Stateful streaming reader. Calls must be serialized by the transport owner.
    public init(
        maxEnvelopeLength: Int = FrameCodec.defaultMaxEnvelopeLength,
        compactThreshold: Int = FrameCodec.defaultMaxEnvelopeLength
    ) {
        self.maxEnvelopeLength = maxEnvelopeLength
        self.compactThreshold = compactThreshold
    }

    public func append(_ data: Data) {
        buffer.append(data)
    }

    public func decodeNext() throws -> Data? {
        if let poisonError {
            throw poisonError
        }

        guard buffer.count - cursor >= 4 else {
            return nil
        }

        let length = (UInt32(buffer[cursor]) << 24)
            | (UInt32(buffer[cursor + 1]) << 16)
            | (UInt32(buffer[cursor + 2]) << 8)
            | UInt32(buffer[cursor + 3])

        guard length > 0 else {
            return try poison(.emptyFrame)
        }
        guard length <= UInt32(maxEnvelopeLength) else {
            return try poison(.frameTooLarge(Int(length)))
        }

        let frameLength = 4 + Int(length)
        guard buffer.count - cursor >= frameLength else {
            return nil
        }

        let payloadStart = cursor + 4
        let payloadEnd = cursor + frameLength
        let payload = buffer.subdata(in: payloadStart..<payloadEnd)
        cursor += frameLength
        compactIfNeeded()
        return payload
    }

    public func clear() {
        buffer.removeAll(keepingCapacity: true)
        cursor = 0
        poisonError = nil
    }

    private func poison(_ error: FrameCodecError) throws -> Data? {
        poisonError = error
        throw error
    }

    private func compactIfNeeded() {
        guard cursor > 0 else {
            return
        }

        if cursor >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
            cursor = 0
        } else if cursor >= compactThreshold {
            buffer.removeSubrange(0..<cursor)
            cursor = 0
        }
    }
}
