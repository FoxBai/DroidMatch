package app.droidmatch.m1;

import static app.droidmatch.m1.RpcDispatcherTestFixtures.*;
import static org.junit.Assert.assertEquals;

import app.droidmatch.proto.v1.CancelTransferRequest;
import app.droidmatch.proto.v1.CancelTransferResponse;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.OpenTransferRequest;
import app.droidmatch.proto.v1.OpenTransferResponse;
import app.droidmatch.proto.v1.PauseTransferRequest;
import app.droidmatch.proto.v1.PauseTransferResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.TransferChunkAck;
import app.droidmatch.proto.v1.TransferDirection;

import java.nio.charset.StandardCharsets;

import org.junit.Test;

public final class RpcDispatcherDownloadLifecycleTest {
    @Test
    public void cancelTransferClosesActiveDownloadAndDrainsLaterAck() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdef".getBytes(StandardCharsets.UTF_8));
        DiagnosticsReporter reporter = new DiagnosticsReporter(() -> 1L, () -> "test-thread");
        RpcDispatcher dispatcher = new RpcDispatcher(
                reporter,
                null,
                new DmFileProvider(catalog),
                null
        );
        RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(11)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("cancel-me")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_DOWNLOAD)
                        .setSourcePath("dm://media-images/media/42")
                        .setPreferredChunkSizeBytes(2)
                        .build()
                        .toByteString())
                .build();
        RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 7);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());
        assertEquals("cancel-me", openResponse.getTransferId());
        assertEquals(2, catalog.openChunkSizeBytes);

        RpcEnvelope cancelRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(12)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_CANCEL_TRANSFER_REQUEST)
                .setPayload(CancelTransferRequest.newBuilder()
                        .setTransferId("cancel-me")
                        .setReason("unit-test")
                        .build()
                        .toByteString())
                .build();
        RpcEnvelope[] cancelResponses = dispatcher.dispatchForTest(cancelRequest.toByteArray(), true, 7);

        assertEquals(1, cancelResponses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_RESPONSE, cancelResponses[0].getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_CANCEL_TRANSFER_RESPONSE, cancelResponses[0].getPayloadType());
        CancelTransferResponse cancelResponse = CancelTransferResponse.parseFrom(cancelResponses[0].getPayload());
        assertEquals("cancel-me", cancelResponse.getTransferId());
        assertEquals(true, cancelResponse.getOk());
        assertEquals(1, catalog.closeCount);
        assertEquals(1L, reporter.counters().get("rpc.transfer.cancellations.received").longValue());

        TransferChunkAck ack = TransferChunkAck.newBuilder()
                .setTransferId("cancel-me")
                .setNextOffsetBytes(2)
                .build();
        RpcEnvelope ackRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_STREAM)
                .setRequestId(11)
                .setStreamId(openResponse.getStreamId())
                .setPayloadType(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK)
                .setPayload(ack.toByteString())
                .build();
        RpcEnvelope[] ackResponses = dispatcher.dispatchForTest(ackRequest.toByteArray(), true, 7);

        assertEquals(0, ackResponses.length);
    }

    @Test
    public void cancelTransferReturnsNotFoundForUnknownTransfer() throws Exception {
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                null,
                null
        );
        RpcEnvelope request = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(10)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_CANCEL_TRANSFER_REQUEST)
                .setPayload(CancelTransferRequest.newBuilder()
                        .setTransferId("missing-transfer")
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] responses = dispatcher.dispatchForTest(request.toByteArray(), true, 1);

        assertEquals(1, responses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_RESPONSE, responses[0].getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_CANCEL_TRANSFER_RESPONSE, responses[0].getPayloadType());
        CancelTransferResponse response = CancelTransferResponse.parseFrom(responses[0].getPayload());
        assertEquals("missing-transfer", response.getTransferId());
        assertEquals(false, response.getOk());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, response.getError().getCode());
    }

    @Test
    public void pauseActiveDownloadClosesReaderAndReturnsAcknowledgedOffset() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdef".getBytes(StandardCharsets.UTF_8));
        DiagnosticsReporter reporter = new DiagnosticsReporter(() -> 1L, () -> "test-thread");
        RpcDispatcher dispatcher = new RpcDispatcher(
                reporter,
                null,
                new DmFileProvider(catalog),
                null
        );
        RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(21)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("pause-me")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_DOWNLOAD)
                        .setSourcePath("dm://media-images/media/42")
                        .setPreferredChunkSizeBytes(2)
                        .build()
                        .toByteString())
                .build();
        RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 9);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());
        assertEquals("pause-me", openResponse.getTransferId());

        RpcEnvelope pauseRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(22)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_PAUSE_TRANSFER_REQUEST)
                .setPayload(PauseTransferRequest.newBuilder()
                        .setTransferId("pause-me")
                        .build()
                        .toByteString())
                .build();
        RpcEnvelope[] pauseResponses = dispatcher.dispatchForTest(pauseRequest.toByteArray(), true, 9);

        assertEquals(1, pauseResponses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_RESPONSE, pauseResponses[0].getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_PAUSE_TRANSFER_RESPONSE, pauseResponses[0].getPayloadType());
        PauseTransferResponse pauseResponse = PauseTransferResponse.parseFrom(pauseResponses[0].getPayload());
        assertEquals("pause-me", pauseResponse.getTransferId());
        assertEquals(true, pauseResponse.getOk());
        assertEquals(0, pauseResponse.getResumableOffsetBytes());
        assertEquals(1, catalog.closeCount);
        assertEquals(1L, reporter.counters().get("rpc.transfer.pauses.received").longValue());

        TransferChunkAck ack = TransferChunkAck.newBuilder()
                .setTransferId("pause-me")
                .setNextOffsetBytes(2)
                .build();
        RpcEnvelope ackRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_STREAM)
                .setRequestId(21)
                .setStreamId(openResponse.getStreamId())
                .setPayloadType(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK)
                .setPayload(ack.toByteString())
                .build();
        RpcEnvelope[] ackResponses = dispatcher.dispatchForTest(ackRequest.toByteArray(), true, 9);

        assertEquals(0, ackResponses.length);
    }

    @Test
    public void pauseWithWindowedChunksReturnsLastAckNotLastSentOffset() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdefghij".getBytes(StandardCharsets.UTF_8));
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                new DmFileProvider(catalog),
                null
        );
        long sessionId = 19;
        RpcEnvelope[] openResponses = dispatcher.dispatchForTest(
                downloadOpenEnvelope(81, "pause-window", 2).toByteArray(),
                true,
                sessionId
        );
        assertEquals(2, openResponses.length);

        RpcEnvelope[] refillResponses = dispatcher.dispatchForTest(transferChunkAckEnvelope(
                81,
                81,
                "pause-window",
                2,
                false
        ).toByteArray(), true, sessionId);
        assertEquals(4, refillResponses.length);
        assertDownloadChunk(refillResponses[3], "pause-window", 8, "ij", true);

        RpcEnvelope pauseRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(82)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_PAUSE_TRANSFER_REQUEST)
                .setPayload(PauseTransferRequest.newBuilder()
                        .setTransferId("pause-window")
                        .build()
                        .toByteString())
                .build();
        RpcEnvelope[] pauseResponses = dispatcher.dispatchForTest(
                pauseRequest.toByteArray(),
                true,
                sessionId
        );

        assertEquals(1, pauseResponses.length);
        PauseTransferResponse response = PauseTransferResponse.parseFrom(
                pauseResponses[0].getPayload()
        );
        assertEquals(true, response.getOk());
        assertEquals(2, response.getResumableOffsetBytes());
        assertEquals(1, catalog.closeCount);
    }

    @Test
    public void pauseTransferReturnsNotFoundForUnknownTransfer() throws Exception {
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                null,
                null
        );
        RpcEnvelope request = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(10)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_PAUSE_TRANSFER_REQUEST)
                .setPayload(PauseTransferRequest.newBuilder()
                        .setTransferId("missing-transfer")
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] responses = dispatcher.dispatchForTest(request.toByteArray(), true, 1);

        assertEquals(1, responses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_RESPONSE, responses[0].getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_PAUSE_TRANSFER_RESPONSE, responses[0].getPayloadType());
        PauseTransferResponse response = PauseTransferResponse.parseFrom(responses[0].getPayload());
        assertEquals("missing-transfer", response.getTransferId());
        assertEquals(false, response.getOk());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, response.getError().getCode());
    }
}
