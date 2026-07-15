package app.droidmatch.m1;

import app.droidmatch.proto.v1.RpcEnvelope;

import java.nio.ByteBuffer;
import java.util.zip.CRC32;

/** Pure validation for optional integrity fields on an already-decoded envelope. */
final class RpcEnvelopeValidator {
    private static final int PAYLOAD_CRC32_PRESENT_FLAG = 1 << 0;

    private RpcEnvelopeValidator() {
    }

    static boolean payloadChecksumMatches(RpcEnvelope envelope) {
        if ((envelope.getFlags() & PAYLOAD_CRC32_PRESENT_FLAG) == 0) {
            return true;
        }

        CRC32 checksum = new CRC32();
        // ByteString may be rope-backed. Updating its read-only buffers avoids a
        // second payload-sized allocation on the transfer hot path.
        // 中文：仅在 bit 0 开启时计算，并避免把最多 4 MiB payload 再复制一份。
        for (ByteBuffer buffer : envelope.getPayload().asReadOnlyByteBufferList()) {
            checksum.update(buffer);
        }
        return envelope.getPayloadCrc32() == (int) checksum.getValue();
    }
}
