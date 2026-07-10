package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.AuthenticateSessionRequest;
import app.droidmatch.proto.v1.AuthenticateSessionResponse;
import app.droidmatch.proto.v1.AuthenticationState;
import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.CancelTransferRequest;
import app.droidmatch.proto.v1.CancelTransferResponse;
import app.droidmatch.proto.v1.ClientHello;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.HeartbeatRequest;
import app.droidmatch.proto.v1.HeartbeatResponse;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.OpenTransferRequest;
import app.droidmatch.proto.v1.OpenTransferResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.PauseTransferRequest;
import app.droidmatch.proto.v1.PauseTransferResponse;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.ServerHello;
import app.droidmatch.proto.v1.TransferChunk;
import app.droidmatch.proto.v1.TransferChunkAck;
import app.droidmatch.proto.v1.TransferDirection;
import app.droidmatch.proto.v1.TransferFingerprint;
import app.droidmatch.proto.v1.TransportKind;
import com.google.protobuf.ByteString;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Collections;
import java.util.zip.CRC32;

import org.junit.Test;

import static app.droidmatch.m1.RpcDispatcherTestFixtures.*;

public final class RpcDispatcherDownloadTest {
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

        assertEquals(1, ackResponses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_ERROR, ackResponses[0].getKind());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, ackResponses[0].getError().getCode());
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

    @Test
    public void downloadResumeRequiresSourceFingerprint() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdef".getBytes(StandardCharsets.UTF_8));
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                new DmFileProvider(catalog),
                null
        );
        RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(31)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("resume-download")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_DOWNLOAD)
                        .setSourcePath("dm://media-images/media/42")
                        .setRequestedOffsetBytes(3)
                        .setPreferredChunkSizeBytes(2)
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] responses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 7);

        assertEquals(1, responses.length);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(responses[0].getPayload());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, openResponse.getError().getCode());
        assertEquals("source_fingerprint is required for resume", openResponse.getError().getMessage());
        assertEquals(0, catalog.openChunkSizeBytes);
    }

    @Test
    public void downloadResumeRejectsChangedSourceFingerprintAndClosesReader() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdef".getBytes(StandardCharsets.UTF_8));
        catalog.modifiedUnixMillis = 1_700_000_001_000L;
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                new DmFileProvider(catalog),
                null
        );
        RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(32)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("resume-download")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_DOWNLOAD)
                        .setSourcePath("dm://media-images/media/42")
                        .setRequestedOffsetBytes(3)
                        .setSourceFingerprint(testSourceFingerprint())
                        .setPreferredChunkSizeBytes(2)
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] responses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 7);

        assertEquals(1, responses.length);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(responses[0].getPayload());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, openResponse.getError().getCode());
        assertEquals("source fingerprint changed", openResponse.getError().getMessage());
        assertEquals(1, catalog.closeCount);
    }

    @Test
    public void downloadResumeReportsNotFoundWhenSourceDisappears() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdef".getBytes(StandardCharsets.UTF_8));
        catalog.downloadAvailable = false;
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                new DmFileProvider(catalog),
                null
        );
        RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(33)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("resume-download")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_DOWNLOAD)
                        .setSourcePath("dm://media-images/media/42")
                        .setRequestedOffsetBytes(3)
                        .setSourceFingerprint(testSourceFingerprint())
                        .setPreferredChunkSizeBytes(2)
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] responses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 7);

        assertEquals(1, responses.length);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(responses[0].getPayload());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, openResponse.getError().getCode());
        assertEquals("download source is not available", openResponse.getError().getMessage());
        assertEquals(0, catalog.closeCount);
    }

    @Test
    public void downloadAckRefillsWindowUpToProtocolLimit() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdefghij".getBytes(StandardCharsets.UTF_8));
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
                .setRequestId(51)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("windowed-download")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_DOWNLOAD)
                        .setSourcePath("dm://media-images/media/42")
                        .setPreferredChunkSizeBytes(2)
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 3);

        assertEquals(2, openResponses.length);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());
        assertEquals(51, openResponse.getStreamId());
        assertDownloadChunk(openResponses[1], "windowed-download", 0, "ab", false);

        RpcEnvelope[] refillResponses = dispatcher.dispatchForTest(transferChunkAckEnvelope(
                51,
                openResponse.getStreamId(),
                "windowed-download",
                2,
                false
        ).toByteArray(), true, 3);

        assertEquals(4, refillResponses.length);
        assertDownloadChunk(refillResponses[0], "windowed-download", 2, "cd", false);
        assertDownloadChunk(refillResponses[1], "windowed-download", 4, "ef", false);
        assertDownloadChunk(refillResponses[2], "windowed-download", 6, "gh", false);
        assertDownloadChunk(refillResponses[3], "windowed-download", 8, "ij", true);
        assertEquals(10L, reporter.counters().get("rpc.transfer.bytes.sent").longValue());
        assertEquals(5L, reporter.counters().get("rpc.transfer.chunks.sent").longValue());

        assertEquals(0, dispatcher.dispatchForTest(transferChunkAckEnvelope(
                51,
                openResponse.getStreamId(),
                "windowed-download",
                4,
                false
        ).toByteArray(), true, 3).length);
        assertEquals(0, dispatcher.dispatchForTest(transferChunkAckEnvelope(
                51,
                openResponse.getStreamId(),
                "windowed-download",
                6,
                false
        ).toByteArray(), true, 3).length);
        assertEquals(0, dispatcher.dispatchForTest(transferChunkAckEnvelope(
                51,
                openResponse.getStreamId(),
                "windowed-download",
                8,
                false
        ).toByteArray(), true, 3).length);
        assertEquals(0, dispatcher.dispatchForTest(transferChunkAckEnvelope(
                51,
                openResponse.getStreamId(),
                "windowed-download",
                10,
                true
        ).toByteArray(), true, 3).length);
        assertEquals(1L, reporter.counters().get("rpc.transfer.final_acks.received").longValue());
    }

    @Test
    public void dualDownloadStreamsInterleaveKeepHeartbeatResponsiveAndEnforceLimit() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdefgh".getBytes(StandardCharsets.UTF_8));
        DiagnosticsReporter reporter = new DiagnosticsReporter(() -> 1L, () -> "test-thread");
        RpcDispatcher dispatcher = new RpcDispatcher(
                reporter,
                null,
                new DmFileProvider(catalog),
                null
        );
        long sessionId = 33;

        RpcEnvelope[] firstOpen = dispatcher.dispatchForTest(
                downloadOpenEnvelope(71, "dual-a", 2).toByteArray(),
                true,
                sessionId
        );
        RpcEnvelope[] secondOpen = dispatcher.dispatchForTest(
                downloadOpenEnvelope(72, "dual-b", 2).toByteArray(),
                true,
                sessionId
        );
        assertEquals(2, firstOpen.length);
        assertEquals(2, secondOpen.length);
        assertDownloadChunk(firstOpen[1], "dual-a", 0, "ab", false);
        assertDownloadChunk(secondOpen[1], "dual-b", 0, "ab", false);

        RpcEnvelope[] heartbeat = dispatcher.dispatchForTest(
                heartbeatEnvelope(73).toByteArray(),
                true,
                sessionId
        );
        assertEquals(PayloadType.PAYLOAD_TYPE_HEARTBEAT_RESPONSE, heartbeat[0].getPayloadType());
        assertEquals(73, HeartbeatResponse.parseFrom(heartbeat[0].getPayload()).getMonotonicMillis());

        RpcEnvelope invalidDirection = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(74)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("dual-invalid")
                        .setSourcePath("dm://media-images/media/42")
                        .build()
                        .toByteString())
                .build();
        RpcEnvelope[] invalidDirectionResponse = dispatcher.dispatchForTest(
                invalidDirection.toByteArray(),
                true,
                sessionId
        );
        assertEquals(1, invalidDirectionResponse.length);
        assertEquals(
                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                OpenTransferResponse.parseFrom(invalidDirectionResponse[0].getPayload())
                        .getError()
                        .getCode()
        );

        RpcEnvelope[] duplicateTransfer = dispatcher.dispatchForTest(
                downloadOpenEnvelope(75, "dual-a", 2).toByteArray(),
                true,
                sessionId
        );
        assertEquals(1, duplicateTransfer.length);
        OpenTransferResponse duplicate = OpenTransferResponse.parseFrom(
                duplicateTransfer[0].getPayload()
        );
        assertEquals(ErrorCode.ERROR_CODE_ALREADY_EXISTS, duplicate.getError().getCode());
        assertEquals(
                "transfer_id is already active in this session",
                duplicate.getError().getMessage()
        );

        RpcEnvelope[] rejectedThird = dispatcher.dispatchForTest(
                downloadOpenEnvelope(76, "dual-c", 2).toByteArray(),
                true,
                sessionId
        );
        assertEquals(1, rejectedThird.length);
        OpenTransferResponse rejected = OpenTransferResponse.parseFrom(rejectedThird[0].getPayload());
        assertEquals(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, rejected.getError().getCode());
        assertEquals(
                "maximum concurrent transfer streams reached",
                rejected.getError().getMessage()
        );

        RpcEnvelope[] firstRefill = dispatcher.dispatchForTest(transferChunkAckEnvelope(
                71,
                71,
                "dual-a",
                2,
                false
        ).toByteArray(), true, sessionId);
        RpcEnvelope[] secondRefill = dispatcher.dispatchForTest(transferChunkAckEnvelope(
                72,
                72,
                "dual-b",
                2,
                false
        ).toByteArray(), true, sessionId);
        assertEquals(3, firstRefill.length);
        assertEquals(3, secondRefill.length);
        assertDownloadChunk(firstRefill[0], "dual-a", 2, "cd", false);
        assertDownloadChunk(secondRefill[0], "dual-b", 2, "cd", false);
        assertDownloadChunk(firstRefill[2], "dual-a", 6, "gh", true);
        assertDownloadChunk(secondRefill[2], "dual-b", 6, "gh", true);

        long[] offsets = {4, 6, 8};
        for (int index = 0; index < offsets.length; index += 1) {
            boolean finalAck = index == offsets.length - 1;
            assertEquals(0, dispatcher.dispatchForTest(transferChunkAckEnvelope(
                    71,
                    71,
                    "dual-a",
                    offsets[index],
                    finalAck
            ).toByteArray(), true, sessionId).length);
            assertEquals(0, dispatcher.dispatchForTest(transferChunkAckEnvelope(
                    72,
                    72,
                    "dual-b",
                    offsets[index],
                    finalAck
            ).toByteArray(), true, sessionId).length);
        }
        assertEquals(2, catalog.closeCount);
        assertEquals(
                1L,
                reporter.counters().get("rpc.transfer.concurrent_limit_rejected").longValue()
        );

        RpcEnvelope[] replacementOpen = dispatcher.dispatchForTest(
                downloadOpenEnvelope(77, "dual-c", 2).toByteArray(),
                true,
                sessionId
        );
        assertEquals(2, replacementOpen.length);
        assertDownloadChunk(replacementOpen[1], "dual-c", 0, "ab", false);
    }

}
