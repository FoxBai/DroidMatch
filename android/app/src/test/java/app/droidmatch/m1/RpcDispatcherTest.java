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
import app.droidmatch.proto.v1.TransferChunk;
import app.droidmatch.proto.v1.TransferChunkAck;
import app.droidmatch.proto.v1.TransferDirection;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.Collections;
import java.util.zip.CRC32;

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
    public void uploadWritesChunksToAppSandboxAndAcksBoundaries() throws Exception {
        File root = Files.createTempDirectory("droidmatch-upload").toFile();
        try {
            DiagnosticsReporter reporter = new DiagnosticsReporter(() -> 1L, () -> "test-thread");
            RpcDispatcher dispatcher = new RpcDispatcher(
                    reporter,
                    null,
                    new DmFileProvider(root),
                    null
            );
            RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                    .setFrameVersion(1)
                    .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                    .setRequestId(31)
                    .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                    .setPayload(OpenTransferRequest.newBuilder()
                            .setTransferId("upload-me")
                            .setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                            .setSourcePath("/tmp/payload.bin")
                            .setDestinationPath("dm://app-sandbox/uploads/payload.bin")
                            .setExpectedSizeBytes(6)
                            .setPreferredChunkSizeBytes(4)
                            .build()
                            .toByteString())
                    .build();

            RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 5);

            assertEquals(1, openResponses.length);
            assertEquals(RpcFrameKind.RPC_FRAME_KIND_RESPONSE, openResponses[0].getKind());
            assertEquals(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_RESPONSE, openResponses[0].getPayloadType());
            OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());
            assertEquals("upload-me", openResponse.getTransferId());
            assertEquals(0, openResponse.getAcceptedOffsetBytes());
            assertEquals(4, openResponse.getChunkSizeBytes());
            assertEquals(6, openResponse.getTotalSizeBytes());
            assertEquals(31, openResponse.getStreamId());

            RpcEnvelope[] firstAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                    31,
                    openResponse.getStreamId(),
                    "upload-me",
                    0,
                    "abc",
                    false
            ).toByteArray(), true, 5);
            TransferChunkAck first = TransferChunkAck.parseFrom(firstAck[0].getPayload());
            assertEquals(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK, firstAck[0].getPayloadType());
            assertEquals(3, first.getNextOffsetBytes());
            assertEquals(false, first.getFinalAck());

            RpcEnvelope[] finalAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                    31,
                    openResponse.getStreamId(),
                    "upload-me",
                    3,
                    "def",
                    true
            ).toByteArray(), true, 5);
            TransferChunkAck finalResponse = TransferChunkAck.parseFrom(finalAck[0].getPayload());
            assertEquals(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK, finalAck[0].getPayloadType());
            assertEquals(6, finalResponse.getNextOffsetBytes());
            assertEquals(true, finalResponse.getFinalAck());
            assertEquals("abcdef", new String(
                    Files.readAllBytes(new File(root, "uploads/payload.bin").toPath()),
                    StandardCharsets.UTF_8
            ));
            assertEquals(6L, reporter.counters().get("rpc.transfer.bytes.received").longValue());
            assertEquals(1L, reporter.counters().get("rpc.transfer.uploads.completed").longValue());
        } finally {
            deleteRecursively(root);
        }
    }

    @Test
    public void uploadWritesChunksToSafDestinationAndAcksBoundaries() throws Exception {
        TestSafCatalog safCatalog = new TestSafCatalog(
                new DmFileProvider.SafRoot("abc123", "primary:Docs", "Documents", true)
        );
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                new DmFileProvider(new TestMediaCatalog(new byte[0]), safCatalog),
                null
        );
        RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(37)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("saf-upload")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                        .setSourcePath("/tmp/payload.txt")
                        .setDestinationPath("dm://saf-abc123/payload.txt")
                        .setExpectedSizeBytes(6)
                        .setPreferredChunkSizeBytes(4)
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 7);

        assertEquals(1, openResponses.length);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());
        assertEquals(0, openResponse.getAcceptedOffsetBytes());
        assertEquals(37, openResponse.getStreamId());

        RpcEnvelope[] firstAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                37,
                openResponse.getStreamId(),
                "saf-upload",
                0,
                "abc",
                false
        ).toByteArray(), true, 7);
        TransferChunkAck first = TransferChunkAck.parseFrom(firstAck[0].getPayload());
        assertEquals(3, first.getNextOffsetBytes());
        assertEquals(false, first.getFinalAck());

        RpcEnvelope[] finalAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                37,
                openResponse.getStreamId(),
                "saf-upload",
                3,
                "def",
                true
        ).toByteArray(), true, 7);
        TransferChunkAck finalResponse = TransferChunkAck.parseFrom(finalAck[0].getPayload());
        assertEquals(6, finalResponse.getNextOffsetBytes());
        assertEquals(true, finalResponse.getFinalAck());
        assertEquals("primary:Docs", safCatalog.uploadParentDocumentId);
        assertEquals("payload.txt", safCatalog.uploadDisplayName);
        assertEquals("abcdef", safCatalog.uploadedText());
    }

    @Test
    public void uploadResumeAcceptsExistingAppSandboxPartialOffset() throws Exception {
        File root = Files.createTempDirectory("droidmatch-upload-resume").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);
            DmFileProvider.UploadWriter partialWriter = provider.openUpload(
                    "dm://app-sandbox/uploads/payload.bin",
                    0,
                    6
            );
            partialWriter.writeChunk(0, "abc".getBytes(StandardCharsets.UTF_8), false);
            partialWriter.close();
            RpcDispatcher dispatcher = new RpcDispatcher(
                    new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                    null,
                    provider,
                    null
            );
            RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                    .setFrameVersion(1)
                    .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                    .setRequestId(41)
                    .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                    .setPayload(OpenTransferRequest.newBuilder()
                            .setTransferId("resume-upload")
                            .setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                            .setSourcePath("/tmp/payload.bin")
                            .setDestinationPath("dm://app-sandbox/uploads/payload.bin")
                            .setRequestedOffsetBytes(3)
                            .setExpectedSizeBytes(6)
                            .setPreferredChunkSizeBytes(4)
                            .build()
                            .toByteString())
                    .build();

            RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 8);

            assertEquals(1, openResponses.length);
            OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());
            assertEquals(3, openResponse.getAcceptedOffsetBytes());
            assertEquals(41, openResponse.getStreamId());

            RpcEnvelope[] finalAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                    41,
                    openResponse.getStreamId(),
                    "resume-upload",
                    3,
                    "def",
                    true
            ).toByteArray(), true, 8);
            TransferChunkAck finalResponse = TransferChunkAck.parseFrom(finalAck[0].getPayload());
            assertEquals(6, finalResponse.getNextOffsetBytes());
            assertEquals(true, finalResponse.getFinalAck());
            assertEquals("abcdef", new String(
                    Files.readAllBytes(new File(root, "uploads/payload.bin").toPath()),
                    StandardCharsets.UTF_8
            ));
        } finally {
            deleteRecursively(root);
        }
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

    private static RpcEnvelope uploadChunkEnvelope(
            long requestId,
            long streamId,
            String transferId,
            long offsetBytes,
            String text,
            boolean finalChunk
    ) {
        byte[] data = text.getBytes(StandardCharsets.UTF_8);
        return RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_STREAM)
                .setRequestId(requestId)
                .setStreamId(streamId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK)
                .setPayload(TransferChunk.newBuilder()
                        .setTransferId(transferId)
                        .setOffsetBytes(offsetBytes)
                        .setData(com.google.protobuf.ByteString.copyFrom(data))
                        .setCrc32(crc32(data))
                        .setFinalChunk(finalChunk)
                        .build()
                        .toByteString())
                .build();
    }

    private static int crc32(byte[] data) {
        CRC32 crc32 = new CRC32();
        crc32.update(data);
        return (int) crc32.getValue();
    }

    private static void deleteRecursively(File file) {
        if (file == null || !file.exists()) {
            return;
        }
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) {
                deleteRecursively(child);
            }
        }
        file.delete();
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

    private static final class TestSafCatalog implements DmFileProvider.SafCatalog {
        private final DmFileProvider.SafRoot root;
        private String uploadParentDocumentId;
        private String uploadDisplayName;
        private ByteArrayOutputStream uploadedBytes;

        private TestSafCatalog(DmFileProvider.SafRoot root) {
            this.root = root;
        }

        @Override
        public java.util.List<DmFileProvider.SafRoot> roots() {
            return Collections.singletonList(root);
        }

        @Override
        public DmFileProvider.SafPage listChildren(
                DmFileProvider.SafRoot root,
                String documentId,
                DmFileProvider.ProviderQuery query
        ) {
            return new DmFileProvider.SafPage(Collections.emptyList(), false);
        }

        @Override
        public DmFileProvider.DownloadChunk readDocument(
                DmFileProvider.SafRoot root,
                String documentId,
                long offsetBytes,
                int chunkSizeBytes
        ) throws DmFileProvider.ProviderCatalogException {
            throw new DmFileProvider.ProviderCatalogException(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "SAF document is not available"
            );
        }

        @Override
        public DmFileProvider.UploadWriter openUploadDocument(
                DmFileProvider.SafRoot root,
                String parentDocumentId,
                String displayName,
                long offsetBytes,
                long expectedSizeBytes
        ) {
            this.uploadParentDocumentId = parentDocumentId;
            this.uploadDisplayName = displayName;
            this.uploadedBytes = new ByteArrayOutputStream();
            return new DmFileProvider.UploadWriter() {
                private long nextOffsetBytes = offsetBytes;
                private boolean closed;

                @Override
                public long nextOffsetBytes() {
                    return nextOffsetBytes;
                }

                @Override
                public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
                        throws DmFileProvider.ProviderCatalogException {
                    if (closed) {
                        throw new DmFileProvider.ProviderCatalogException(
                                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                                "upload writer is closed"
                        );
                    }
                    if (offsetBytes != nextOffsetBytes) {
                        throw new DmFileProvider.ProviderCatalogException(
                                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                                "transfer chunk offset does not match the expected write boundary"
                        );
                    }
                    uploadedBytes.write(data, 0, data.length);
                    nextOffsetBytes += data.length;
                    if (finalChunk) {
                        close();
                    }
                }

                @Override
                public void close() {
                    closed = true;
                }
            };
        }

        private String uploadedText() {
            return new String(uploadedBytes.toByteArray(), StandardCharsets.UTF_8);
        }
    }
}
