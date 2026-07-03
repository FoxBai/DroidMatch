package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;

import app.droidmatch.proto.v1.CancelTransferRequest;
import app.droidmatch.proto.v1.CancelTransferResponse;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.HeartbeatRequest;
import app.droidmatch.proto.v1.HeartbeatResponse;
import app.droidmatch.proto.v1.OpenTransferRequest;
import app.droidmatch.proto.v1.OpenTransferResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.PauseTransferRequest;
import app.droidmatch.proto.v1.PauseTransferResponse;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.TransferChunkAck;
import app.droidmatch.proto.v1.TransferDirection;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Collections;

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
    public void cancelTransferClosesActiveDownloadAndRejectsLaterAck() throws Exception {
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

        assertEquals(1, ackResponses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_ERROR, ackResponses[0].getKind());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, ackResponses[0].getError().getCode());
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
    public void pauseActiveDownloadClosesReaderAndReturnsResumableOffset() throws Exception {
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
        assertEquals(2, pauseResponse.getResumableOffsetBytes());
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

        assertEquals(1, ackResponses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_ERROR, ackResponses[0].getKind());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, ackResponses[0].getError().getCode());
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

    private static final class TestMediaCatalog implements DmFileProvider.MediaCatalog {
        private final byte[] data;
        private int openChunkSizeBytes;
        private int closeCount;

        private TestMediaCatalog(byte[] data) {
            this.data = data;
        }

        @Override
        public DmFileProvider.MediaPage listMedia(
                DmFileProvider.RootKind rootKind,
                DmFileProvider.ProviderQuery query
        ) {
            return new DmFileProvider.MediaPage(Collections.emptyList(), false);
        }

        @Override
        public DmFileProvider.DownloadChunk readMedia(
                DmFileProvider.RootKind rootKind,
                long mediaId,
                long offsetBytes,
                int chunkSizeBytes
        ) {
            int start = (int) offsetBytes;
            int end = Math.min(start + chunkSizeBytes, data.length);
            return new DmFileProvider.DownloadChunk(
                    Arrays.copyOfRange(data, start, end),
                    data.length,
                    1_700_000_000_000L,
                    "test-etag",
                    end >= data.length
            );
        }

        @Override
        public DmFileProvider.DownloadReader openMedia(
                DmFileProvider.RootKind rootKind,
                long mediaId,
                long offsetBytes,
                int chunkSizeBytes
        ) {
            openChunkSizeBytes = chunkSizeBytes;
            return new DmFileProvider.DownloadReader() {
                private int offset = (int) offsetBytes;
                private boolean closed;

                @Override
                public DmFileProvider.DownloadChunk readNextChunk() {
                    int end = Math.min(offset + chunkSizeBytes, data.length);
                    byte[] chunk = Arrays.copyOfRange(data, offset, end);
                    offset = end;
                    return new DmFileProvider.DownloadChunk(
                            chunk,
                            data.length,
                            1_700_000_000_000L,
                            "test-etag",
                            offset >= data.length
                    );
                }

                @Override
                public void close() {
                    if (closed) {
                        return;
                    }
                    closed = true;
                    closeCount++;
                }
            };
        }
    }
}
