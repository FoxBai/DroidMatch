package app.droidmatch.m1;

import static app.droidmatch.m1.DmFileProviderTestFixtures.deleteRecursively;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.CancelTransferRequest;
import app.droidmatch.proto.v1.CancelTransferResponse;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.OpenTransferRequest;
import app.droidmatch.proto.v1.OpenTransferResponse;
import app.droidmatch.proto.v1.PayloadType;
import app.droidmatch.proto.v1.RpcEnvelope;
import app.droidmatch.proto.v1.RpcFrameKind;
import app.droidmatch.proto.v1.TransferDirection;

import java.io.File;
import java.nio.file.Files;

import org.junit.Test;

public final class RpcUploadDestinationLeaseTest {
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
            deleteRecursively(root);
        }
    }

    @Test
    public void processLeaseUsesCanonicalFileIdentityAcrossFacades() throws Exception {
        File root = Files.createTempDirectory("droidmatch-upload-canonical-lease").toFile();
        try {
            File canonicalDirectory = new File(root, "canonical");
            assertTrue(canonicalDirectory.mkdir());
            Files.createSymbolicLink(
                    new File(root, "alias").toPath(),
                    canonicalDirectory.toPath()
            );
            DmFileProvider firstProvider = new DmFileProvider(root);
            DmFileProvider replacementProvider = new DmFileProvider(root);
            DmFileProvider.UploadWriter aliasWriter = firstProvider.openUpload(
                    "dm://app-sandbox/alias/shared.bin",
                    0,
                    1
            );

            try {
                replacementProvider.openUpload(
                        "dm://app-sandbox/canonical/shared.bin",
                        0,
                        1
                );
                throw new AssertionError("expected canonical alias collision");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_ALREADY_EXISTS, exception.code);
            }

            aliasWriter.close();
            replacementProvider.openUpload(
                    "dm://app-sandbox/canonical/shared.bin",
                    0,
                    1
            ).close();
        } finally {
            deleteRecursively(root);
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
}
