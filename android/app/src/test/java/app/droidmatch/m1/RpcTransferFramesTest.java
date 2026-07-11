package app.droidmatch.m1;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.TransferChunk;

import java.nio.charset.StandardCharsets;

import org.junit.Test;

public final class RpcTransferFramesTest {
    @Test
    public void negotiatedChunkSizeDefaultsAndClampsUnsignedInput() {
        assertEquals(256 * 1024, RpcTransferFrames.negotiatedChunkSize(0));
        assertEquals(512, RpcTransferFrames.negotiatedChunkSize(512));
        assertEquals(1024 * 1024, RpcTransferFrames.negotiatedChunkSize(2 * 1024 * 1024));
        assertEquals(1024 * 1024, RpcTransferFrames.negotiatedChunkSize(-1));
    }

    @Test
    public void transferChunkCopiesPayloadAndOwnsChecksumAndFinalFlag() {
        byte[] data = "abc".getBytes(StandardCharsets.UTF_8);
        TransferChunk chunk = RpcTransferFrames.transferChunk(
                "transfer-1",
                7,
                new DmFileProvider.DownloadChunk(data, 10, 20, "etag", true)
        );

        data[0] = 'z';
        assertEquals("transfer-1", chunk.getTransferId());
        assertEquals(7, chunk.getOffsetBytes());
        assertArrayEquals("abc".getBytes(StandardCharsets.UTF_8), chunk.getData().toByteArray());
        assertEquals(0x352441c2, chunk.getCrc32());
        assertTrue(chunk.getFinalChunk());
    }

    @Test
    public void errorEnvelopeUsesStableWireMetadataAndNormalizesNullMessage() {
        RpcEnvelope envelope = RpcTransferFrames.errorEnvelope(
                42,
                ErrorCode.ERROR_CODE_PROTOCOL_ERROR,
                null
        );

        assertEquals(RpcDispatcher.FRAME_VERSION, envelope.getFrameVersion());
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_ERROR, envelope.getKind());
        assertEquals(42, envelope.getRequestId());
        assertEquals(PayloadType.PAYLOAD_TYPE_DROIDMATCH_ERROR, envelope.getPayloadType());
        assertEquals(ErrorCode.ERROR_CODE_PROTOCOL_ERROR, envelope.getError().getCode());
        assertEquals("", envelope.getError().getMessage());
    }
}
