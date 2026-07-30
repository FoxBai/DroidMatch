package app.droidmatch.m1;

/** Numeric limits shared by the framed RPC and transfer data plane. */
final class RpcWireLimits {
    static final int MAX_ENVELOPE_LENGTH_BYTES = 4 * 1024 * 1024;
    static final int DEFAULT_TRANSFER_CHUNK_SIZE_BYTES = 256 * 1024;
    static final int MAX_TRANSFER_CHUNK_SIZE_BYTES = 1024 * 1024;
    static final int MAX_TRANSFER_IN_FLIGHT_CHUNKS = 4;
    static final int MAX_TRANSFER_IN_FLIGHT_BYTES = 2 * 1024 * 1024;

    private RpcWireLimits() {
    }
}
