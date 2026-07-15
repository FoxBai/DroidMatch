package app.droidmatch.m1;

import static app.droidmatch.m1.RpcDispatcherTestFixtures.transferChunkAckEnvelope;
import static app.droidmatch.m1.RpcDispatcherTestFixtures.uploadChunkEnvelope;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;

import app.droidmatch.proto.v1.CancelTransferRequest;
import app.droidmatch.proto.v1.CancelTransferResponse;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.OpenTransferRequest;
import app.droidmatch.proto.v1.OpenTransferResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.TransferDirection;
import com.google.protobuf.ByteString;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

/** Shared request builders and assertions for terminal transfer-route tests. */
final class RpcTransferFailureTestSupport {
    static final int MALFORMED_PAYLOAD = 0;
    static final int EMPTY_TRANSFER_ID = 1;
    static final int WRONG_TRANSFER_ID = 2;
    static final int WRONG_OFFSET = 3;
    static final int OVERSIZED_CHUNK = 4;
    static final int BAD_CHUNK_CRC = 5;

    private RpcTransferFailureTestSupport() {
    }

    static RpcEnvelope invalidUploadChunk(
            int failure,
            OpenTransferResponse opened,
            String transferId
    ) {
        switch (failure) {
            case MALFORMED_PAYLOAD:
                return uploadChunkEnvelope(21, opened.getStreamId(), transferId, 0, "abc", false)
                        .toBuilder()
                        .setPayload(ByteString.copyFrom(new byte[] {0x0a, (byte) 0x80}))
                        .build();
            case EMPTY_TRANSFER_ID:
                return uploadChunkEnvelope(21, opened.getStreamId(), "", 0, "abc", false);
            case WRONG_TRANSFER_ID:
                return uploadChunkEnvelope(21, opened.getStreamId(), "other", 0, "abc", false);
            case WRONG_OFFSET:
                return uploadChunkEnvelope(21, opened.getStreamId(), transferId, 1, "abc", false);
            case OVERSIZED_CHUNK:
                return uploadChunkEnvelope(21, opened.getStreamId(), transferId, 0, "abcde", false);
            case BAD_CHUNK_CRC:
                return uploadChunkEnvelope(21, opened.getStreamId(), transferId, 0, "abc", false, 0);
            default:
                throw new AssertionError("unknown failure case " + failure);
        }
    }

    static RpcEnvelope invalidDownloadAck(int failure, long requestId, String transferId) {
        switch (failure) {
            case 0:
                return transferChunkAckEnvelope(requestId, requestId, transferId, 3, false)
                        .toBuilder()
                        .setPayload(ByteString.copyFrom(new byte[] {0x0a, (byte) 0x80}))
                        .build();
            case 1:
                return transferChunkAckEnvelope(requestId, requestId, "", 3, false);
            case 2:
                return transferChunkAckEnvelope(requestId, requestId, "other", 3, false);
            case 3:
                return transferChunkAckEnvelope(requestId, requestId, transferId, 2, false);
            case 4:
                return transferChunkAckEnvelope(requestId, requestId, transferId, 3, true);
            default:
                throw new AssertionError("unknown failure case " + failure);
        }
    }

    static ErrorCode uploadFailureCode(int failure) {
        switch (failure) {
            case MALFORMED_PAYLOAD:
            case WRONG_TRANSFER_ID:
                return ErrorCode.ERROR_CODE_PROTOCOL_ERROR;
            case EMPTY_TRANSFER_ID:
            case WRONG_OFFSET:
            case OVERSIZED_CHUNK:
                return ErrorCode.ERROR_CODE_INVALID_ARGUMENT;
            case BAD_CHUNK_CRC:
                return ErrorCode.ERROR_CODE_CHECKSUM_MISMATCH;
            default:
                throw new AssertionError("unknown failure case " + failure);
        }
    }

    static ErrorCode downloadFailureCode(int failure) {
        switch (failure) {
            case 0:
            case 2:
            case 4:
                return ErrorCode.ERROR_CODE_PROTOCOL_ERROR;
            case 1:
            case 3:
                return ErrorCode.ERROR_CODE_INVALID_ARGUMENT;
            default:
                throw new AssertionError("unknown failure case " + failure);
        }
    }

