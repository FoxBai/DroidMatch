package app.droidmatch.m1;

import static app.droidmatch.m1.RpcDispatcherTestFixtures.*;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.HeartbeatResponse;
import app.droidmatch.proto.v1.OpenTransferRequest;
import app.droidmatch.proto.v1.OpenTransferResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.TransferDirection;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

import org.junit.Test;

public final class RpcDispatcherDownloadTest {
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
        assertFalse(openResponse.getError().getMessage().contains("secret.jpg"));
        assertFalse(openResponse.getError().getMessage().contains("content://"));
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
    public void downloadRefillPermissionFailureClosesAndRemovesStream() throws Exception {
        byte[] data = "abcdef".getBytes(StandardCharsets.UTF_8);
        SecurityFailingInputStream input = new SecurityFailingInputStream(data, 2);
        TestMediaCatalog catalog = new TestMediaCatalog(data) {
            @Override
            public DmFileProvider.DownloadReader openMedia(
                    DmFileProvider.RootKind rootKind,
                    long mediaId,
                    long offsetBytes,
                    int chunkSizeBytes
            ) {
                return ProviderDownloadReaders.stream(
                        input,
                        offsetBytes,
                        chunkSizeBytes,
                        data.length,
                        modifiedUnixMillis,
                        providerEtag,
                        ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "content://media/external/images/private/secret.jpg permission denied",
                        "MediaStore read failed"
                );
            }
        };
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                new DmFileProvider(catalog),
                null
        );

        RpcEnvelope[] openResponses = dispatcher.dispatchForTest(
                downloadOpenEnvelope(61, "permission-loss", 2).toByteArray(),
                true,
                13
        );
        assertEquals(2, openResponses.length);
        assertDownloadChunk(openResponses[1], "permission-loss", 0, "ab", false);

        RpcEnvelope ack = transferChunkAckEnvelope(61, 61, "permission-loss", 2, false);
        RpcEnvelope[] refillResponses = dispatcher.dispatchForTest(
                ack.toByteArray(),
                true,
                13
        );
        assertEquals(1, refillResponses.length);
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_ERROR, refillResponses[0].getKind());
        assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, refillResponses[0].getError().getCode());
        assertEquals("download permission is required",
                refillResponses[0].getError().getMessage());
        assertFalse(refillResponses[0].getError().getMessage().contains("secret.jpg"));
        assertFalse(refillResponses[0].getError().getMessage().contains("content://"));
        assertEquals(1, input.closeCount);
        assertEquals(2, input.readCount);

        RpcEnvelope[] repeatedAckResponses = dispatcher.dispatchForTest(
                ack.toByteArray(), true, 13);
        assertEquals(0, repeatedAckResponses.length);
        assertEquals(2, input.readCount);
        assertEquals(1, input.closeCount);
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

    private static final class SecurityFailingInputStream extends ByteArrayInputStream {
        private final int failingRead;
        private int readCount;
        private int closeCount;

        private SecurityFailingInputStream(byte[] data, int failingRead) {
            super(data);
            this.failingRead = failingRead;
        }

        @Override
        public synchronized int read(byte[] buffer, int offset, int length) {
            readCount += 1;
            if (readCount == failingRead) {
                throw new SecurityException("content://private/media/42 and stack detail");
            }
            return super.read(buffer, offset, length);
        }

        @Override
        public void close() throws IOException {
            closeCount += 1;
            super.close();
        }
    }

}
