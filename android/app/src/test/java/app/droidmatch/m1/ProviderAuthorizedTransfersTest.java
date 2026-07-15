package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.fail;

import app.droidmatch.m1.ProviderUploadLeases.Destination;
import app.droidmatch.proto.v1.ErrorCode;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

import org.junit.Test;

public final class ProviderAuthorizedTransfersTest {
    @Test
    public void fullAndSelectedMediaAccessStayFastAndItemScoped() throws Exception {
        MutableMediaAccess access = new MutableMediaAccess();
        MutableItemVisibility visibility = new MutableItemVisibility();
        ProviderLiveAuthorization authorization = new ProviderMediaReadAuthorization(
                access,
                visibility,
                "provider permission is required"
        );
        TrackingDownloadReader delegate = new TrackingDownloadReader();
        DmFileProvider.DownloadReader reader = ProviderAuthorizedTransfers.download(
                delegate,
                authorization
        );

        assertEquals("first", text(reader.readNextChunk().data));
        assertEquals(0, visibility.checkCount);
        access.current = PermissionStateProvider.MediaReadAccess.SELECTED;
        assertEquals("second", text(reader.readNextChunk().data));
        visibility.visible = false;

        expectPermissionFailure(reader::readNextChunk);
        assertEquals(3, access.checkCount);
        assertEquals(2, visibility.checkCount);
        assertEquals(2, delegate.readCount);
        assertEquals(1, delegate.closeCount);

        try {
            reader.readNextChunk();
            fail("expected the revoked reader to stay closed");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
            assertEquals("download reader is closed", exception.getMessage());
        }
        assertEquals(3, access.checkCount);
        assertEquals(2, visibility.checkCount);
        assertEquals(2, delegate.readCount);

        MutableMediaAccess deniedAccess = new MutableMediaAccess();
        deniedAccess.current = PermissionStateProvider.MediaReadAccess.DENIED;
        MutableItemVisibility deniedVisibility = new MutableItemVisibility();
        ProviderLiveAuthorization denied = new ProviderMediaReadAuthorization(
                deniedAccess,
                deniedVisibility,
                "provider permission is required"
        );
        expectPermissionFailure(() -> {
            denied.requireAuthorized();
            return null;
        });
        assertEquals(1, deniedAccess.checkCount);
        assertEquals(0, deniedVisibility.checkCount);
    }

    @Test
    public void revokedUploadAuthorizationBlocksFinalCommitAndReleasesLease() throws Exception {
        MutableAuthorization authorization = new MutableAuthorization();
        ProviderUploadLeases leases = new ProviderUploadLeases();
        Destination destination = Destination.safAuthority(
                "com.example.documents",
                "root:exports",
                "result.bin"
        );
        TrackingUploadWriter delegate = new TrackingUploadWriter();
        DmFileProvider.UploadWriter writer = leases.openLeased(
                destination,
                () -> ProviderAuthorizedTransfers.upload(delegate, authorization)
        );

        writer.writeChunk(0, bytes("ab"), false);
        authorization.granted = false;
        expectPermissionFailure(() -> {
            writer.writeChunk(2, bytes("cd"), true);
            return null;
        });

        assertEquals("ab", delegate.text());
        assertEquals(0, delegate.commitCount);
        assertEquals(1, delegate.closeCount);
        assertEquals(2, authorization.checkCount);

        authorization.granted = true;
        TrackingUploadWriter replacement = new TrackingUploadWriter();
        DmFileProvider.UploadWriter replacementWriter = leases.openLeased(
                destination,
                () -> ProviderAuthorizedTransfers.upload(replacement, authorization)
        );
        replacementWriter.writeChunk(0, bytes("abcd"), true);

        assertEquals("abcd", replacement.text());
        assertEquals(1, replacement.commitCount);
        assertEquals(1, replacement.closeCount);
        leases.openLeased(destination, TrackingUploadWriter::new).close();
    }

    private static void expectPermissionFailure(ThrowingAction action) throws Exception {
        try {
            action.run();
            fail("expected live provider authorization failure");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, exception.code);
            assertEquals("provider permission is required", exception.getMessage());
        }
    }

    private static byte[] bytes(String value) {
        return value.getBytes(StandardCharsets.UTF_8);
    }

    private static String text(byte[] value) {
        return new String(value, StandardCharsets.UTF_8);
    }

    @FunctionalInterface
    private interface ThrowingAction {
        DmFileProvider.DownloadChunk run() throws Exception;
    }

    private static final class MutableAuthorization implements ProviderLiveAuthorization {
        private boolean granted = true;
        private int checkCount;

        @Override
        public void requireAuthorized() throws DmFileProvider.ProviderCatalogException {
            checkCount += 1;
            if (!granted) {
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "provider permission is required"
                );
            }
        }
    }

    private static final class MutableMediaAccess
            implements ProviderMediaReadAuthorization.MediaAccessSource {
        private PermissionStateProvider.MediaReadAccess current =
                PermissionStateProvider.MediaReadAccess.FULL;
        private int checkCount;

        @Override
        public PermissionStateProvider.MediaReadAccess currentAccess() {
            checkCount += 1;
            return current;
        }
    }

    private static final class MutableItemVisibility
            implements ProviderMediaReadAuthorization.ItemVisibility {
        private boolean visible = true;
        private int checkCount;

        @Override
        public boolean currentItemVisible() {
            checkCount += 1;
            return visible;
        }
    }

    private static final class TrackingDownloadReader
            implements DmFileProvider.DownloadReader {
        private int readCount;
        private int closeCount;

        @Override
        public DmFileProvider.DownloadChunk readNextChunk() {
            readCount += 1;
            return new DmFileProvider.DownloadChunk(
                    bytes(readCount == 1 ? "first" : "second"),
                    11,
                    0,
                    "opaque",
                    readCount == 2
            );
        }

        @Override
        public void close() {
            closeCount += 1;
        }
    }

    private static final class TrackingUploadWriter
            implements DmFileProvider.UploadWriter {
        private final ByteArrayOutputStream output = new ByteArrayOutputStream();
        private long nextOffsetBytes;
        private int commitCount;
        private int closeCount;

        @Override
        public long nextOffsetBytes() {
            return nextOffsetBytes;
        }

        @Override
        public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
                throws DmFileProvider.ProviderCatalogException {
            if (offsetBytes != nextOffsetBytes) {
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "unexpected test offset"
                );
            }
            output.write(data, 0, data.length);
            nextOffsetBytes += data.length;
            if (finalChunk) {
                commitCount += 1;
            }
        }

        @Override
        public void close() {
            closeCount += 1;
        }

        private String text() {
            return new String(output.toByteArray(), StandardCharsets.UTF_8);
        }
    }
}
