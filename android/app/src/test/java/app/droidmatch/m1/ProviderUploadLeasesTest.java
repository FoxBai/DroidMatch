package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.fail;

import app.droidmatch.m1.ProviderUploadLeases.Destination;
import app.droidmatch.m1.RpcTransferStreams.Upload;
import app.droidmatch.proto.v1.ErrorCode;

import org.junit.Test;

public final class ProviderUploadLeasesTest {
    @Test
    public void failedOpenReleasesDestinationForNextWriter() throws Exception {
        ProviderUploadLeases leases = new ProviderUploadLeases();
        Destination destination = Destination.appSandbox("/canonical/export.bin");

        try {
            leases.openLeased(destination, () -> {
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "injected open failure"
                );
            });
            fail("expected injected open failure");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_INTERNAL, exception.code);
        }

        CloseProbeWriter next = new CloseProbeWriter();
        leases.openLeased(destination, () -> next).close();
        assertEquals(1, next.closeCount);
    }

    @Test
    public void finalCommitAndWriteFailureBothReleaseDestination() throws Exception {
        ProviderUploadLeases leases = new ProviderUploadLeases();
        Destination destination = Destination.appSandbox("/canonical/export.bin");
        CloseProbeWriter committed = new CloseProbeWriter();
        DmFileProvider.UploadWriter first = leases.openLeased(destination, () -> committed);

        first.writeChunk(0, new byte[] {1}, true);
        assertEquals(1, committed.closeCount);

        CloseProbeWriter failed = new CloseProbeWriter();
        failed.writeFailure = new DmFileProvider.ProviderCatalogException(
                ErrorCode.ERROR_CODE_INTERNAL,
                "injected write failure"
        );
        DmFileProvider.UploadWriter second = leases.openLeased(destination, () -> failed);
        try {
            second.writeChunk(0, new byte[] {2}, false);
            fail("expected injected write failure");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_INTERNAL, exception.code);
        }
        assertEquals(1, failed.closeCount);

        leases.openLeased(destination, CloseProbeWriter::new).close();
    }

    @Test
    public void repeatedCloseCannotReleaseAReplacementOwner() throws Exception {
        ProviderUploadLeases leases = new ProviderUploadLeases();
        Destination destination = Destination.appSandbox("/canonical/export.bin");
        DmFileProvider.UploadWriter first = leases.openLeased(
                destination,
                CloseProbeWriter::new
        );
        first.close();
        DmFileProvider.UploadWriter replacement = leases.openLeased(
                destination,
                CloseProbeWriter::new
        );

        first.close();
        expectActiveDestination(leases, destination);

        replacement.close();
        leases.openLeased(destination, CloseProbeWriter::new).close();
    }

    @Test
    public void registrySessionTeardownReleasesLeasedWriter() throws Exception {
        ProviderUploadLeases leases = new ProviderUploadLeases();
        Destination destination = Destination.appSandbox("/canonical/export.bin");
        RpcTransferRegistry registry = new RpcTransferRegistry();
        CloseProbeWriter delegate = new CloseProbeWriter();
        DmFileProvider.UploadWriter leased = leases.openLeased(destination, () -> delegate);
        registry.installUpload(10, 1, new Upload(1, "session-upload", leased, 256));

        registry.closeSession(10);

        assertEquals(1, delegate.closeCount);
        leases.openLeased(destination, CloseProbeWriter::new).close();
    }

    @Test
    public void sameSafAuthorityAndParentShareOneProviderDestination() throws Exception {
        ProviderUploadLeases leases = new ProviderUploadLeases();
        Destination throughParentGrant = Destination.safAuthority(
                "com.android.externalstorage.documents",
                "primary:Documents/Shared",
                "export.bin"
        );
        Destination throughChildGrant = Destination.safAuthority(
                "com.android.externalstorage.documents",
                "primary:Documents/Shared",
                "export.bin"
        );
        DmFileProvider.UploadWriter first = leases.openLeased(
                throughParentGrant,
                CloseProbeWriter::new
        );

        expectActiveDestination(leases, throughChildGrant);

        first.close();
        leases.openLeased(throughChildGrant, CloseProbeWriter::new).close();
    }

    private static void expectActiveDestination(
            ProviderUploadLeases leases,
            Destination destination
    ) throws Exception {
        try {
            leases.openLeased(destination, CloseProbeWriter::new);
            fail("expected active upload destination to be rejected");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_ALREADY_EXISTS, exception.code);
            assertEquals("upload destination is already active", exception.getMessage());
        }
    }

    private static final class CloseProbeWriter implements DmFileProvider.UploadWriter {
        private int closeCount;
        private DmFileProvider.ProviderCatalogException writeFailure;

        @Override
        public long nextOffsetBytes() {
            return 0;
        }

        @Override
        public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
                throws DmFileProvider.ProviderCatalogException {
            if (writeFailure != null) {
                throw writeFailure;
            }
        }

        @Override
        public void close() {
            closeCount += 1;
        }
    }
}
