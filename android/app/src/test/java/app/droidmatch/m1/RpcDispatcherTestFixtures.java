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

final class RpcDispatcherTestFixtures {
    private RpcDispatcherTestFixtures() {}

    static RpcEnvelope uploadChunkEnvelope(
            long requestId,
            long streamId,
            String transferId,
            long offsetBytes,
            String text,
            boolean finalChunk
    ) {
        byte[] data = text.getBytes(StandardCharsets.UTF_8);
        return uploadChunkEnvelope(
                requestId,
                streamId,
                transferId,
                offsetBytes,
                text,
                finalChunk,
                crc32(data)
        );
    }

    static RpcDispatcher pairedDispatcher(byte[] pairingId, byte[] pairingKey) {
        PairingKeyProvider provider = candidate -> Arrays.equals(candidate, pairingId)
                ? Arrays.copyOf(pairingKey, pairingKey.length)
                : null;
        return new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                null,
                null,
                SessionAuthenticationMode.PAIRED_REQUIRED,
                provider,
                null,
                null,
                testDeviceIdentity()
        );
    }

    static RpcDispatcher pairedDispatcher(
            byte[] pairingId,
            byte[] pairingKey,
            AuthenticationRateLimiter limiter
    ) {
        PairingKeyProvider provider = candidate -> Arrays.equals(candidate, pairingId)
                ? Arrays.copyOf(pairingKey, pairingKey.length)
                : null;
        return new RpcDispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                null,
                null,
                null,
                SessionAuthenticationMode.PAIRED_REQUIRED,
                provider,
                null,
                null,
                testDeviceIdentity(),
                limiter
        );
    }

    static DeviceIdentityProvider testDeviceIdentity() {
        return new DeviceIdentityProvider() {
            @Override
            public byte[] publicKeyX963Representation() {
                return new byte[PairingAuthenticator.PUBLIC_KEY_LENGTH];
            }

            @Override
            public byte[] fingerprint() {
                return sequentialBytes(0x50, PairingAuthenticator.DIGEST_LENGTH);
            }

            @Override
            public byte[] signPairingTranscript(byte[] transcript) {
                return new byte[] {0x01};
            }
        };
    }

    static final class FakeAuthenticationClock implements AuthenticationRateLimiter.Clock {
        long nowMillis;

        @Override
        public long nowMillis() {
            return nowMillis;
        }

        void advance(long millis) {
            nowMillis += millis;
        }
    }

    static RpcEnvelope clientHelloEnvelope(long requestId, byte[] nonce, byte[] pairingId) {
        return clientHelloEnvelope(
                requestId,
                nonce,
                pairingId,
                Capability.CAPABILITY_DIAGNOSTICS
        );
    }

    static RpcEnvelope clientHelloEnvelope(
            long requestId,
            byte[] nonce,
            byte[] pairingId,
            Capability... requestedCapabilities
    ) {
        ClientHello hello = ClientHello.newBuilder()
                .setClientName("DroidMatchTests")
                .setClientVersion("test")
                .setProtocolMajor(1)
                .setProtocolMinor(0)
                .setTransport(TransportKind.TRANSPORT_KIND_ADB)
                .addAllRequestedCapabilities(Arrays.asList(requestedCapabilities))
                .setSessionNonce(ByteString.copyFrom(nonce))
                .setPairingId(ByteString.copyFrom(pairingId))
                .build();
        return RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_CLIENT_HELLO)
                .setPayload(hello.toByteString())
                .build();
    }

    static RpcEnvelope authenticationEnvelope(long requestId, byte[] pairingId, byte[] clientProof) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_AUTHENTICATE_SESSION_REQUEST)
                .setPayload(AuthenticateSessionRequest.newBuilder()
                        .setPairingId(ByteString.copyFrom(pairingId))
                        .setClientProof(ByteString.copyFrom(clientProof))
                        .build()
                        .toByteString())
                .build();
    }

    static RpcEnvelope heartbeatEnvelope(long requestId) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_HEARTBEAT_REQUEST)
                .setPayload(HeartbeatRequest.newBuilder().setMonotonicMillis(requestId).build().toByteString())
                .build();
    }

    static RpcEnvelope downloadOpenEnvelope(
            long requestId,
            String transferId,
            int preferredChunkSizeBytes
    ) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_REQUEST)
                .setRequestId(requestId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_OPEN_TRANSFER_REQUEST)
                .setPayload(OpenTransferRequest.newBuilder()
                        .setTransferId(transferId)
                        .setDirection(TransferDirection.TRANSFER_DIRECTION_DOWNLOAD)
                        .setSourcePath("dm://media-images/media/42")
                        .setPreferredChunkSizeBytes(preferredChunkSizeBytes)
                        .build()
                        .toByteString())
                .build();
    }

    static byte[] sequentialBytes(int start, int count) {
        byte[] bytes = new byte[count];
        for (int index = 0; index < count; index += 1) {
            bytes[index] = (byte) (start + index);
        }
        return bytes;
    }

    static RpcEnvelope uploadChunkEnvelope(
            long requestId,
            long streamId,
            String transferId,
            long offsetBytes,
            String text,
            boolean finalChunk,
            int crc32
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
                        .setCrc32(crc32)
                        .setFinalChunk(finalChunk)
                        .build()
                        .toByteString())
                .build();
    }

    static RpcEnvelope transferChunkAckEnvelope(
            long requestId,
            long streamId,
            String transferId,
            long nextOffsetBytes,
            boolean finalAck
    ) {
        return RpcEnvelope.newBuilder()
                .setFrameVersion(1)
                .setKind(RpcFrameKind.RPC_FRAME_KIND_STREAM)
                .setRequestId(requestId)
                .setStreamId(streamId)
                .setPayloadType(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK_ACK)
                .setPayload(TransferChunkAck.newBuilder()
                        .setTransferId(transferId)
                        .setNextOffsetBytes(nextOffsetBytes)
                        .setFinalAck(finalAck)
                        .build()
                        .toByteString())
                .build();
    }

    static void assertDownloadChunk(
            RpcEnvelope envelope,
            String transferId,
            long offsetBytes,
            String text,
            boolean finalChunk
    ) throws Exception {
        assertEquals(RpcFrameKind.RPC_FRAME_KIND_STREAM, envelope.getKind());
        assertEquals(PayloadType.PAYLOAD_TYPE_TRANSFER_CHUNK, envelope.getPayloadType());
        TransferChunk chunk = TransferChunk.parseFrom(envelope.getPayload());
        byte[] expectedData = text.getBytes(StandardCharsets.UTF_8);
        assertEquals(transferId, chunk.getTransferId());
        assertEquals(offsetBytes, chunk.getOffsetBytes());
        assertEquals(text, new String(chunk.getData().toByteArray(), StandardCharsets.UTF_8));
        assertEquals(crc32(expectedData), chunk.getCrc32());
        assertEquals(finalChunk, chunk.getFinalChunk());
    }

    static int crc32(byte[] data) {
        CRC32 crc32 = new CRC32();
        crc32.update(data);
        return (int) crc32.getValue();
    }

    static TransferFingerprint testSourceFingerprint() {
        return TransferFingerprint.newBuilder()
                .setSizeBytes(6)
                .setModifiedUnixMillis(1_700_000_000_000L)
                .setProviderEtag("test-etag")
                .build();
    }

    static void deleteRecursively(File file) {
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

    static class TestMediaCatalog implements ProviderMediaCatalog {
        final byte[] data;
        boolean downloadAvailable = true;
        long modifiedUnixMillis = 1_700_000_000_000L;
        String providerEtag = "test-etag";
        int openChunkSizeBytes;
        int closeCount;
        DmFileProvider.RootKind uploadRootKind;
        String uploadDisplayName;
        ByteArrayOutputStream uploadedBytes;

        TestMediaCatalog(byte[] data) {
            this.data = data;
        }

        @Override
        public boolean canUploadMedia(DmFileProvider.RootKind rootKind) {
            return rootKind == DmFileProvider.RootKind.MEDIA_IMAGES
                    || rootKind == DmFileProvider.RootKind.MEDIA_VIDEOS;
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
            if (!downloadAvailable) {
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "content://media/external/images/private/secret.jpg is not available"
                );
            }
            int start = (int) offsetBytes;
            int end = Math.min(start + chunkSizeBytes, data.length);
            return new DmFileProvider.DownloadChunk(
                    Arrays.copyOfRange(data, start, end),
                    data.length,
                    modifiedUnixMillis,
                    providerEtag,
                    end >= data.length
            );
        }

        @Override
        public DmFileProvider.DownloadReader openMedia(
                DmFileProvider.RootKind rootKind,
                long mediaId,
                long offsetBytes,
                int chunkSizeBytes
        ) throws DmFileProvider.ProviderCatalogException {
            if (!downloadAvailable) {
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "content://media/external/images/private/secret.jpg is not available"
                );
            }
            openChunkSizeBytes = chunkSizeBytes;
            return new DmFileProvider.DownloadReader() {
                int offset = (int) offsetBytes;
                boolean closed;

                @Override
                public DmFileProvider.DownloadChunk readNextChunk() {
                    int end = Math.min(offset + chunkSizeBytes, data.length);
                    byte[] chunk = Arrays.copyOfRange(data, offset, end);
                    offset = end;
                    return new DmFileProvider.DownloadChunk(
                            chunk,
                            data.length,
                            modifiedUnixMillis,
                            providerEtag,
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

        @Override
        public DmFileProvider.UploadWriter openUploadMedia(
                DmFileProvider.RootKind rootKind,
                String displayName,
                long offsetBytes,
                long expectedSizeBytes
        ) {
            this.uploadRootKind = rootKind;
            this.uploadDisplayName = displayName;
            this.uploadedBytes = new ByteArrayOutputStream();
            return new DmFileProvider.UploadWriter() {
                long nextOffsetBytes = offsetBytes;
                boolean closed;

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

        String uploadedText() {
            return new String(uploadedBytes.toByteArray(), StandardCharsets.UTF_8);
        }
    }

    static final class TestSafCatalog implements ProviderSafCatalog {
        final DmFileProvider.SafRoot root;
        String uploadParentDocumentId;
        String uploadDisplayName;
        String uploadTransferId;
        ByteArrayOutputStream uploadedBytes;

        TestSafCatalog(DmFileProvider.SafRoot root) {
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
                String transferId,
                long offsetBytes,
                long expectedSizeBytes
        ) {
            this.uploadParentDocumentId = parentDocumentId;
            this.uploadDisplayName = displayName;
            this.uploadTransferId = transferId;
            this.uploadedBytes = new ByteArrayOutputStream();
            return new DmFileProvider.UploadWriter() {
                long nextOffsetBytes = offsetBytes;
                boolean closed;

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

        String uploadedText() {
            return new String(uploadedBytes.toByteArray(), StandardCharsets.UTF_8);
        }
    }
}
