package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import app.droidmatch.m1.SafUploadDocumentStore.Document;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;

import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;

import org.junit.Test;

public final class AndroidSafUploadOpenerTest {
    private static final DmFileProvider.SafRoot ROOT =
            new DmFileProvider.SafRoot("documents", "root", "Documents", true);
    private static final String FINAL_NAME = "result.bin";
    private static final String TRANSFER_ID = "transfer-one";
    private static final long EXPECTED_SIZE = 4;

    @Test
    public void restartDeletesThenVerifiesUniqueExactCreatedDocument() throws Exception {
        FakeStore store = storeWithOldPartial();
        AndroidSafUploadOpener opener = new AndroidSafUploadOpener(store);

        DmFileProvider.UploadWriter writer = opener.open(
                ROOT,
                ROOT.documentId,
                FINAL_NAME,
                TRANSFER_ID,
                0,
                EXPECTED_SIZE,
                () -> {
                }
        );

        assertNotNull(writer);
        assertEquals(1, store.openCount);
        assertTrue(store.deletedIds.contains("old-partial"));
        assertEquals(1, store.exactNameCount(partialName()));
        writer.close();
        assertEquals(1, store.exactNameCount(partialName()));
    }

    @Test
    public void restartRejectsFalseDeleteEvenWhenNameDisappears() throws Exception {
        FakeStore store = storeWithOldPartial();
        store.deleteResult = false;
        store.removeOnDelete = true;

        expectOpenFailure(store, ErrorCode.ERROR_CODE_INTERNAL);

        assertEquals(0, store.createCount);
        assertEquals(0, store.openCount);
    }

    @Test
    public void restartRejectsDeleteExceptionAndResidualExactName() throws Exception {
        FakeStore denied = storeWithOldPartial();
        denied.deleteFailure = new DmFileProvider.ProviderCatalogException(
                ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                "injected permission failure"
        );
        expectOpenFailure(denied, ErrorCode.ERROR_CODE_PERMISSION_REQUIRED);
        assertEquals(0, denied.createCount);
        assertEquals(0, denied.openCount);

        FakeStore residual = storeWithOldPartial();
        residual.removeOnDelete = false;
        expectOpenFailure(residual, ErrorCode.ERROR_CODE_INTERNAL);
        assertEquals(0, residual.createCount);
        assertEquals(0, residual.openCount);
    }

    @Test
    public void restartRejectsAutoRenameWithoutDeletingUnverifiedIdentity() throws Exception {
        FakeStore store = storeWithOldPartial();
        store.createdNameOverride = partialName() + " (1)";

        expectOpenFailure(store, ErrorCode.ERROR_CODE_INTERNAL);

        assertEquals(1, store.createCount);
        assertEquals(0, store.openCount);
        assertFalse(store.deletedIds.contains("created-1"));
        assertFalse(store.deletedIds.contains("unrelated"));
    }

    @Test
    public void restartRejectsDuplicateExactNameWithoutDeletingEitherIdentity()
            throws Exception {
        FakeStore store = storeWithOldPartial();
        store.addDuplicateOnCreate = true;

        expectOpenFailure(store, ErrorCode.ERROR_CODE_INTERNAL);

        assertEquals(0, store.openCount);
        assertFalse(store.deletedIds.contains("created-1"));
        assertFalse(store.deletedIds.contains("duplicate-created"));
        assertEquals(2, store.exactNameCount(partialName()));
    }

    @Test
    public void discardRequiresTrueDeleteAndVerifiedAbsence() throws Exception {
        FakeStore falseDelete = storeWithOldPartial();
        falseDelete.deleteResult = false;
        falseDelete.removeOnDelete = true;
        expectDiscardFailure(falseDelete, ErrorCode.ERROR_CODE_INTERNAL);

        FakeStore residual = storeWithOldPartial();
        residual.removeOnDelete = false;
        expectDiscardFailure(residual, ErrorCode.ERROR_CODE_INTERNAL);

        FakeStore removed = storeWithOldPartial();
        new AndroidSafUploadOpener(removed).discardPartial(
                ROOT,
                ROOT.documentId,
                FINAL_NAME,
                TRANSFER_ID,
                EXPECTED_SIZE
        );
        assertEquals(0, removed.exactNameCount(partialName()));
    }

    @Test
    public void discardTreatsDeleteNotFoundAsSuccessOnlyAfterVerifiedAbsence()
            throws Exception {
        FakeStore missing = storeWithOldPartial();
        missing.removeBeforeDeleteFailure = true;
        missing.deleteFailure = new DmFileProvider.ProviderCatalogException(
                ErrorCode.ERROR_CODE_NOT_FOUND,
                "injected delete race"
        );

        new AndroidSafUploadOpener(missing).discardPartial(
                ROOT,
                ROOT.documentId,
                FINAL_NAME,
                TRANSFER_ID,
                EXPECTED_SIZE
        );
        assertEquals(0, missing.exactNameCount(partialName()));

        FakeStore residual = storeWithOldPartial();
        residual.deleteFailure = new DmFileProvider.ProviderCatalogException(
                ErrorCode.ERROR_CODE_NOT_FOUND,
                "injected false not-found"
        );
        expectDiscardFailure(residual, ErrorCode.ERROR_CODE_NOT_FOUND);
        assertEquals(1, residual.exactNameCount(partialName()));
    }

