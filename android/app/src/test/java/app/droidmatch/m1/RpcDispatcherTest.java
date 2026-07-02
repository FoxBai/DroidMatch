package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.HeartbeatRequest;
import app.droidmatch.proto.v1.HeartbeatResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.TransferChunkAck;

import org.junit.Test;

public final class RpcDispatcherTest {
    @Test
    public void heartbeatRoundTripsMonotonicMillisAfterHandshake() throws Exception {
        DiagnosticsReporter reporter = new DiagnosticsReporter(() -> 1L, () -> "test-thread");
        RpcDispatcher dispatcher = new RpcDispatcher(
                reporter,
                null,
                null,
                null
        );
        HeartbeatRequest heartbeat = HeartbeatRequest.newBuilder()
                .setMonotonicMillis(123456789L)
                .build();
        RpcEnvelope request = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(7)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_HEARTBEAT_REQUEST)
                .setPayload(heartbeat.toByteString())
                .build();

        RpcEnvelope[] responses = dispatcher.dispatchForTest(request.toByteArray(), true, 1);

        assertEquals(1, responses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_RESPONSE, responses[0].getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_HEARTBEAT_RESPONSE, responses[0].getPayloadType());
        assertEquals(7, responses[0].getRequestId());
        HeartbeatResponse response = HeartbeatResponse.parseFrom(responses[0].getPayload());
        assertEquals(123456789L, response.getMonotonicMillis());
        assertEquals(1L, reporter.counters().get("rpc.heartbeat.requests").longValue());
    }

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
