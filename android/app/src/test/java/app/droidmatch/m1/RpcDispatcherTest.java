package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.TransferChunkAck;

import org.junit.Test;

public final class RpcDispatcherTest {
    @Test
    public void transferAckRejectsReservedZeroStreamId() throws Exception {
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                null,
                null
        );
        TransferChunkAck ack = TransferChunkAck.newBuilder()
                .setTransferId("loopback-transfer")
                .setNextOffsetBytes(1)
                .build();
        RpcEnvelope request = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_STREAM)
                .setRequestId(9)
                .setStreamId(0)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK)
                .setPayload(ack.toByteString())
                .build();

        RpcEnvelope[] responses = dispatcher.dispatchForTest(request.toByteArray(), true, 1);

        assertEquals(1, responses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_ERROR, responses[0].getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_DROIDMATCH_ERROR, responses[0].getPayloadType());
        assertEquals(ErrorCode.ERROR_CODE_PROTOCOL_ERROR, responses[0].getError().getCode());
        assertEquals("stream_id must be non-zero for transfer acknowledgements", responses[0].getError().getMessage());
    }
}