    @Test
    public void restartRejectsInvalidOldPartialAndCreatedDirectory() throws Exception {
        FakeStore directoryPartial = storeWithOldPartial(
                FileKind.FILE_KIND_DIRECTORY,
                0
        );
        expectOpenFailure(directoryPartial, ErrorCode.ERROR_CODE_INTERNAL);
        assertTrue(directoryPartial.deletedIds.isEmpty());
        assertEquals(0, directoryPartial.createCount);
        assertEquals(0, directoryPartial.openCount);

        FakeStore oversizedPartial = storeWithOldPartial(
                FileKind.FILE_KIND_FILE,
                EXPECTED_SIZE + 1
        );
        expectOpenFailure(oversizedPartial, ErrorCode.ERROR_CODE_INTERNAL);
        assertTrue(oversizedPartial.deletedIds.isEmpty());
        assertEquals(0, oversizedPartial.createCount);
        assertEquals(0, oversizedPartial.openCount);

        FakeStore createdDirectory = storeWithOldPartial();
        createdDirectory.createdKind = FileKind.FILE_KIND_DIRECTORY;
        expectOpenFailure(createdDirectory, ErrorCode.ERROR_CODE_INTERNAL);

        assertEquals(0, createdDirectory.openCount);
        assertFalse(createdDirectory.deletedIds.contains("created-1"));
    }

    @Test
    public void freshUploadRejectsExistingAndUsesHiddenProvisionalName()
            throws Exception {
        FakeStore store = new FakeStore();
        store.entries.add(new FakeEntry(
                "existing",
                FINAL_NAME,
                FileKind.FILE_KIND_FILE,
                EXPECTED_SIZE
        ));
        AndroidSafUploadOpener opener = new AndroidSafUploadOpener(store);

        try {
            opener.open(
                    ROOT,
                    ROOT.documentId,
                    FINAL_NAME,
                    "",
                    0,
                    EXPECTED_SIZE,
                    () -> {}
            );
            fail("expected existing SAF upload destination to be rejected");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_ALREADY_EXISTS, exception.code);
        }

        assertEquals(0, store.createCount);
        assertEquals(0, store.openCount);
        assertTrue(store.deletedIds.isEmpty());

