package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.fail;

import app.droidmatch.m1.RpcTransferStreams.Upload;
import app.droidmatch.proto.v1.ErrorCode;

import java.util.Arrays;

import org.junit.Test;

public final class ProviderPathCoordinatorTest {
    @Test
    public void failedOpenReleasesDestinationForNextWriter() throws Exception {
        ProviderPathCoordinator coordinator = new ProviderPathCoordinator();
        ProviderPathCoordinator.Claim destination =
                ProviderPathCoordinator.Claim.appSandbox("canonical/export.bin");

        try {
            coordinator.openLeased(destination, () -> {
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
        coordinator.openLeased(destination, () -> next).close();
        assertEquals(1, next.closeCount);
    }

    @Test
    public void finalCommitAndWriteFailureBothReleaseDestination() throws Exception {
        ProviderPathCoordinator coordinator = new ProviderPathCoordinator();
        ProviderPathCoordinator.Claim destination =
                ProviderPathCoordinator.Claim.appSandbox("canonical/export.bin");
        CloseProbeWriter committed = new CloseProbeWriter();
        DmFileProvider.UploadWriter first =
                coordinator.openLeased(destination, () -> committed);

        first.writeChunk(0, new byte[] {1}, true);
        assertEquals(1, committed.closeCount);

        CloseProbeWriter failed = new CloseProbeWriter();
        failed.writeFailure = new DmFileProvider.ProviderCatalogException(
                ErrorCode.ERROR_CODE_INTERNAL,
                "injected write failure"
        );
        DmFileProvider.UploadWriter second =
                coordinator.openLeased(destination, () -> failed);
        try {
            second.writeChunk(0, new byte[] {2}, false);
            fail("expected injected write failure");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_INTERNAL, exception.code);
        }
        assertEquals(1, failed.closeCount);

        coordinator.openLeased(destination, CloseProbeWriter::new).close();
    }

    @Test
    public void repeatedCloseCannotReleaseAReplacementOwner() throws Exception {
        ProviderPathCoordinator coordinator = new ProviderPathCoordinator();
        ProviderPathCoordinator.Claim destination =
                ProviderPathCoordinator.Claim.appSandbox("canonical/export.bin");
        DmFileProvider.UploadWriter first = coordinator.openLeased(
                destination,
                CloseProbeWriter::new
        );
        first.close();
        DmFileProvider.UploadWriter replacement = coordinator.openLeased(
                destination,
                CloseProbeWriter::new
        );

        first.close();
        expectActiveDestination(coordinator, destination);

        replacement.close();
        coordinator.openLeased(destination, CloseProbeWriter::new).close();
    }

    @Test
    public void registrySessionTeardownReleasesLeasedWriter() throws Exception {
        ProviderPathCoordinator coordinator = new ProviderPathCoordinator();
        ProviderPathCoordinator.Claim destination =
                ProviderPathCoordinator.Claim.appSandbox("canonical/export.bin");
        RpcTransferRegistry registry = new RpcTransferRegistry();
        CloseProbeWriter delegate = new CloseProbeWriter();
        DmFileProvider.UploadWriter leased =
                coordinator.openLeased(destination, () -> delegate);
        registry.installUpload(10, 1, new Upload(1, "session-upload", leased, 256));

        registry.closeSession(10);

        assertEquals(1, delegate.closeCount);
        coordinator.openLeased(destination, CloseProbeWriter::new).close();
    }

    @Test
    public void ancestorMutationConflictsWithoutBlockingAndReleasesAfterward()
            throws Exception {
        ProviderPathCoordinator coordinator = new ProviderPathCoordinator();
        ProviderPathCoordinator.Claim upload =
                ProviderPathCoordinator.Claim.appSandbox("exports/current/result.bin");
        DmFileProvider.UploadWriter writer = coordinator.openLeased(
                upload,
                CloseProbeWriter::new
        );

        expectActiveOperation(
                coordinator,
                Arrays.asList(
                        ProviderPathCoordinator.Claim.appSandbox("exports/current"),
                        ProviderPathCoordinator.Claim.appSandbox("exports/renamed")
                )
        );

        writer.close();
        try {
            coordinator.runLeased(
                    ProviderPathCoordinator.Claim.appSandbox("exports/current"),
                    () -> {
                        throw new DmFileProvider.ProviderCatalogException(
                                ErrorCode.ERROR_CODE_INTERNAL,
                                "injected mutation failure"
                        );
                    }
            );
            fail("expected injected mutation failure");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_INTERNAL, exception.code);
        }
        coordinator.runLeased(
                ProviderPathCoordinator.Claim.appSandbox("exports/current"),
                () -> {
                }
        );
    }

    @Test
    public void safAncestorConflictsAndIncompleteLineageIsOnlyTemporary()
            throws Exception {
        ProviderPathCoordinator coordinator = new ProviderPathCoordinator();
        DmFileProvider.SafRoot root = new DmFileProvider.SafRoot(
                "documents",
                "root",
                "Documents",
                true
        );
        ProviderPathCoordinator.Claim descendant =
                ProviderPathCoordinator.Claim.safChild(
                        root,
                        Arrays.asList(root),
                        "child-directory",
                        "nested.bin",
                        Arrays.asList(
                                "child-directory",
                                "ancestor-directory",
                                root.documentId
                        )
                );
        ProviderPathCoordinator.Claim ancestor =
                ProviderPathCoordinator.Claim.safDocument(
                        root,
                        Arrays.asList(root),
                        "ancestor-directory",
                        root.documentId,
                        "ancestor",
                        Arrays.asList(root.documentId)
                );
        DmFileProvider.UploadWriter descendantWriter =
                coordinator.openLeased(descendant, CloseProbeWriter::new);
        expectActiveOperation(coordinator, Arrays.asList(ancestor));
        descendantWriter.close();
        coordinator.runLeased(ancestor, () -> {
        });

        ProviderPathCoordinator.Claim incomplete =
                ProviderPathCoordinator.Claim.safChild(
                        root,
                        Arrays.asList(root),
                        "unknown-parent",
                        "first.bin",
                        null
                );
        ProviderPathCoordinator.Claim separate =
                ProviderPathCoordinator.Claim.safChild(
                        root,
                        Arrays.asList(root),
                        root.documentId,
                        "second.bin",
                        Arrays.asList(root.documentId)
                );
        DmFileProvider.UploadWriter writer =
                coordinator.openLeased(incomplete, CloseProbeWriter::new);

        expectActiveDestination(coordinator, separate);

        writer.close();
        coordinator.openLeased(separate, CloseProbeWriter::new).close();
    }

    @Test
    public void overlappingSafRootsClaimTheirWholeProviderAuthority() throws Exception {
        ProviderPathCoordinator coordinator = new ProviderPathCoordinator();
        DmFileProvider.SafRoot broad = new DmFileProvider.SafRoot(
                "broad",
                "documents.provider",
                "root",
                "Documents",
                true
        );
        DmFileProvider.SafRoot nested = new DmFileProvider.SafRoot(
                "nested",
                "documents.provider",
                "nested-root",
                "Nested",
                true
        );
        java.util.List<DmFileProvider.SafRoot> overlappingRoots =
                Arrays.asList(broad, nested);
        ProviderPathCoordinator.Claim nestedUpload =
                ProviderPathCoordinator.Claim.safChild(
                        nested,
                        overlappingRoots,
                        nested.documentId,
                        "result.bin",
                        Arrays.asList(nested.documentId)
                );
        ProviderPathCoordinator.Claim broadAncestorDelete =
                ProviderPathCoordinator.Claim.safDocument(
                        broad,
                        overlappingRoots,
                        "broad-ancestor",
                        broad.documentId,
                        "ancestor",
                        Arrays.asList(broad.documentId)
                );
        DmFileProvider.UploadWriter writer =
                coordinator.openLeased(nestedUpload, CloseProbeWriter::new);

        expectActiveOperation(coordinator, Arrays.asList(broadAncestorDelete));

        DmFileProvider.SafRoot otherProvider = new DmFileProvider.SafRoot(
                "other",
                "other.provider",
                "other-root",
                "Other",
                true
        );
        ProviderPathCoordinator.Claim unrelated =
                ProviderPathCoordinator.Claim.safChild(
                        otherProvider,
                        Arrays.asList(otherProvider),
                        otherProvider.documentId,
                        "unrelated.bin",
                        Arrays.asList(otherProvider.documentId)
                );
        coordinator.openLeased(unrelated, CloseProbeWriter::new).close();

        writer.close();
        coordinator.runLeased(broadAncestorDelete, () -> {
        });

        ProviderPathCoordinator.Claim narrowNested =
                ProviderPathCoordinator.Claim.safChild(
                        nested,
                        Arrays.asList(nested),
                        nested.documentId,
                        "narrow.bin",
                        Arrays.asList(nested.documentId)
                );
        ProviderPathCoordinator.Claim narrowBroad =
                ProviderPathCoordinator.Claim.safDocument(
                        broad,
                        Arrays.asList(broad),
                        "separate-id",
                        broad.documentId,
                        "separate",
                        Arrays.asList(broad.documentId)
                );
        DmFileProvider.UploadWriter narrowWriter =
                coordinator.openLeased(narrowNested, CloseProbeWriter::new);
        expectActiveOperation(coordinator, Arrays.asList(narrowBroad));
        narrowWriter.close();
    }

    private static void expectActiveDestination(
            ProviderPathCoordinator coordinator,
            ProviderPathCoordinator.Claim destination
    ) throws Exception {
        try {
            coordinator.openLeased(destination, CloseProbeWriter::new);
            fail("expected active upload destination to be rejected");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_ALREADY_EXISTS, exception.code);
            assertEquals("upload destination is already active", exception.getMessage());
        }
    }

    private static void expectActiveOperation(
            ProviderPathCoordinator coordinator,
            java.util.List<ProviderPathCoordinator.Claim> claims
    ) throws Exception {
        try {
            coordinator.runLeased(claims, () -> {
            });
            fail("expected active provider path to be rejected");
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
