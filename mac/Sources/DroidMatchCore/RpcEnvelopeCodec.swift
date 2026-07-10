import Foundation
import SwiftProtobuf

public enum RpcEnvelopeCodecError: Error, CustomStringConvertible, Sendable {
    case unsupportedFrameVersion(expected: UInt32, actual: UInt32)
    case payloadChecksumMismatch(expected: UInt32, actual: UInt32)

    public var description: String {
        switch self {
        case let .unsupportedFrameVersion(expected, actual):
            return "unsupported RPC frame version: expected \(expected), got \(actual)"
        case let .payloadChecksumMismatch(expected, actual):
            return "RPC payload checksum mismatch: expected \(expected), got \(actual)"
        }
    }
}

/// Pure construction and validation for the shared RPC envelope.
///
/// Keeping this independent from either synchronous or async transport prevents
/// the two clients from drifting on frame-version, checksum, error, and request-ID
/// rules while the M1 harness migrates incrementally toward product-facing actors.
enum RpcEnvelopeCodec {
    static let frameVersion: UInt32 = 1
    private static let payloadChecksumPresentFlag: UInt32 = 1 << 0

    static func request<Payload: SwiftProtobuf.Message>(
        payload: Payload,
        payloadType: Droidmatch_V1_PayloadType,
        requestID: UInt64
    ) throws -> Droidmatch_V1_RpcEnvelope {
        var envelope = Droidmatch_V1_RpcEnvelope()
        envelope.frameVersion = frameVersion
        envelope.kind = .request
        envelope.requestID = requestID
        envelope.payloadType = payloadType
        envelope.payload = try payload.serializedData()
        return envelope
    }

    static func parse(_ bytes: Data) throws -> Droidmatch_V1_RpcEnvelope {
        let envelope = try Droidmatch_V1_RpcEnvelope(serializedBytes: bytes)
        guard envelope.frameVersion == frameVersion else {
            throw RpcEnvelopeCodecError.unsupportedFrameVersion(
                expected: frameVersion,
                actual: envelope.frameVersion
            )
        }

        if envelope.flags & payloadChecksumPresentFlag != 0 {
            let actualChecksum = Crc32.checksum(envelope.payload)
            guard actualChecksum == envelope.payloadCrc32 else {
                throw RpcEnvelopeCodecError.payloadChecksumMismatch(
                    expected: envelope.payloadCrc32,
                    actual: actualChecksum
                )
            }
        }
        return envelope
    }

    static func response(
        from bytes: Data,
        requestID: UInt64,
        expectedPayloadType: Droidmatch_V1_PayloadType
    ) throws -> Droidmatch_V1_RpcEnvelope {
        let response = try parse(bytes)
        guard response.requestID == requestID else {
            throw RpcControlClientError.requestIDMismatch(
                expected: requestID,
                actual: response.requestID
            )
        }
        if response.kind == .error {
            throw RpcControlClientError.remoteError(try errorPayload(from: response))
        }
        guard response.kind == .response, response.payloadType == expectedPayloadType else {
            throw RpcControlClientError.unexpectedEnvelope(
                kind: response.kind,
                payloadType: response.payloadType
            )
        }
        return response
    }

    static func errorPayload(
        from envelope: Droidmatch_V1_RpcEnvelope
    ) throws -> Droidmatch_V1_DroidMatchError {
        if envelope.hasError {
            return envelope.error
        }
        if envelope.payload.isEmpty {
            var error = Droidmatch_V1_DroidMatchError()
            error.code = .protocolError
            error.message = "remote returned error envelope without payload"
            return error
        }
        return try Droidmatch_V1_DroidMatchError(serializedBytes: envelope.payload)
    }
}
