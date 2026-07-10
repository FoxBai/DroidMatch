/// Shared RPC validation errors used by both async product paths and legacy probes.
///
/// The historical type name remains source-compatible, but its ownership is no
/// longer tied to `RpcControlClient` or the synchronous transport implementation.
public enum RpcControlClientError: Error, CustomStringConvertible, Sendable {
    case remoteError(Droidmatch_V1_DroidMatchError)
    case requestIDMismatch(expected: UInt64, actual: UInt64)
    case streamIDMismatch(expected: UInt64, actual: UInt64)
    case transferIDMismatch(expected: String, actual: String)
    case offsetMismatch(expected: Int64, actual: Int64)
    case unexpectedEnvelope(kind: Droidmatch_V1_RpcFrameKind, payloadType: Droidmatch_V1_PayloadType)
    case checksumMismatch(expected: UInt32, actual: UInt32)
    case invalidTransferState(String)

    public var description: String {
        switch self {
        case let .remoteError(error):
            return "remote error \(error.code): \(error.message)"
        case let .requestIDMismatch(expected, actual):
            return "response request_id mismatch: expected \(expected), got \(actual)"
        case let .streamIDMismatch(expected, actual):
            return "stream_id mismatch: expected \(expected), got \(actual)"
        case let .transferIDMismatch(expected, actual):
            return "transfer_id mismatch: expected \(expected), got \(actual)"
        case let .offsetMismatch(expected, actual):
            return "transfer chunk offset mismatch: expected \(expected), got \(actual)"
        case let .unexpectedEnvelope(kind, payloadType):
            return "unexpected response envelope: kind=\(kind) payload_type=\(payloadType)"
        case let .checksumMismatch(expected, actual):
            return "transfer chunk checksum mismatch: expected \(expected), got \(actual)"
        case let .invalidTransferState(message):
            return message
        }
    }
}
