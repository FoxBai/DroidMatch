package app.droidmatch.m1;

import static app.droidmatch.m1.DmFileProviderTestFixtures.deleteAppSandboxRoot;
import static app.droidmatch.m1.RpcDispatcherTestFixtures.heartbeatEnvelope;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.CancelTransferRequest;
import app.droidmatch.proto.v1.CancelTransferResponse;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.HeartbeatResponse;
import app.droidmatch.proto.v1.OpenTransferRequest;
import app.droidmatch.proto.v1.OpenTransferResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.TransferDirection;

import java.io.File;
import java.nio.file.Files;
import java.util.Collections;

import org.junit.Test;

public final class RpcUploadDestinationLeaseTest {
    @Test
    public void failedMediaCancelRetainsTransferAndLeaseUntilVerifiedRetry() throws Exception {
        RetryingCancelMediaCatalog catalog = new RetryingCancelMediaCatalog();
        RpcDispatcher dispatcher = new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                new DmFileProvider(catalog),
                null
        );

        OpenTransferResponse shared = open(
                dispatcher, 30, 61, "media-shared", "dm://media-images/shared.jpg"
        );
        OpenTransferResponse sibling = open(
                dispatcher, 30, 62, "media-sibling", "dm://media-images/sibling.jpg"
        );
        assertFalse(shared.hasError());
        assertFalse(sibling.hasError());

        CancelTransferResponse failed = cancel(dispatcher, 30, 63, "media-shared");
        assertFalse(failed.getOk());
        assertEquals(ErrorCode.ERROR_CODE_INTERNAL, failed.getError().getCode());
        assertEquals("upload failed", failed.getError().getMessage());
        assertEquals(1, catalog.firstSharedWriter.cancelCount);
        assertFalse(catalog.firstSharedWriter.closed);

        RpcEnvelope heartbeat = dispatcher.dispatchForTest(
                heartbeatEnvelope(64).toByteArray(), true, 30
        )[0];
        assertEquals(PayloadType.PAYLOAD_TYPE_HEARTBEAT_RESPONSE, heartbeat.getPayloadType());
        assertEquals(64, HeartbeatResponse.parseFrom(heartbeat.getPayload()).getMonotonicMillis());
        assertTrue(cancel(dispatcher, 30, 65, "media-sibling").getOk());

        OpenTransferResponse collision = open(
                dispatcher, 40, 66, "media-collision", "dm://media-images/shared.jpg"
        );
        assertEquals(ErrorCode.ERROR_CODE_ALREADY_EXISTS, collision.getError().getCode());

        assertTrue(cancel(dispatcher, 30, 67, "media-shared").getOk());
        assertEquals(2, catalog.firstSharedWriter.cancelCount);
        assertTrue(catalog.firstSharedWriter.closed);

