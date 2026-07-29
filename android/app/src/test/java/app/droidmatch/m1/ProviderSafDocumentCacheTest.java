package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.FileMutationResponse;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;

import java.util.Collections;

import org.junit.Test;

public final class ProviderSafDocumentCacheTest {
    private static final DmFileProvider.SafRoot DOCUMENTS =
            new DmFileProvider.SafRoot("documents", "primary:Documents", "Documents", true);

    @Test
    public void resolvesOpaqueIdentityAndEvictsLeastRecentlyUsedDocument() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(2);
        String first = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                "primary:Documents/one.txt"
        );
        String second = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                "primary:Documents/two.txt"
        );
        assertEquals("primary:Documents/one.txt", cache.documentId(DOCUMENTS, first));
        String third = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                "primary:Documents/three.txt"
        );
        assertEquals("primary:Documents/one.txt", cache.documentId(DOCUMENTS, first));
        assertNull(cache.documentId(DOCUMENTS, second));
        assertEquals("primary:Documents/three.txt", cache.documentId(DOCUMENTS, third));
    }

    @Test
    public void scopesSameDocumentIdentityToItsPersistedRoot() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(2);
        DmFileProvider.SafRoot pictures =
                new DmFileProvider.SafRoot("pictures", "primary:Pictures", "Pictures", true);
        String documentsToken = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                "shared-document-id"
        );
        String picturesToken = cache.remember(
                pictures,
                pictures.documentId,
                "shared-document-id"
        );

        assertNotEquals(documentsToken, picturesToken);
        assertEquals("shared-document-id", cache.documentId(DOCUMENTS, documentsToken));
        assertEquals("shared-document-id", cache.documentId(pictures, picturesToken));
        assertNull(cache.documentId(pictures, documentsToken));
        assertNull(cache.documentId(DOCUMENTS, picturesToken));
    }

    @Test
    public void bindsListedParentAndRebindsProviderChangedRenameIdentity() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(2);
        String firstParent = "primary:Documents/first";
        String secondParent = "primary:Documents/second";
        String firstToken = cache.remember(DOCUMENTS, firstParent, "shared-document-id");
        String secondToken = cache.remember(DOCUMENTS, secondParent, "shared-document-id");
        ProviderSafDocumentCache.DocumentTarget first = cache.target(DOCUMENTS, firstToken);
        ProviderSafDocumentCache.DocumentTarget second = cache.target(DOCUMENTS, secondToken);
        assertNotEquals(firstToken, secondToken);
        assertNotNull(first);
        assertNotNull(second);
        assertEquals("shared-document-id", first.documentId);
        assertEquals(firstParent, first.parentDocumentId);
        assertEquals("shared-document-id", second.documentId);
        assertEquals(secondParent, second.parentDocumentId);
        ProviderSafDocumentCache renameCache = new ProviderSafDocumentCache(4);
        String oldDocumentId = "primary:Documents/old.txt";
        String renamedDocumentId = "provider:renamed-id";
        String sourceToken = renameCache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                oldDocumentId,
                "old.txt"
        );
        FakeSafCatalog catalog = new FakeSafCatalog(DOCUMENTS);
        catalog.renameResultDocumentId = renamedDocumentId;
        ProviderMutations mutations = new ProviderMutations(
                catalog,
                ProviderAppSandboxCatalog.empty(),
                renameCache,
                new ProviderPathCoordinator()
        );

        FileMutationResponse response = mutations.renamePath(
                DOCUMENTS.path() + ProviderPathRouter.SAF_DOCUMENT_PREFIX + sourceToken,
                DOCUMENTS.path() + "renamed.txt"
        );

        assertTrue(response.getOk());
        assertNull(renameCache.target(DOCUMENTS, sourceToken));
        assertNull(renameCache.uniqueTargetForDocument(DOCUMENTS, oldDocumentId));
        ProviderSafDocumentCache.DocumentTarget renamed =
                renameCache.uniqueTargetForDocument(DOCUMENTS, renamedDocumentId);
        assertNotNull(renamed);
        assertEquals(renamedDocumentId, renamed.documentId);
        assertEquals(DOCUMENTS.documentId, renamed.parentDocumentId);
        assertEquals("renamed.txt", renamed.displayName);
    }

    @Test
    public void providerAutoRenameFailsClosedAndInvalidatesUnclaimedIdentity() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(4);
        String oldDocumentId = "primary:Documents/old.txt";
        String sourceToken = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                oldDocumentId,
                "old.txt"
        );
        FakeSafCatalog catalog = new FakeSafCatalog(DOCUMENTS);
        catalog.renameResultDocumentId = "provider:auto-renamed-id";
        catalog.renameResultDisplayName = "renamed (1).txt";
        ProviderMutations mutations = new ProviderMutations(
                catalog,
                ProviderAppSandboxCatalog.empty(),
                cache,
                new ProviderPathCoordinator()
        );

        FileMutationResponse response = mutations.renamePath(
                DOCUMENTS.path() + ProviderPathRouter.SAF_DOCUMENT_PREFIX + sourceToken,
                DOCUMENTS.path() + "renamed.txt"
        );

        assertFalse(response.getOk());
        assertEquals(ErrorCode.ERROR_CODE_INTERNAL, response.getError().getCode());
        assertNull(cache.target(DOCUMENTS, sourceToken));
        assertNull(cache.uniqueTargetForDocument(
                DOCUMENTS,
                "provider:auto-renamed-id"
        ));
    }

    @Test
    public void providerKindChangeFailsClosedAndInvalidatesUnclaimedIdentity() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(4);
        String sourceToken = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                "primary:Documents/old.txt",
                "old.txt"
        );
        FakeSafCatalog catalog = new FakeSafCatalog(DOCUMENTS);
        catalog.renameResultDocumentId = "provider:wrong-kind-id";
        catalog.renameResultKind = FileKind.FILE_KIND_DIRECTORY;
        ProviderMutations mutations = new ProviderMutations(
                catalog,
                ProviderAppSandboxCatalog.empty(),
                cache,
                new ProviderPathCoordinator()
        );

        FileMutationResponse response = mutations.renamePath(
                DOCUMENTS.path() + ProviderPathRouter.SAF_DOCUMENT_PREFIX + sourceToken,
                DOCUMENTS.path() + "renamed.txt"
        );

        assertFalse(response.getOk());
        assertEquals(ErrorCode.ERROR_CODE_INTERNAL, response.getError().getCode());
        assertNull(cache.target(DOCUMENTS, sourceToken));
        assertNull(cache.uniqueTargetForDocument(
                DOCUMENTS,
                "provider:wrong-kind-id"
        ));
    }

    @Test
    public void listedDirectoryRenamesWithoutAHiddenSourcePathSuffix() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(4);
        FakeSafCatalog catalog = new FakeSafCatalog(DOCUMENTS);
        catalog.page = new DmFileProvider.SafPage(
                Collections.singletonList(new DmFileProvider.SafItem(
                        "primary:Documents/folder",
                        "Folder",
                        FileKind.FILE_KIND_DIRECTORY,
                        0,
                        1,
                        "vnd.android.document/directory",
                        true
                )),
                false
        );
        DmFileProvider provider = provider(catalog, cache);
        ListDirResponse listing = provider.listDir(
                ListDirRequest.newBuilder().setPath(DOCUMENTS.path()).build()
        );
        String sourcePath = listing.getEntries(0).getPath();
        catalog.renameResultDocumentId = "provider:renamed-folder";
        catalog.renameResultKind = FileKind.FILE_KIND_DIRECTORY;

        FileMutationResponse response = provider.renamePath(
                sourcePath,
                DOCUMENTS.path() + "Renamed/"
        );

        assertFalse(sourcePath.endsWith("/"));
        assertTrue(response.getOk());
        ProviderSafDocumentCache.DocumentTarget renamed =
                cache.uniqueTargetForDocument(DOCUMENTS, "provider:renamed-folder");
        assertNotNull(renamed);
        assertEquals(FileKind.FILE_KIND_DIRECTORY, renamed.kind);
    }

    @Test
    public void uncertainRenameInvalidatesProviderTokensAndOldListings() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(4);
        String oldDocumentId = "primary:Documents/old.txt";
        String sourceToken = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                oldDocumentId,
                "old.txt"
        );
        ProviderSafDocumentCache.ListingResolution oldListing =
                cache.resolveForListing(DOCUMENTS, null);
        assertNotNull(oldListing);
        FakeSafCatalog catalog = new FakeSafCatalog(DOCUMENTS);
        catalog.mutationException = new DmFileProvider.ProviderCatalogException(
                ErrorCode.ERROR_CODE_INTERNAL,
                "provider result is uncertain"
        );
        ProviderMutations mutations = new ProviderMutations(
                catalog,
                ProviderAppSandboxCatalog.empty(),
                cache,
                new ProviderPathCoordinator()
        );

        FileMutationResponse response = mutations.renamePath(
                DOCUMENTS.path() + ProviderPathRouter.SAF_DOCUMENT_PREFIX + sourceToken,
                DOCUMENTS.path() + "renamed.txt"
        );

        assertFalse(response.getOk());
        assertNull(cache.target(DOCUMENTS, sourceToken));
        assertNull(cache.rememberListingIfCurrent(
                DOCUMENTS,
                DOCUMENTS.documentId,
                Collections.emptyList(),
                oldListing.epoch
        ));
    }

    @Test
    public void exactDirectoryCreateAdvancesTheListingEpoch() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(4);
        String staleToken = cache.remember(
                DOCUMENTS, DOCUMENTS.documentId, "provider:stale", "Exact",
                FileKind.FILE_KIND_DIRECTORY
        );
        ProviderSafDocumentCache.ListingResolution oldListing =
                cache.resolveForListing(DOCUMENTS, null);
        assertNotNull(oldListing);
        FakeSafCatalog catalog = new FakeSafCatalog(DOCUMENTS);
        catalog.createSupported = true;
        ProviderMutations mutations = new ProviderMutations(
                catalog,
                ProviderAppSandboxCatalog.empty(),
                cache,
                new ProviderPathCoordinator()
        );

        FileMutationResponse response =
                mutations.createDirectory(DOCUMENTS.path() + "Exact/");

        assertTrue(response.getOk());
        assertNull(cache.target(DOCUMENTS, staleToken));
        assertNull(cache.rememberListingIfCurrent(
                DOCUMENTS,
                DOCUMENTS.documentId,
                Collections.emptyList(),
                oldListing.epoch
        ));
    }

    @Test
    public void autoRenamedDirectoryCreateFailsClosedAndInvalidatesTokens() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(4);
        String existingToken = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                "primary:Documents/existing.txt",
                "existing.txt"
        );
        FakeSafCatalog catalog = new FakeSafCatalog(DOCUMENTS);
        catalog.createSupported = true;
        catalog.createResultDisplayName = "Exact (1)";
        ProviderMutations mutations = new ProviderMutations(
                catalog,
                ProviderAppSandboxCatalog.empty(),
                cache,
                new ProviderPathCoordinator()
        );

        FileMutationResponse response =
                mutations.createDirectory(DOCUMENTS.path() + "Exact/");

        assertFalse(response.getOk());
        assertEquals(ErrorCode.ERROR_CODE_INTERNAL, response.getError().getCode());
        assertNull(cache.target(DOCUMENTS, existingToken));
    }

    @Test
    public void finalSafUploadAttemptInvalidatesAnOlderDirectoryPage() throws Exception {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(4);
        String parentToken = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                "primary:Documents/nested",
                "nested",
                FileKind.FILE_KIND_DIRECTORY
        );
        FakeSafCatalog catalog = new FakeSafCatalog(DOCUMENTS);
        DmFileProvider provider = provider(catalog, cache);
        DmFileProvider.UploadWriter writer = provider.openUpload(
                DOCUMENTS.path() + ProviderPathRouter.SAF_DOCUMENT_PREFIX
                        + parentToken + "/payload.bin",
                0,
                1
        );
        ProviderSafDocumentCache.ListingResolution oldListing =
                cache.resolveForListing(DOCUMENTS, null);
        assertNotNull(oldListing);
        writer.writeChunk(0, new byte[] {1}, true);

        assertNull(cache.rememberListingIfCurrent(
                DOCUMENTS,
                DOCUMENTS.documentId,
                Collections.emptyList(),
                oldListing.epoch
        ));
        assertNotNull(cache.target(DOCUMENTS, parentToken));
    }

    @Test
    public void safUploadOpenAndAbortEachInvalidateOlderDirectoryPages()
            throws Exception {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(4);
        String parentToken = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                "primary:Documents/nested",
                "nested",
                FileKind.FILE_KIND_DIRECTORY
        );
        String staleChildToken = cache.remember(
                DOCUMENTS,
                "primary:Documents/nested",
                "primary:Documents/stale-payload",
                "payload.bin",
                FileKind.FILE_KIND_FILE
        );
        ProviderSafDocumentCache.ListingResolution beforeOpen =
                cache.resolveForListing(DOCUMENTS, null);
        FakeSafCatalog catalog = new FakeSafCatalog(DOCUMENTS);
        DmFileProvider.UploadWriter writer = provider(catalog, cache).openUpload(
                DOCUMENTS.path() + ProviderPathRouter.SAF_DOCUMENT_PREFIX
                        + parentToken + "/payload.bin",
                0,
                1
        );
        assertNotNull(cache.target(DOCUMENTS, parentToken));
        assertNull(cache.target(DOCUMENTS, staleChildToken));
        assertNull(cache.rememberListingIfCurrent(
                DOCUMENTS,
                DOCUMENTS.documentId,
                Collections.emptyList(),
                beforeOpen.epoch
        ));
        ProviderSafDocumentCache.ListingResolution beforeAbort =
                cache.resolveForListing(DOCUMENTS, null);

        writer.close();

        assertNotNull(cache.target(DOCUMENTS, parentToken));
        assertNull(cache.rememberListingIfCurrent(
                DOCUMENTS,
                DOCUMENTS.documentId,
                Collections.emptyList(),
                beforeAbort.epoch
        ));
    }

    @Test
    public void renameInvalidatesOldIdentityAcrossRootsFromSameAuthority() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(8);
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
        DmFileProvider.SafRoot otherProvider = new DmFileProvider.SafRoot(
                "other",
                "other.provider",
                "other-root",
                "Other",
                true
        );
        String oldDocumentId = "provider:old-id";
        String broadToken = cache.remember(
                broad,
                "broad-parent",
                oldDocumentId,
                "old.txt"
        );
        String nestedToken = cache.remember(
                nested,
                nested.documentId,
                oldDocumentId,
                "old.txt"
        );
        String otherToken = cache.remember(
                otherProvider,
                otherProvider.documentId,
                oldDocumentId,
                "old.txt"
        );

        String renamedToken = cache.rebindAfterRename(
                nested,
                oldDocumentId,
                nested.documentId,
                "provider:new-id",
                "renamed.txt",
                FileKind.FILE_KIND_FILE
        );

        assertNull(cache.target(broad, broadToken));
        assertNull(cache.target(nested, nestedToken));
        assertNull(cache.uniqueTargetForDocument(broad, oldDocumentId));
        assertNull(cache.uniqueTargetForDocument(nested, oldDocumentId));
        assertEquals(
                oldDocumentId,
                cache.target(otherProvider, otherToken).documentId
        );
        ProviderSafDocumentCache.DocumentTarget renamed =
                cache.target(nested, renamedToken);
        assertNotNull(renamed);
        assertEquals("provider:new-id", renamed.documentId);
        assertEquals("renamed.txt", renamed.displayName);

        ProviderSafDocumentCache collisionCache = new ProviderSafDocumentCache(4);
        collisionCache.remember(
                nested, nested.documentId, oldDocumentId, "old.txt"
        );
        collisionCache.remember(
                broad, broad.documentId, "provider:new-id", "existing.txt"
        );
        assertNull(collisionCache.rebindAfterRename(
                nested,
                oldDocumentId,
                nested.documentId,
                "provider:new-id",
                "renamed.txt",
                FileKind.FILE_KIND_FILE
        ));
        assertNull(collisionCache.uniqueTargetForDocument(nested, oldDocumentId));
        assertNull(collisionCache.uniqueTargetForDocument(broad, "provider:new-id"));
    }

    @Test
    public void staleListingCannotRestoreOldIdentityAfterRename() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(8);
        DmFileProvider.SafRoot root = new DmFileProvider.SafRoot(
                "documents",
                "documents.provider",
                "root",
                "Documents",
                true
        );
        String oldDocumentId = "provider:old-id";
        String renamedDocumentId = "provider:new-id";
        FakeSafCatalog catalog = new FakeSafCatalog(root);
        catalog.page = new DmFileProvider.SafPage(
                Collections.singletonList(new DmFileProvider.SafItem(
                        oldDocumentId,
                        "old.txt",
                        FileKind.FILE_KIND_FILE,
                        1,
                        1,
                        "application/octet-stream",
                        true
                )),
                false
        );
        catalog.listCallback = () -> cache.rebindAfterRename(
                root,
                oldDocumentId,
                root.documentId,
                renamedDocumentId,
                "renamed.txt",
                FileKind.FILE_KIND_FILE
        );

        ListDirResponse response = ProviderDirectoryListings.list(
                ListDirRequest.newBuilder().setPath(root.path()).build(),
                new FakeMediaCatalog(),
                catalog,
                ProviderAppSandboxCatalog.empty(),
                cache
        );

        assertTrue(response.hasError());
        assertEquals(
                ErrorCode.ERROR_CODE_ALREADY_EXISTS,
                response.getError().getCode()
        );
        assertNull(cache.uniqueTargetForDocument(root, oldDocumentId));
        assertNotNull(cache.uniqueTargetForDocument(root, renamedDocumentId));
    }

    @Test
    public void staleListingCannotRestoreIdentityAfterCrossRootDelete() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(8);
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
        String deletedDocumentId = "provider:deleted-id";
        cache.remember(
                nested,
                nested.documentId,
                deletedDocumentId,
                "deleted.txt"
        );
        FakeSafCatalog catalog = new FakeSafCatalog(broad, nested);
        catalog.page = new DmFileProvider.SafPage(
                Collections.singletonList(new DmFileProvider.SafItem(
                        deletedDocumentId,
                        "deleted.txt",
                        FileKind.FILE_KIND_FILE,
                        1,
                        1,
                        "application/octet-stream",
                        true
                )),
                false
        );
        catalog.listCallback = () ->
                cache.invalidateAfterDelete(nested, deletedDocumentId);

        ListDirResponse response = ProviderDirectoryListings.list(
                ListDirRequest.newBuilder().setPath(broad.path()).build(),
                new FakeMediaCatalog(),
                catalog,
                ProviderAppSandboxCatalog.empty(),
                cache
        );

        assertTrue(response.hasError());
        assertEquals(
                ErrorCode.ERROR_CODE_ALREADY_EXISTS,
                response.getError().getCode()
        );
        assertNull(cache.uniqueTargetForDocument(broad, deletedDocumentId));
        assertNull(cache.uniqueTargetForDocument(nested, deletedDocumentId));
    }

    @Test
    public void mutationBeforeListingResolutionRejectsOldDirectoryToken() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(8);
        String documentId = "primary:Documents/old-directory";
        String token = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                documentId,
                "Old"
        );

        cache.invalidateAfterDelete(DOCUMENTS, documentId);

        assertNull(cache.resolveForListing(DOCUMENTS, token));
    }

    @Test
    public void mutationAfterListingResolutionRejectsOldDirectoryPage() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(8);
        String documentId = "primary:Documents/old-directory";
        String token = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                documentId,
                "Old"
        );
        ProviderSafDocumentCache.ListingResolution resolution =
                cache.resolveForListing(DOCUMENTS, token);
        assertNotNull(resolution);

        cache.invalidateAfterDelete(DOCUMENTS, documentId);

        assertNull(cache.rememberListingIfCurrent(
                DOCUMENTS,
                resolution.target.documentId,
                Collections.singletonList(new DmFileProvider.SafItem(
                        "primary:Documents/old-directory/child.txt",
                        "child.txt",
                        FileKind.FILE_KIND_FILE,
                        1,
                        1,
                        "application/octet-stream",
                        true
                )),
                resolution.epoch
        ));
        assertNull(cache.resolveForListing(DOCUMENTS, token));
    }

    @Test
    public void replacementFacadeRenameInvalidatesOldFacadeListingAndToken() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(8);
        DmFileProvider.SafRoot root = new DmFileProvider.SafRoot(
                "documents",
                "documents.provider",
                "root",
                "Documents",
                true
        );
        String oldDocumentId = "provider:old-id";
        String renamedDocumentId = "provider:new-id";
        String oldToken = cache.remember(
                root,
                root.documentId,
                oldDocumentId,
                "old.txt"
        );
        String oldPath = root.path() + ProviderPathRouter.SAF_DOCUMENT_PREFIX + oldToken;
        FakeSafCatalog catalog = new FakeSafCatalog(root);
        catalog.renameResultDocumentId = renamedDocumentId;
        catalog.page = pageWithFile(oldDocumentId, "old.txt");
        DmFileProvider oldFacade = provider(catalog, cache);
        DmFileProvider replacementFacade = provider(catalog, cache);
        catalog.listCallback = () -> {
            catalog.listCallback = null;
            assertTrue(replacementFacade.renamePath(
                    oldPath,
                    root.path() + "renamed.txt"
            ).getOk());
        };

        ListDirResponse listing = oldFacade.listDir(
                ListDirRequest.newBuilder().setPath(root.path()).build()
        );

        assertTrue(listing.hasError());
        assertEquals(ErrorCode.ERROR_CODE_ALREADY_EXISTS, listing.getError().getCode());
        assertNull(cache.target(root, oldToken));
        assertNotNull(cache.uniqueTargetForDocument(root, renamedDocumentId));
        FileMutationResponse staleDelete = oldFacade.deletePath(oldPath, false);
        assertFalse(staleDelete.getOk());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, staleDelete.getError().getCode());
        assertEquals(0, catalog.deleteCount);
    }

    @Test
    public void replacementFacadeDeleteInvalidatesOldFacadeListingAndToken() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(8);
        DmFileProvider.SafRoot root = new DmFileProvider.SafRoot(
                "documents",
                "documents.provider",
                "root",
                "Documents",
                true
        );
        String deletedDocumentId = "provider:deleted-id";
        String oldToken = cache.remember(
                root,
                root.documentId,
                deletedDocumentId,
                "deleted.txt"
        );
        String oldPath = root.path() + ProviderPathRouter.SAF_DOCUMENT_PREFIX + oldToken;
        FakeSafCatalog catalog = new FakeSafCatalog(root);
        catalog.deleteSupported = true;
        catalog.page = pageWithFile(deletedDocumentId, "deleted.txt");
        DmFileProvider oldFacade = provider(catalog, cache);
        DmFileProvider replacementFacade = provider(catalog, cache);
        catalog.listCallback = () -> {
            catalog.listCallback = null;
            assertTrue(replacementFacade.deletePath(oldPath, false).getOk());
        };

        ListDirResponse listing = oldFacade.listDir(
                ListDirRequest.newBuilder().setPath(root.path()).build()
        );

        assertTrue(listing.hasError());
        assertEquals(ErrorCode.ERROR_CODE_ALREADY_EXISTS, listing.getError().getCode());
        assertNull(cache.target(root, oldToken));
        FileMutationResponse staleDelete = oldFacade.deletePath(oldPath, false);
        assertFalse(staleDelete.getOk());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, staleDelete.getError().getCode());
        assertEquals(1, catalog.deleteCount);
    }

    @Test
    public void parentAndDocumentTupleBoundariesCannotAlias() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(3);

        String first = cache.remember(DOCUMENTS, "parent\nchild", "leaf");
        String second = cache.remember(DOCUMENTS, "parent", "child\nleaf");
        String missingParent = cache.remember(DOCUMENTS, null, "leaf");

        assertNotEquals(first, second);
        assertNotEquals(first, missingParent);
        assertEquals("parent\nchild", cache.target(DOCUMENTS, first).parentDocumentId);
        assertEquals("parent", cache.target(DOCUMENTS, second).parentDocumentId);
        assertNull(cache.target(DOCUMENTS, missingParent).parentDocumentId);
    }

    private static DmFileProvider provider(
            FakeSafCatalog catalog,
            ProviderSafDocumentCache cache
    ) {
        return new DmFileProvider(
                new FakeMediaCatalog(),
                catalog,
                ProviderAppSandboxCatalog.empty(),
                cache
        );
    }

    private static DmFileProvider.SafPage pageWithFile(
            String documentId,
            String displayName
    ) {
        return new DmFileProvider.SafPage(
                Collections.singletonList(new DmFileProvider.SafItem(
                        documentId,
                        displayName,
                        FileKind.FILE_KIND_FILE,
                        1,
                        1,
                        "application/octet-stream",
                        true
                )),
                false
        );
    }
}