        FakeStore hidden = new FakeStore();
        DmFileProvider.UploadWriter writer = new AndroidSafUploadOpener(hidden).open(
                ROOT,
                ROOT.documentId,
                FINAL_NAME,
                "",
                0,
                EXPECTED_SIZE,
                () -> {}
        );
        String hiddenName = SafDocumentPolicy.uploadPartialDisplayName(
                ROOT.stableId,
                ROOT.documentId,
                FINAL_NAME,
                "",
                EXPECTED_SIZE
        );
        assertEquals(0, hidden.exactNameCount(FINAL_NAME));
        assertEquals(1, hidden.exactNameCount(hiddenName));
        writer.close();
        assertEquals(0, hidden.exactNameCount(hiddenName));
    }

    @Test
    public void restartAndDiscardRejectUnknownPartialSizeWithoutStorageMutation()
            throws Exception {
        FakeStore restart = storeWithOldPartial(FileKind.FILE_KIND_FILE, -1);

        expectOpenFailure(restart, ErrorCode.ERROR_CODE_INTERNAL);

        assertTrue(restart.deletedIds.isEmpty());
        assertEquals(0, restart.createCount);
        assertEquals(0, restart.openCount);

        FakeStore discard = storeWithOldPartial(FileKind.FILE_KIND_FILE, -1);
        expectDiscardFailure(discard, ErrorCode.ERROR_CODE_INTERNAL);

        assertTrue(discard.deletedIds.isEmpty());
        assertEquals(0, discard.createCount);
        assertEquals(0, discard.openCount);
    }

    private static FakeStore storeWithOldPartial() {
        return storeWithOldPartial(FileKind.FILE_KIND_FILE, 2);
    }

    private static FakeStore storeWithOldPartial(FileKind kind, long sizeBytes) {
        FakeStore store = new FakeStore();
        store.entries.add(new FakeEntry(
                "old-partial",
                partialName(),
                kind,
                sizeBytes
        ));
        store.entries.add(new FakeEntry(
                "unrelated",
                "unrelated.bin",
                FileKind.FILE_KIND_FILE,
                1
        ));
        return store;
    }

    private static void expectOpenFailure(FakeStore store, ErrorCode expectedCode)
            throws Exception {
        AndroidSafUploadOpener opener = new AndroidSafUploadOpener(store);
        try {
            opener.open(
                    ROOT,
                    ROOT.documentId,
                    FINAL_NAME,
                    TRANSFER_ID,
                    0,
                    EXPECTED_SIZE,
                    () -> {
                    }
            );
            fail("expected SAF upload open to fail");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(expectedCode, exception.code);
        }
    }

    private static void expectDiscardFailure(FakeStore store, ErrorCode expectedCode)
            throws Exception {
        try {
            new AndroidSafUploadOpener(store).discardPartial(
                    ROOT,
                    ROOT.documentId,
                    FINAL_NAME,
                    TRANSFER_ID,
                    EXPECTED_SIZE
            );
            fail("expected SAF upload partial discard to fail");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(expectedCode, exception.code);
        }
    }

    private static String partialName() {
        return SafDocumentPolicy.uploadPartialDisplayName(
                ROOT.stableId,
                ROOT.documentId,
                FINAL_NAME,
                TRANSFER_ID,
                EXPECTED_SIZE
        );
    }

    private static final class FakeStore implements SafUploadDocumentStore {
        private final List<FakeEntry> entries = new ArrayList<>();
        private final List<String> deletedIds = new ArrayList<>();
        private boolean deleteResult = true;
        private boolean removeOnDelete = true;
        private boolean removeBeforeDeleteFailure;
        private boolean addDuplicateOnCreate;
        private String createdNameOverride;
        private FileKind createdKind = FileKind.FILE_KIND_FILE;
        private DmFileProvider.ProviderCatalogException deleteFailure;
        private int createCount;
        private int openCount;

        @Override
        public List<Document> exactChildren(
                DmFileProvider.SafRoot root,
                String parentDocumentId,
                String displayName
        ) {
            ArrayList<Document> matches = new ArrayList<>();
            for (FakeEntry entry : entries) {
                if (displayName.equals(entry.displayName)) {
                    matches.add(document(entry));
                }
            }
            return matches;
        }

        @Override
        public Document create(
                DmFileProvider.SafRoot root,
                String parentDocumentId,
                String finalDisplayName,
                String requestedDisplayName
        ) {
            createCount += 1;
            FakeEntry created = new FakeEntry(
                    "created-" + createCount,
                    createdNameOverride == null ? requestedDisplayName : createdNameOverride,
                    createdKind,
                    0
            );
            entries.add(created);
            if (addDuplicateOnCreate) {
                entries.add(new FakeEntry(
                        "duplicate-created",
                        requestedDisplayName,
                        FileKind.FILE_KIND_FILE,
                        0
                ));
            }
            return document(created);
        }

        @Override
        public boolean delete(DmFileProvider.SafRoot root, Document document)
                throws DmFileProvider.ProviderCatalogException {
            if (deleteFailure != null) {
                if (removeBeforeDeleteFailure) {
                    entries.removeIf(entry -> document.documentId.equals(entry.documentId));
                }
                throw deleteFailure;
            }
            deletedIds.add(document.documentId);
            if (removeOnDelete) {
                entries.removeIf(entry -> document.documentId.equals(entry.documentId));
            }
            return deleteResult;
        }

        @Override
        public OutputStream openOutput(
                DmFileProvider.SafRoot root,
                Document document,
                boolean append
        ) {
            openCount += 1;
            return new ByteArrayOutputStream();
        }

        @Override
        public void truncate(
                DmFileProvider.SafRoot root,
                Document document,
                long offsetBytes
        ) {
            entry(document).sizeBytes = offsetBytes;
        }

        @Override
        public SafDocumentOperations operations(
                DmFileProvider.SafRoot root,
                String parentDocumentId,
                Document document
        ) {
            return new SafDocumentOperations() {
                @Override
                public ProviderSafCatalog.MutationIdentity verifyPublished() {
                    FakeEntry value = entry(document);
                    return identity(value);
                }

                @Override
                public ProviderSafCatalog.MutationIdentity rename(String displayName) {
                    FakeEntry value = entry(document);
                    value.displayName = displayName;
                    return identity(value);
                }

                @Override
                public void delete() {
                    Iterator<FakeEntry> iterator = entries.iterator();
                    while (iterator.hasNext()) {
                        if (document.documentId.equals(iterator.next().documentId)) {
                            iterator.remove();
                            return;
                        }
                    }
                }

                private ProviderSafCatalog.MutationIdentity identity(
                        FakeEntry value
                ) {
                    return new ProviderSafCatalog.MutationIdentity(
                            value.documentId,
                            value.displayName,
                            value.kind,
                            value.sizeBytes
                    );
                }
            };
        }

        int exactNameCount(String displayName) {
            int count = 0;
            for (FakeEntry entry : entries) {
                if (displayName.equals(entry.displayName)) {
                    count += 1;
                }
            }
            return count;
        }

        private Document document(FakeEntry entry) {
            return new Document(
                    entry.documentId,
                    entry.displayName,
                    entry.kind,
                    entry.sizeBytes,
                    entry
            );
        }

        private FakeEntry entry(Document document) {
            return (FakeEntry) document.platformHandle;
        }
    }

    private static final class FakeEntry {
        private final String documentId;
        private String displayName;
        private final FileKind kind;
        private long sizeBytes;

        private FakeEntry(
                String documentId,
                String displayName,
                FileKind kind,
                long sizeBytes
        ) {
            this.documentId = documentId;
            this.displayName = displayName;
            this.kind = kind;
            this.sizeBytes = sizeBytes;
        }
    }
}
