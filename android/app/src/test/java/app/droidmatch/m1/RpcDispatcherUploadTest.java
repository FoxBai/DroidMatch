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
import app.droidmatch.proto.v1.DiscardUploadPartialRequest;
import app.droidmatch.proto.v1.DiscardUploadPartialResponse;
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
import static app.droidmatch.m1.DmFileProviderTestFixtures.deleteAppSandboxRoot;

public final class RpcDispatcherUploadTest {
    @Test
    public void authenticatedDiscardUploadPartialIsIdempotentAndCapabilityBound() throws Exception {
        File root = Files.createTempDirectory("droidmatch-upload-discard").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);
            DmFileProvider.UploadWriter writer = provider.openUpload(
                    "dm://app-sandbox/uploads/payload.bin",
                    "discard-rpc",
                    0,
                    6
            );
            writer.writeChunk(0, "abc".getBytes(StandardCharsets.UTF_8), false);
            writer.close();
            RpcDispatcher dispatcher = new RpcDispatcher(
                    new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                    null,
                    provider,
                    null
            );
            RpcEnvelope request = RpcEnvelope.newBuilder()
                    .setFrameVersion(1)
                    .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                    .setRequestId(81)
                    .setPayloadType(PayloadType.PAYLOAD_TYPE_DISCARD_UPLOAD_PARTIAL_REQUEST)
                    .setPayload(DiscardUploadPartialRequest.newBuilder()
                            .setTransferId("discard-rpc")
                            .setDestinationPath("dm://app-sandbox/uploads/payload.bin")
                            .setExpectedSizeBytes(6)
                            .build()
                            .toByteString())
                    .build();

            RpcDispatcher.SessionState writeOnly = dispatcher.newSessionStateForTest();
            writeOnly.markReadyAndClear(Arrays.asList(Capability.CAPABILITY_FILE_WRITE));
            RpcEnvelope[] denied = dispatcher.dispatchForTest(
                    request.toByteArray(),
                    writeOnly,
                    17
            );
            assertEquals(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, denied[0].getError().getCode());