        OpenTransferResponse reacquired = open(
                dispatcher, 40, 68, "media-reacquired", "dm://media-images/shared.jpg"
        );
        assertFalse(reacquired.hasError());
        assertTrue(cancel(dispatcher, 40, 69, "media-reacquired").getOk());
    }

    @Test
    public void sharedProviderRejectsSameDestinationAcrossSessionsWithoutBlockingOthers()
            throws Exception {
        File root = Files.createTempDirectory("droidmatch-upload-lease").toFile();
        try {
            RpcDispatcher dispatcher = new RpcDispatcher(
                    new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                    null,
                    new DmFileProvider(root),
                    null
            );

            OpenTransferResponse first = open(
                    dispatcher, 10, 31, "first", "dm://app-sandbox/exports/shared.bin"
            );
            assertFalse(first.hasError());

            OpenTransferResponse collision = open(
                    dispatcher, 20, 41, "collision", "dm://app-sandbox/exports/shared.bin"
            );
            assertEquals(ErrorCode.ERROR_CODE_ALREADY_EXISTS, collision.getError().getCode());
            assertEquals("upload destination is already active", collision.getError().getMessage());

            OpenTransferResponse independent = open(
                    dispatcher, 20, 42, "independent", "dm://app-sandbox/exports/other.bin"
            );
            assertFalse(independent.hasError());

            assertTrue(cancel(dispatcher, 10, 51, "first").getOk());
            OpenTransferResponse reacquired = open(
                    dispatcher, 20, 43, "reacquired", "dm://app-sandbox/exports/shared.bin"
            );
            assertFalse(reacquired.hasError());

            assertTrue(cancel(dispatcher, 20, 52, "independent").getOk());
            assertTrue(cancel(dispatcher, 20, 53, "reacquired").getOk());
        } finally {
            deleteAppSandboxRoot(root);
        }
    }

    @Test
    public void processLeaseRejectsSymbolicAliasesAndKeepsCanonicalDestinationUsable() throws Exception {
        File root = Files.createTempDirectory("droidmatch-upload-canonical-lease").toFile();
        java.nio.file.Path alias = new File(root, "alias").toPath();
        try {
            File canonicalDirectory = new File(root, "canonical");
            assertTrue(canonicalDirectory.mkdir());
            Files.createSymbolicLink(
                    alias,
                    canonicalDirectory.toPath()
            );
            DmFileProvider firstProvider = new DmFileProvider(root);
            DmFileProvider replacementProvider = new DmFileProvider(root);

            try {
                firstProvider.openUpload(
                        "dm://app-sandbox/alias/shared.bin",
                        0,
                        1
                );
                throw new AssertionError("expected symbolic alias to be rejected");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
            }

            replacementProvider.openUpload(
                    "dm://app-sandbox/canonical/shared.bin",
                    0,
                    1
            ).close();
        } finally {
            Files.deleteIfExists(alias);
            deleteAppSandboxRoot(root);
        }
    }

    private static OpenTransferResponse open(
            RpcDispatcher dispatcher,
            long sessionId,
            long requestId,
            String transferId,
            String destinationPath
    ) throws Exception {
        RpcEnvelope request = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId(transferId)
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_UPLOAD)
                        .setSourcePath("mac-local-upload")
                        .setDestinationPath(destinationPath)
                        .setExpectedSizeBytes(1)
                        .build()
                        .toByteString())
                .build();
        RpcEnvelope[] responses = dispatcher.dispatchForTest(
                request.toByteArray(),
                true,
                sessionId
        );
        assertEquals(1, responses.length);
        return OpenTransferResponse.parseFrom(responses[0].getPayload());
    }

    private static CancelTransferResponse cancel(
            RpcDispatcher dispatcher,
            long sessionId,
            long requestId,
            String transferId
    ) throws Exception {
        RpcEnvelope request = RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_CANCEL_TRANSFER_REQUEST)
                .setPayload(CancelTransferRequest.newBuilder()
                        .setTransferId(transferId)
                        .setReason("unit-test")
                        .build()
                        .toByteString())
                .build();
        RpcEnvelope[] responses = dispatcher.dispatchForTest(
                request.toByteArray(),
                true,
                sessionId
        );
        assertEquals(1, responses.length);
        return CancelTransferResponse.parseFrom(responses[0].getPayload());
    }

    private static final class RetryingCancelMediaCatalog implements ProviderMediaCatalog {
        private int sharedOpenCount;
        private RetryingCancelWriter firstSharedWriter;

        @Override
        public boolean canUploadMedia(DmFileProvider.RootKind rootKind) {
            return true;
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
        ) throws DmFileProvider.ProviderCatalogException {
            throw new DmFileProvider.ProviderCatalogException(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "media item is not available"
            );
        }

        @Override
        public DmFileProvider.UploadWriter openUploadMedia(
                DmFileProvider.RootKind rootKind,
                String displayName,
                long offsetBytes,
                long expectedSizeBytes
        ) {
            boolean failFirstCancel = false;
            if ("shared.jpg".equals(displayName)) {
                sharedOpenCount += 1;
                failFirstCancel = sharedOpenCount == 1;
            }
            RetryingCancelWriter writer = new RetryingCancelWriter(failFirstCancel);
            if (failFirstCancel) {
                firstSharedWriter = writer;
            }
            return writer;
        }
    }

    private static final class RetryingCancelWriter implements DmFileProvider.UploadWriter {
        private final boolean failFirstCancel;
        private int cancelCount;
        private boolean closed;

        private RetryingCancelWriter(boolean failFirstCancel) {
            this.failFirstCancel = failFirstCancel;
        }

        @Override
        public long nextOffsetBytes() {
            return 0;
        }

        @Override
        public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk) {
        }

        @Override
        public void cancel() throws DmFileProvider.ProviderCatalogException {
            cancelCount += 1;
            if (failFirstCancel && cancelCount == 1) {
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "content://private/provider detail"
                );
            }
            closed = true;
        }

        @Override
        public void close() {
            closed = true;
        }
    }
}
