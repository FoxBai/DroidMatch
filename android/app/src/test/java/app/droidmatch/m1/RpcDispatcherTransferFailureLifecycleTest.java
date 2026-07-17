package app.droidmatch.m1;

import static app.droidmatch.m1.RpcDispatcherTestFixtures.TestMediaCatalog;
import static app.droidmatch.m1.RpcDispatcherTestFixtures.crc32;
import static app.droidmatch.m1.DmFileProviderTestFixtures.deleteAppSandboxRoot;
import static app.droidmatch.m1.RpcDispatcherTestFixtures.heartbeatEnvelope;
import static app.droidmatch.m1.RpcDispatcherTestFixtures.transferChunkAckEnvelope;
import static app.droidmatch.m1.RpcDispatcherTestFixtures.uploadChunkEnvelope;
import static app.droidmatch.m1.RpcTransferFailureTestSupport.*;
import static org.junit.Assert.assertEquals;

import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.OpenTransferResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;

import org.junit.Test;

public final class RpcDispatcherTransferFailureLifecycleTest {
    @Test
    public void terminalUploadErrorsReleaseSlotAndDestinationLease() throws Exception {
        for (int failure = MALFORMED_PAYLOAD; failure <= BAD_CHUNK_CRC; failure += 1) {
            File root = Files.createTempDirectory("droidmatch-upload-terminal-" + failure).toFile();
            try {
                RpcDispatcher dispatcher = dispatcher(new DmFileProvider(root));
                long sessionId = 100 + failure;
                String transferId = "broken-" + failure;
                String destination = "dm://app-sandbox/uploads/terminal-" + failure + ".bin";
                OpenTransferResponse opened = openUpload(
                        dispatcher,
                        sessionId,
                        21,
                        transferId,
                        destination
                );

                RpcEnvelope rejected = dispatcher.dispatchForTest(
                        invalidUploadChunk(failure, opened, transferId).toByteArray(),
                        true,
                        sessionId
                )[0];
                assertError(rejected, uploadFailureCode(failure));

                OpenTransferResponse replacement = openUpload(
                        dispatcher,
                        sessionId,
                        22,
                        transferId,
                        destination
                );
                RpcEnvelope finalAck = dispatcher.dispatchForTest(uploadChunkEnvelope(
                        22,
                        replacement.getStreamId(),
                        transferId,
                        0,
                        "abc",
                        true
                ).toByteArray(), true, sessionId)[0];
                assertEquals(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK, finalAck.getPayloadType());
                assertEquals(0, dispatcher.dispatchForTest(uploadChunkEnvelope(
                        22,
                        replacement.getStreamId(),
                        transferId,
                        3,
                        "late",
                        false
                ).toByteArray(), true, sessionId).length);
                assertEquals(
                        "abc",
                        new String(
                                Files.readAllBytes(new File(root, "uploads/terminal-" + failure + ".bin").toPath()),
                                StandardCharsets.UTF_8
                        )
                );
            } finally {
                deleteAppSandboxRoot(root);
            }
        }
    }