    static RpcDispatcher dispatcher(DmFileProvider provider) {
        return new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                provider,
                null
        );
    }

    static OpenTransferResponse openUpload(
            RpcDispatcher dispatcher,
            long sessionId,
            long requestId,
            String transferId,
            String destination
    ) throws Exception {
        return openUpload(dispatcher, null, sessionId, requestId, transferId, destination);
    }

    static OpenTransferResponse openUpload(
            RpcDispatcher dispatcher,
            RpcDispatcher.SessionState state,
            long sessionId,
            long requestId,
            String transferId,
            String destination
    ) throws Exception {
        RpcEnvelope request = openRequest(
                requestId,
                transferId,
                TransferDirection.TRANSFER_DIRECTION_UPLOAD,
                "mac-local-upload",
                destination,
                3,
                4
        );
        RpcEnvelope responseEnvelope = state == null
                ? dispatcher.dispatchForTest(request.toByteArray(), true, sessionId)[0]
                : dispatcher.dispatchForTest(request.toByteArray(), state, sessionId)[0];
        OpenTransferResponse response = OpenTransferResponse.parseFrom(responseEnvelope.getPayload());
        assertFalse(response.hasError());
        assertEquals(requestId, response.getStreamId());
        return response;
    }

    static void openDownload(
            RpcDispatcher dispatcher,
            long sessionId,
            long requestId,
            String transferId,
            int chunkSize
    ) throws Exception {
        openDownload(dispatcher, null, sessionId, requestId, transferId, chunkSize);
    }

    static void openDownload(
            RpcDispatcher dispatcher,
            RpcDispatcher.SessionState state,
            long sessionId,
            long requestId,
            String transferId,
            int chunkSize
    ) throws Exception {
        RpcEnvelope request = openRequest(
                requestId,
                transferId,
                TransferDirection.TRANSFER_DIRECTION_DOWNLOAD,
                "dm://media-images/media/42",
                "",
                0,
                chunkSize
        );
        RpcEnvelope responseEnvelope = state == null
                ? dispatcher.dispatchForTest(request.toByteArray(), true, sessionId)[0]
                : dispatcher.dispatchForTest(request.toByteArray(), state, sessionId)[0];
        OpenTransferResponse response = OpenTransferResponse.parseFrom(responseEnvelope.getPayload());
        assertFalse(response.hasError());
        assertEquals(requestId, response.getStreamId());
    }

    static CancelTransferResponse cancel(
            RpcDispatcher dispatcher,
            long sessionId,
            long requestId,
            String transferId
    ) throws Exception {
        RpcEnvelope request = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(requestId + 1000)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_CANCEL_TRANSFER_REQUEST)
                .setPayload(CancelTransferRequest.newBuilder()
                        .setTransferId(transferId)
                        .setReason("test cleanup")
                        .build()
                        .toByteString())
                .build();
        return CancelTransferResponse.parseFrom(
                dispatcher.dispatchForTest(request.toByteArray(), true, sessionId)[0].getPayload()
        );
    }

    static void assertTrueCancel(CancelTransferResponse response) {
        assertEquals(true, response.getOk());
    }

    static void assertError(RpcEnvelope envelope, ErrorCode code) {
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_ERROR, envelope.getKind());
        assertEquals(code, envelope.getError().getCode());
    }

    static void assertFileText(File root, String path, String expected) throws Exception {
        assertEquals(
                expected,
                new String(Files.readAllBytes(new File(root, path).toPath()), StandardCharsets.UTF_8)
        );
    }

    private static RpcEnvelope openRequest(
            long requestId,
            String transferId,
            TransferDirection direction,
            String source,
            String destination,
            long expectedSizeBytes,
            int chunkSize
    ) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId(transferId)
                        .setDirection(direction)
                        .setSourcePath(source)
                        .setDestinationPath(destination)
                        .setExpectedSizeBytes(expectedSizeBytes)
                        .setPreferredChunkSizeBytes(chunkSize)
                        .build()
                        .toByteString())
                .build();
    }
}