            RpcEnvelope[] first = dispatcher.dispatchForTest(request.toByteArray(), true, 18);
            RpcEnvelope[] second = dispatcher.dispatchForTest(request.toByteArray(), true, 18);
            DiscardUploadPartialResponse firstResponse =
                    DiscardUploadPartialResponse.parseFrom(first[0].getPayload());
            DiscardUploadPartialResponse secondResponse =
                    DiscardUploadPartialResponse.parseFrom(second[0].getPayload());
            assertEquals(PayloadType.PAYLOAD_TYPE_DISCARD_UPLOAD_PARTIAL_RESPONSE,
                    first[0].getPayloadType());
            assertTrue(firstResponse.getOk());
            assertTrue(secondResponse.getOk());
            assertEquals("discard-rpc", secondResponse.getTransferId());
        } finally {
            deleteAppSandboxRoot(root);
        }
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
            deleteAppSandboxRoot(root);
        }
    }

    @Test
    public void cancelActiveUploadReleasesWriterAndAllowsSafeResume() throws Exception {
        File root = Files.createTempDirectory("droidmatch-upload-cancel").toFile();
        try {
            RpcDispatcher dispatcher = new RpcDispatcher(
                    new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                    null,
                    new DmFileProvider(root),
                    null
            );
            long sessionId = 21;
            RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                    .setFrameVersion(1)
                    .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                    .setRequestId(41)
                    .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                    .setPayload(OpenTransferRequest.newBuilder()
                            .setTransferId("cancel-upload")
                            .setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                            .setSourcePath("/tmp/payload.bin")
                            .setDestinationPath("dm://app-sandbox/uploads/cancel.bin")
                            .setExpectedSizeBytes(6)
                            .setPreferredChunkSizeBytes(4)
                            .build()
                            .toByteString())
                    .build();
            OpenTransferResponse opened = OpenTransferResponse.parseFrom(
                    dispatcher.dispatchForTest(openRequest.toByteArray(), true, sessionId)[0]
                            .getPayload()
            );
            RpcEnvelope[] firstAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                    41,
                    opened.getStreamId(),
                    "cancel-upload",
                    0,
                    "abc",
                    false
            ).toByteArray(), true, sessionId);
            assertEquals(3, TransferChunkAck.parseFrom(firstAck[0].getPayload()).getNextOffsetBytes());

            RpcEnvelope cancelRequest = RpcEnvelope.newBuilder()
                    .setFrameVersion(1)
                    .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                    .setRequestId(42)
                    .setPayloadType(PayloadType.PAYLOAD_TYPE_CANCEL_TRANSFER_REQUEST)
                    .setPayload(CancelTransferRequest.newBuilder()
                            .setTransferId("cancel-upload")
                            .setReason("unit-test")
                            .build()
                            .toByteString())
                    .build();
            CancelTransferResponse cancelled = CancelTransferResponse.parseFrom(
                    dispatcher.dispatchForTest(cancelRequest.toByteArray(), true, sessionId)[0]
                            .getPayload()
            );
            assertEquals(true, cancelled.getOk());

            RpcEnvelope resumeRequest = RpcEnvelope.newBuilder()
                    .setFrameVersion(1)
                    .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                    .setRequestId(43)
                    .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                    .setPayload(OpenTransferRequest.newBuilder()
                            .setTransferId("cancel-upload")
                            .setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                            .setSourcePath("/tmp/payload.bin")
                            .setDestinationPath("dm://app-sandbox/uploads/cancel.bin")
                            .setRequestedOffsetBytes(3)
                            .setExpectedSizeBytes(6)
                            .setPreferredChunkSizeBytes(4)
                            .build()
                            .toByteString())
                    .build();
            OpenTransferResponse resumed = OpenTransferResponse.parseFrom(
                    dispatcher.dispatchForTest(resumeRequest.toByteArray(), true, sessionId)[0]
                            .getPayload()
            );
            assertEquals(3, resumed.getAcceptedOffsetBytes());

            RpcEnvelope[] finalAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                    43,
                    resumed.getStreamId(),
                    "cancel-upload",
                    3,
                    "def",
                    true
            ).toByteArray(), true, sessionId);
            assertEquals(true, TransferChunkAck.parseFrom(finalAck[0].getPayload()).getFinalAck());
            assertEquals("abcdef", new String(
                    Files.readAllBytes(new File(root, "uploads/cancel.bin").toPath()),
                    StandardCharsets.UTF_8
            ));
        } finally {
            deleteAppSandboxRoot(root);
        }
    }

    @Test
    public void uploadChunkRejectsBadCrc32() throws Exception {
        File root = Files.createTempDirectory("droidmatch-upload-crc").toFile();
        try {
            RpcDispatcher dispatcher = new RpcDispatcher(
                    new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                    null,
                    new DmFileProvider(root),
                    null
            );
            RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                    .setFrameVersion(1)
                    .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                    .setRequestId(35)
                    .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                    .setPayload(OpenTransferRequest.newBuilder()
                            .setTransferId("bad-crc-upload")
                            .setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                            .setSourcePath("/tmp/payload.bin")
                            .setDestinationPath("dm://app-sandbox/uploads/payload.bin")
                            .setExpectedSizeBytes(3)
                            .setPreferredChunkSizeBytes(4)
                            .build()
                            .toByteString())
                    .build();
            RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 5);
            OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());

            RpcEnvelope[] responses = dispatcher.dispatchForTest(uploadChunkEnvelope(
                    35,
                    openResponse.getStreamId(),
                    "bad-crc-upload",
                    0,
                    "abc",
                    false,
                    0
            ).toByteArray(), true, 5);

            assertEquals(1, responses.length);
            assertEquals(RpcFrameKind.RPC_FRAME_KIND_ERROR, responses[0].getKind());
            assertEquals(ErrorCode.ERROR_CODE_CHECKSUM_MISMATCH, responses[0].getError().getCode());
            assertEquals("transfer chunk crc32 mismatch", responses[0].getError().getMessage());
        } finally {
            deleteAppSandboxRoot(root);
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
        assertEquals("saf-upload", safCatalog.uploadTransferId);
        assertEquals("abcdef", safCatalog.uploadedText());
    }

    @Test
    public void uploadWritesChunksToMediaStoreDestinationAndAcksBoundaries() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog(new byte[0]);
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                new DmFileProvider(catalog),
                null
        );
        RpcEnvelope openRequest = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(39)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId("media-upload")
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                        .setSourcePath("/tmp/payload.jpg")
                        .setDestinationPath("dm://media-images/payload.jpg")
                        .setExpectedSizeBytes(6)
                        .setPreferredChunkSizeBytes(4)
                        .build()
                        .toByteString())
                .build();

        RpcEnvelope[] openResponses = dispatcher.dispatchForTest(openRequest.toByteArray(), true, 7);

        assertEquals(1, openResponses.length);
        OpenTransferResponse openResponse = OpenTransferResponse.parseFrom(openResponses[0].getPayload());
        assertEquals(0, openResponse.getAcceptedOffsetBytes());
        assertEquals(39, openResponse.getStreamId());

        RpcEnvelope[] firstAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                39,
                openResponse.getStreamId(),
                "media-upload",
                0,
                "abc",
                false
        ).toByteArray(), true, 7);
        TransferChunkAck first = TransferChunkAck.parseFrom(firstAck[0].getPayload());
        assertEquals(3, first.getNextOffsetBytes());
        assertEquals(false, first.getFinalAck());

        RpcEnvelope[] finalAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                39,
                openResponse.getStreamId(),
                "media-upload",
                3,
                "def",
                true
        ).toByteArray(), true, 7);
        TransferChunkAck finalResponse = TransferChunkAck.parseFrom(finalAck[0].getPayload());
        assertEquals(6, finalResponse.getNextOffsetBytes());
        assertEquals(true, finalResponse.getFinalAck());
        assertEquals(DmFileProvider.RootKind.MEDIA_IMAGES, catalog.uploadRootKind);
        assertEquals("payload.jpg", catalog.uploadDisplayName);
        assertEquals("abcdef", catalog.uploadedText());
    }

    @Test
    public void uploadResumeAcceptsExistingAppSandboxPartialOffset() throws Exception {
        File root = Files.createTempDirectory("droidmatch-upload-resume").toFile();
        try {
            DmFileProvider provider = new DmFileProvider(root);
            DmFileProvider.UploadWriter partialWriter = provider.openUpload(
                    "dm://app-sandbox/uploads/payload.bin",
                    "resume-upload",
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
            deleteAppSandboxRoot(root);
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

}
