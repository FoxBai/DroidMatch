/// Numeric limits shared by the framed RPC and transfer data plane.
///
/// These values are part of the documented M1 wire contract. Keep the Android
/// mirror and `docs/protocol*.md` aligned through `tools/check-wire-limits.py`.
public enum RpcWireLimits {
    public static let maximumEnvelopeLengthBytes = 4 * 1024 * 1024
    public static let defaultTransferChunkSizeBytes: UInt32 = 256 * 1024
    public static let maximumTransferChunkSizeBytes = 1024 * 1024
    public static let maximumTransferInFlightChunks = 4
    public static let maximumTransferInFlightBytes = 2 * 1024 * 1024
}
