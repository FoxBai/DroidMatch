package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.FileMutationResponse;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import org.junit.Test;

public final class ProviderMutationCoordinationTest {
    @Test
    public void ancestorDeleteFailsClosedWhileUploadOpenIsAtBarrier() throws Exception {
        ProviderPathCoordinator coordinator = new ProviderPathCoordinator();
        BlockingAppSandboxCatalog catalog = new BlockingAppSandboxCatalog();
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(4);
        ProviderMutations mutations = new ProviderMutations(
                ProviderSafCatalog.empty(),
                catalog,
                cache,
                coordinator
        );
        ExecutorService executor = Executors.newSingleThreadExecutor();
        try {
            Future<DmFileProvider.UploadWriter> opening = executor.submit(
                    () -> ProviderTransfers.openUpload(
                            "dm://app-sandbox/folder/result.bin",
                            "transfer-one",
                            0,
                            4,
                            ProviderMediaCatalog.empty(),
                            ProviderSafCatalog.empty(),
                            catalog,
                            cache,
                            coordinator
                    )
            );
            assertTrue(catalog.openEntered.await(2, TimeUnit.SECONDS));

            FileMutationResponse conflicted = mutations.deletePath(
                    "dm://app-sandbox/folder/",
                    true
            );

            assertFalse(conflicted.getOk());
            assertEquals(
                    ErrorCode.ERROR_CODE_ALREADY_EXISTS,
                    conflicted.getError().getCode()
            );
            assertEquals(0, catalog.deleteCount);

            catalog.allowOpen.countDown();
            DmFileProvider.UploadWriter writer = opening.get(2, TimeUnit.SECONDS);
            writer.close();

            FileMutationResponse afterRelease = mutations.deletePath(
                    "dm://app-sandbox/folder/",
                    true
            );
            assertTrue(afterRelease.getOk());
            assertEquals(1, catalog.deleteCount);
        } finally {
            catalog.allowOpen.countDown();
            executor.shutdownNow();
            assertTrue(executor.awaitTermination(2, TimeUnit.SECONDS));
        }
    }

    @Test
    public void overlappingSafRootClaimsAndMutationInvalidationShareAuthority()
            throws Exception {
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
        BlockingSafCatalog catalog = new BlockingSafCatalog(broad, nested);
        catalog.replaceRootsAfterFirst(broad);
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(8);
        String ancestorToken = cache.remember(
                broad,
                broad.documentId,
                "broad-ancestor",
                "ancestor"
        );
        ProviderMutations mutations = new ProviderMutations(
                catalog,
                ProviderAppSandboxCatalog.empty(),
                cache,
                coordinator
        );
        ExecutorService executor = Executors.newSingleThreadExecutor();
        try {
            Future<DmFileProvider.UploadWriter> opening = executor.submit(
                    () -> ProviderTransfers.openUpload(
                            nested.path() + "result.bin",
                            "transfer-one",
                            0,
                            4,
                            ProviderMediaCatalog.empty(),
                            catalog,
                            ProviderAppSandboxCatalog.empty(),
                            cache,
                            coordinator
                    )
            );
            assertTrue(catalog.openEntered.await(2, TimeUnit.SECONDS));
            assertEquals(1, catalog.rootsCallCount);

            String ancestorPath = broad.path()
                    + ProviderPathRouter.SAF_DOCUMENT_PREFIX
                    + ancestorToken
                    + "/";
            FileMutationResponse conflicted = mutations.deletePath(ancestorPath, true);

            assertFalse(conflicted.getOk());
            assertEquals(
                    ErrorCode.ERROR_CODE_ALREADY_EXISTS,
                    conflicted.getError().getCode()
            );
            assertEquals(0, catalog.deleteCount);
            assertEquals(2, catalog.rootsCallCount);

            catalog.allowOpen.countDown();
            DmFileProvider.UploadWriter writer = opening.get(2, TimeUnit.SECONDS);
            writer.close();

            FileMutationResponse afterRelease = mutations.deletePath(ancestorPath, true);
            assertTrue(afterRelease.getOk());
            assertEquals(1, catalog.deleteCount);
            assertNull(cache.uniqueTargetForDocument(broad, "broad-ancestor"));

            String parentToken = cache.remember(
                    nested, nested.documentId, "shared-parent", "parent"
            );
            String broadChild = cache.remember(
                    broad, "shared-parent", "broad-child", "result.bin"
            );
            String nestedChild = cache.remember(
                    nested, "shared-parent", "nested-child", "result.bin"
            );
            cache.invalidateChildAfterMutation(nested, "shared-parent", "result.bin");
            assertNull(cache.target(broad, broadChild));
            assertNull(cache.target(nested, nestedChild));
            assertNotNull(cache.target(nested, parentToken));

            String staleDestination = cache.remember(
                    broad, "shared-parent", "broad-stale", "renamed.bin"
            );
            String renameSource = cache.remember(
                    nested, "shared-parent", "nested-source", "source.bin"
            );
            String unrelatedName = cache.remember(
                    broad, "shared-parent", "broad-unrelated", "other.bin"
            );
            String unrelatedParent = cache.remember(
                    broad, "other-parent", "broad-other-parent", "renamed.bin"
            );
            String renamed = cache.rebindAfterRename(
                    nested, "nested-source", "shared-parent",
                    "provider:renamed", "renamed.bin", FileKind.FILE_KIND_FILE
            );
            assertNull(cache.target(broad, staleDestination));
            assertNull(cache.target(nested, renameSource));
            assertNotNull(cache.target(nested, renamed));
            assertNotNull(cache.target(nested, parentToken));
            assertNotNull(cache.target(broad, unrelatedName));
            assertNotNull(cache.target(broad, unrelatedParent));
        } finally {
            catalog.allowOpen.countDown();
            executor.shutdownNow();
            assertTrue(executor.awaitTermination(2, TimeUnit.SECONDS));
        }
    }