    @Test
    public void crossedRequestAndStreamIdsAbortOnlyCorrelatedRoute() throws Exception {
        File root = Files.createTempDirectory("droidmatch-crossed-stream").toFile();
        try {
            RpcDispatcher dispatcher = dispatcher(new DmFileProvider(root));
            long sessionId = 200;
            OpenTransferResponse first = openUpload(
                    dispatcher,
                    sessionId,
                    31,
                    "first",
                    "dm://app-sandbox/uploads/first.bin"
            );
            OpenTransferResponse sibling = openUpload(
                    dispatcher,
                    sessionId,
                    32,
                    "sibling",
                    "dm://app-sandbox/uploads/sibling.bin"
            );

            RpcEnvelope crossed = uploadChunkEnvelope(
                    31,
                    sibling.getStreamId(),
                    "sibling",
                    0,
                    "bad",
                    true
            );
            RpcEnvelope rejected = dispatcher.dispatchForTest(crossed.toByteArray(), true, sessionId)[0];
            assertError(rejected, ErrorCode.ERROR_CODE_PROTOCOL_ERROR);

            RpcEnvelope lateTail = uploadChunkEnvelope(31, 31, "first", 0, "late", false);
            assertEquals(0, dispatcher.dispatchForTest(lateTail.toByteArray(), true, sessionId).length);
            assertEquals(0, dispatcher.dispatchForTest(
                    lateTail.toBuilder().setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST).build().toByteArray(),
                    true,
                    sessionId
            ).length);
            assertEquals(0, dispatcher.dispatchForTest(
                    lateTail.toBuilder()
                            .setStreamId(sibling.getStreamId())
                            .setFlags(1)
                            .setPayloadCrc32(crc32(lateTail.getPayload().toByteArray()) ^ 1)
                            .build()
                            .toByteArray(),
                    true,
                    sessionId
            ).length);
            assertEquals(0, dispatcher.dispatchForTest(lateTail.toByteArray(), true, sessionId).length);
            assertError(
                    dispatcher.dispatchForTest(lateTail.toByteArray(), true, sessionId)[0],
                    ErrorCode.ERROR_CODE_NOT_FOUND
            );
            assertEquals(
                    PayloadType.PAYLOAD_TYPE_HEARTBEAT_RESPONSE,
                    dispatcher.dispatchForTest(heartbeatEnvelope(90).toByteArray(), true, sessionId)[0]
                            .getPayloadType()
            );
            assertError(
                    dispatcher.dispatchForTest(
                            uploadChunkEnvelope(91, 91, "unknown", 0, "x", false).toByteArray(),
                            true,
                            sessionId
                    )[0],
                    ErrorCode.ERROR_CODE_NOT_FOUND
            );

            OpenTransferResponse replacement = openUpload(
                    dispatcher,
                    sessionId,
                    33,
                    "first",
                    "dm://app-sandbox/uploads/first.bin"
            );
            assertEquals(first.getStreamId(), 31);
            assertEquals(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK, dispatcher.dispatchForTest(
                    uploadChunkEnvelope(32, sibling.getStreamId(), "sibling", 0, "xyz", true).toByteArray(),
                    true,
                    sessionId
            )[0].getPayloadType());
            assertEquals(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK, dispatcher.dispatchForTest(
                    uploadChunkEnvelope(33, replacement.getStreamId(), "first", 0, "abc", true).toByteArray(),
                    true,
                    sessionId
            )[0].getPayloadType());
            assertFileText(root, "uploads/first.bin", "abc");
            assertFileText(root, "uploads/sibling.bin", "xyz");
        } finally {
            deleteAppSandboxRoot(root);
        }
    }

    @Test
    public void transferEnvelopeErrorsReleaseCorrelatedUpload() throws Exception {
        for (int failure = 0; failure < 6; failure += 1) {
            File root = Files.createTempDirectory("droidmatch-envelope-terminal-" + failure).toFile();
            try {
                RpcDispatcher dispatcher = dispatcher(new DmFileProvider(root));
                long sessionId = 300 + failure;
                String transferId = "envelope-" + failure;
                String destination = "dm://app-sandbox/uploads/envelope-" + failure + ".bin";
                OpenTransferResponse opened = openUpload(
                        dispatcher,
                        sessionId,
                        41,
                        transferId,
                        destination
                );
                RpcEnvelope valid = uploadChunkEnvelope(
                        41,
                        opened.getStreamId(),
                        transferId,
                        0,
                        "abc",
                        true
                );
                RpcEnvelope invalid;
                if (failure == 0) {
                    invalid = valid.toBuilder()
                            .setFlags(1)
                            .setPayloadCrc32(crc32(valid.getPayload().toByteArray()) ^ 1)
                            .build();
                } else if (failure == 1) {
                    invalid = valid.toBuilder().setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST).build();
                } else if (failure == 2) {
                    invalid = valid.toBuilder().setStreamId(0).build();
                } else if (failure == 3) {
                    invalid = valid.toBuilder()
                            .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                            .setPayloadType(PayloadType.PAYLOAD_TYPE_HEARTBEAT_REQUEST)
                            .setFlags(1)
                            .setPayloadCrc32(crc32(valid.getPayload().toByteArray()) ^ 1)
                            .build();
                } else if (failure == 4) {
                    invalid = valid.toBuilder()
                            .setPayloadType(PayloadType.PAYLOAD_TYPE_HEARTBEAT_REQUEST)
                            .build();
                } else {
                    invalid = valid.toBuilder()
                            .setPayloadType(PayloadType.PAYLOAD_TYPE_HEARTBEAT_REQUEST)
                            .setFlags(1)
                            .setPayloadCrc32(crc32(valid.getPayload().toByteArray()))
                            .build();
                }

                RpcEnvelope rejected = dispatcher.dispatchForTest(invalid.toByteArray(), true, sessionId)[0];
                assertError(
                        rejected,
                        failure == 0 || failure == 3
                                ? ErrorCode.ERROR_CODE_CHECKSUM_MISMATCH
                                : ErrorCode.ERROR_CODE_PROTOCOL_ERROR
                );
                OpenTransferResponse replacement = openUpload(
                        dispatcher,
                        sessionId,
                        42,
                        transferId,
                        destination
                );
                dispatcher.dispatchForTest(uploadChunkEnvelope(
                        42,
                        replacement.getStreamId(),
                        transferId,
                        0,
                        "abc",
                        true
                ).toByteArray(), true, sessionId);
                assertFileText(root, "uploads/envelope-" + failure + ".bin", "abc");
            } finally {
                deleteAppSandboxRoot(root);
            }
        }
    }

    @Test
    public void terminalDownloadAckErrorsReleaseReaderSlotAndKeepSibling() throws Exception {
        for (int failure = 0; failure < 5; failure += 1) {
            TestMediaCatalog catalog = new TestMediaCatalog("abcdef".getBytes(StandardCharsets.UTF_8));
            RpcDispatcher dispatcher = dispatcher(new DmFileProvider(catalog));
            long sessionId = 400 + failure;
            openDownload(dispatcher, sessionId, 51, "broken-download", 3);
            openDownload(dispatcher, sessionId, 52, "sibling-download", 3);

            RpcEnvelope invalidAck = invalidDownloadAck(failure, 51, "broken-download");
            RpcEnvelope rejected = dispatcher.dispatchForTest(
                    invalidAck.toByteArray(),
                    true,
                    sessionId
            )[0];
            assertError(rejected, downloadFailureCode(failure));
            assertEquals("failure case " + failure, 1, catalog.closeCount);

            openDownload(dispatcher, sessionId, 53, "replacement-download", 3);
            assertTrueCancel(cancel(dispatcher, sessionId, 52, "sibling-download"));
            assertTrueCancel(cancel(dispatcher, sessionId, 53, "replacement-download"));
            assertEquals(3, catalog.closeCount);
        }
    }

    @Test
    public void transferPayloadDirectionMismatchClosesActualCorrelatedRoute() throws Exception {
        TestMediaCatalog catalog = new TestMediaCatalog("abcdef".getBytes(StandardCharsets.UTF_8));
        RpcDispatcher downloadDispatcher = dispatcher(new DmFileProvider(catalog));
        openDownload(downloadDispatcher, 500, 61, "download", 3);

        RpcEnvelope chunkForDownload = uploadChunkEnvelope(61, 61, "download", 0, "abc", true);
        assertError(
                downloadDispatcher.dispatchForTest(chunkForDownload.toByteArray(), true, 500)[0],
                ErrorCode.ERROR_CODE_PROTOCOL_ERROR
        );
        assertEquals(1, catalog.closeCount);

        RpcDispatcher.SessionState readOnly = downloadDispatcher.newSessionStateForTest();
        readOnly.markReadyAndClear(Arrays.asList(Capability.CAPABILITY_FILE_READ));
        openDownload(downloadDispatcher, readOnly, 502, 64, "read-only-download", 3);
        assertError(
                downloadDispatcher.dispatchForTest(
                        uploadChunkEnvelope(64, 64, "read-only-download", 0, "abc", true).toByteArray(),
                        readOnly,
                        502
                )[0],
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY
        );
        openDownload(downloadDispatcher, readOnly, 502, 65, "read-only-replacement", 3);
        assertTrueCancel(cancel(downloadDispatcher, 502, 65, "read-only-replacement"));

        File root = Files.createTempDirectory("droidmatch-direction-mismatch").toFile();
        try {
            RpcDispatcher uploadDispatcher = dispatcher(new DmFileProvider(root));
            openUpload(
                    uploadDispatcher,
                    501,
                    62,
                    "upload",
                    "dm://app-sandbox/uploads/direction.bin"
            );
            RpcEnvelope ackForUpload = transferChunkAckEnvelope(62, 62, "upload", 0, false);
            assertError(
                    uploadDispatcher.dispatchForTest(ackForUpload.toByteArray(), true, 501)[0],
                    ErrorCode.ERROR_CODE_PROTOCOL_ERROR
            );
            openUpload(
                    uploadDispatcher,
                    501,
                    63,
                    "upload",
                    "dm://app-sandbox/uploads/direction.bin"
            );
            assertTrueCancel(cancel(uploadDispatcher, 501, 63, "upload"));

            RpcDispatcher.SessionState writeOnly = uploadDispatcher.newSessionStateForTest();
            writeOnly.markReadyAndClear(Arrays.asList(Capability.CAPABILITY_FILE_WRITE));
            openUpload(
                    uploadDispatcher,
                    writeOnly,
                    503,
                    66,
                    "write-only-upload",
                    "dm://app-sandbox/uploads/write-only.bin"
            );
            assertError(
                    uploadDispatcher.dispatchForTest(
                            transferChunkAckEnvelope(66, 66, "write-only-upload", 0, false).toByteArray(),
                            writeOnly,
                            503
                    )[0],
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY
            );
            openUpload(
                    uploadDispatcher,
                    writeOnly,
                    503,
                    67,
                    "write-only-upload",
                    "dm://app-sandbox/uploads/write-only.bin"
            );
            assertTrueCancel(cancel(uploadDispatcher, 503, 67, "write-only-upload"));
        } finally {
            deleteAppSandboxRoot(root);
        }
    }

}