    private static final class BlockingAppSandboxCatalog
            implements ProviderAppSandboxCatalog {
        private final CountDownLatch openEntered = new CountDownLatch(1);
        private final CountDownLatch allowOpen = new CountDownLatch(1);
        private int deleteCount;

        @Override
        public DmFileProvider.AppSandboxPage listDirectory(
                String relativePath,
                DmFileProvider.ProviderQuery query
        ) {
            return new DmFileProvider.AppSandboxPage(new ArrayList<>(), false);
        }

        @Override
        public DmFileProvider.DownloadReader openFile(
                String relativePath,
                long offsetBytes,
                int chunkSizeBytes
        ) throws DmFileProvider.ProviderCatalogException {
            throw unavailable();
        }

        @Override
        public DmFileProvider.UploadWriter openUploadFile(
                String relativePath,
                String transferId,
                long offsetBytes,
                long expectedSizeBytes
        ) throws DmFileProvider.ProviderCatalogException {
            openEntered.countDown();
            try {
                if (!allowOpen.await(2, TimeUnit.SECONDS)) {
                    throw new DmFileProvider.ProviderCatalogException(
                            ErrorCode.ERROR_CODE_INTERNAL,
                            "injected upload-open barrier timed out"
                    );
                }
            } catch (InterruptedException exception) {
                Thread.currentThread().interrupt();
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "injected upload-open barrier interrupted"
                );
            }
            return new NoOpWriter();
        }

        @Override
        public void discardUploadPartial(
                String relativePath,
                String transferId,
                long expectedSizeBytes
        ) {
        }

        @Override
        public void createDirectory(String relativePath) {
        }

        @Override
        public void renamePath(
                String sourceRelativePath,
                String destinationRelativePath,
                boolean directory
        ) {
        }

        @Override
        public void deletePath(String relativePath, boolean directory, boolean recursive) {
            deleteCount += 1;
        }

        private static DmFileProvider.ProviderCatalogException unavailable() {
            return new DmFileProvider.ProviderCatalogException(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "test catalog entry is not available"
            );
        }
    }

    private static final class BlockingSafCatalog implements ProviderSafCatalog {
        private final List<DmFileProvider.SafRoot> roots;
        private List<DmFileProvider.SafRoot> rootsAfterFirst;
        private final CountDownLatch openEntered = new CountDownLatch(1);
        private final CountDownLatch allowOpen = new CountDownLatch(1);
        private int deleteCount;
        private int rootsCallCount;

        private BlockingSafCatalog(DmFileProvider.SafRoot... roots) {
            this.roots = Arrays.asList(roots);
        }

        private void replaceRootsAfterFirst(DmFileProvider.SafRoot... roots) {
            rootsAfterFirst = Arrays.asList(roots);
        }

        @Override
        public List<DmFileProvider.SafRoot> roots() {
            rootsCallCount += 1;
            return new ArrayList<>(
                    rootsCallCount == 1 || rootsAfterFirst == null
                            ? roots
                            : rootsAfterFirst
            );
        }

        @Override
        public DmFileProvider.SafPage listChildren(
                DmFileProvider.SafRoot root,
                String documentId,
                DmFileProvider.ProviderQuery query
        ) {
            return new DmFileProvider.SafPage(new ArrayList<>(), false);
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
                    "test SAF document is not available"
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
        ) throws DmFileProvider.ProviderCatalogException {
            openEntered.countDown();
            try {
                if (!allowOpen.await(2, TimeUnit.SECONDS)) {
                    throw new DmFileProvider.ProviderCatalogException(
                            ErrorCode.ERROR_CODE_INTERNAL,
                            "injected SAF upload-open barrier timed out"
                    );
                }
            } catch (InterruptedException exception) {
                Thread.currentThread().interrupt();
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "injected SAF upload-open barrier interrupted"
                );
            }
            return new NoOpWriter();
        }

        @Override
        public void deleteDocument(
                DmFileProvider.SafRoot root,
                String documentId,
                boolean recursive
        ) {
            deleteCount += 1;
        }
    }

    private static final class NoOpWriter implements DmFileProvider.UploadWriter {
        @Override
        public long nextOffsetBytes() {
            return 0;
        }

        @Override
        public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk) {
        }

        @Override
        public void close() {
        }
    }
}
