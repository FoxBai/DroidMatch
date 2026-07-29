package app.droidmatch.m1;

import android.content.ContentResolver;

import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.m1.DmFileProvider.SafRoot;
import app.droidmatch.m1.DmFileProvider.UploadWriter;
import app.droidmatch.m1.SafUploadDocumentStore.Document;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;

import java.io.OutputStream;
import java.util.List;

/**
 * Owns SAF upload-open orchestration from exact child reconciliation through
 * writer handoff.
 *
 * <p>Restart never trusts a best-effort delete or a provider-created display
 * name. It proves the old exact name is absent, then proves the created
 * document is the unique exact-name child before opening bytes.</p>
 */
final class AndroidSafUploadOpener {
    private final SafUploadDocumentStore documentStore;

    AndroidSafUploadOpener(ContentResolver contentResolver) {
        this(new AndroidSafUploadDocumentStore(contentResolver));
    }

    AndroidSafUploadOpener(SafUploadDocumentStore documentStore) {
        this.documentStore = documentStore;
    }

    UploadWriter open(
            SafRoot root,
            String parentDocumentId,
            String displayName,
            String transferId,
            long offsetBytes,
            long expectedSizeBytes,
            ProviderLiveAuthorization commitAuthorization
    ) throws ProviderCatalogException {
        Document document = null;
        OutputStream outputStream = null;
        String finalDisplayName = null;
        boolean deleteOnNonFinalClose = true;
        boolean deleteDocumentOnOpenFailure = false;
        try {
            SafUploadOpenPolicy.Mode mode = SafUploadOpenPolicy.mode(transferId, offsetBytes);
            String partialDisplayName = SafDocumentPolicy.uploadPartialDisplayName(
                    root.stableId,
                    parentDocumentId,
                    displayName,
                    transferId,
                    expectedSizeBytes
            );
            finalDisplayName = displayName;
            if (uniqueExactChild(root, parentDocumentId, displayName) != null) {
                throw error(
                        ErrorCode.ERROR_CODE_ALREADY_EXISTS,
                        "SAF upload destination already exists"
                );
            }
            if (mode == SafUploadOpenPolicy.Mode.FRESH) {
                deleteRestartPartialVerified(
                        root,
                        parentDocumentId,
                        partialDisplayName,
                        expectedSizeBytes
                );
                document = createVerified(
                        root,
                        parentDocumentId,
                        displayName,
                        partialDisplayName
                );
                deleteDocumentOnOpenFailure = true;
            } else {
                deleteOnNonFinalClose = false;
                if (mode == SafUploadOpenPolicy.Mode.RESTART_RESUMABLE) {
                    deleteRestartPartialVerified(
                            root,
                            parentDocumentId,
                            partialDisplayName,
                            expectedSizeBytes
                    );
                    document = createVerified(
                            root,
                            parentDocumentId,
                            displayName,
                            partialDisplayName
                    );
                    deleteDocumentOnOpenFailure = true;
                } else {
                    document = uniqueExactChild(
                            root,
                            parentDocumentId,
                            partialDisplayName
                    );
                    if (document == null) {
                        throw error(
                                ErrorCode.ERROR_CODE_NOT_FOUND,
                                "SAF upload partial is not available"
                        );
                    }
                    boolean requiresTruncation =
                            SafUploadOpenPolicy.requiresTruncation(
                                    document.kind,
                                    document.sizeBytes,
                                    offsetBytes
                            );
                    if (requiresTruncation) {
                        documentStore.truncate(root, document, offsetBytes);
                    }
                }
            }

            outputStream = documentStore.openOutput(root, document, offsetBytes != 0);
            return new SafUploadWriter(
                    documentStore.operations(root, parentDocumentId, document),
                    outputStream,
                    expectedSizeBytes,
                    offsetBytes,
                    finalDisplayName,
                    deleteOnNonFinalClose,
                    commitAuthorization
            );
        } catch (ProviderCatalogException exception) {
            ProviderIoCleanup.closeQuietly(outputStream);
            if (deleteDocumentOnOpenFailure) {
                deleteExactDocumentQuietly(root, document);
            }
            throw exception;
        } catch (RuntimeException exception) {
            ProviderIoCleanup.closeQuietly(outputStream);
            if (deleteDocumentOnOpenFailure) {
                deleteExactDocumentQuietly(root, document);
            }
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "SAF upload failed");
        }
    }

    void discardPartial(
            SafRoot root,
            String parentDocumentId,
            String displayName,
            String transferId,
            long expectedSizeBytes
    ) throws ProviderCatalogException {
        String partialDisplayName = SafDocumentPolicy.uploadPartialDisplayName(
                root.stableId,
                parentDocumentId,
                displayName,
                transferId,
                expectedSizeBytes
        );
        Document child = uniqueExactChild(root, parentDocumentId, partialDisplayName);
        if (child == null) {
            return;
        }
        validatePartialForCleanup(child, expectedSizeBytes);
        boolean deleted;
        try {
            deleted = documentStore.delete(root, child);
        } catch (ProviderCatalogException exception) {
            if (exception.code != ErrorCode.ERROR_CODE_NOT_FOUND
                    || uniqueExactChild(root, parentDocumentId, partialDisplayName) != null) {
                throw exception;
            }
            return;
        }
        Document remaining = uniqueExactChild(root, parentDocumentId, partialDisplayName);
        if (!deleted || remaining != null) {
            throw error(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF upload partial could not be discarded"
            );
        }
    }

    private void deleteRestartPartialVerified(
            SafRoot root,
            String parentDocumentId,
            String partialDisplayName,
            long expectedSizeBytes
    ) throws ProviderCatalogException {
        Document existing = uniqueExactChild(root, parentDocumentId, partialDisplayName);
        if (existing == null) {
            return;
        }
        validatePartialForCleanup(existing, expectedSizeBytes);
        boolean deleted = documentStore.delete(root, existing);
        Document remaining = uniqueExactChild(root, parentDocumentId, partialDisplayName);
        if (!deleted || remaining != null) {
            throw error(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF upload partial could not be replaced"
            );
        }
    }

    private void validatePartialForCleanup(
            Document document,
            long expectedSizeBytes
    ) throws ProviderCatalogException {
        if (document.kind != FileKind.FILE_KIND_FILE
                || document.documentId == null
                || document.documentId.isEmpty()
                || document.sizeBytes < 0
                || (expectedSizeBytes >= 0
                        && document.sizeBytes > expectedSizeBytes)) {
            throw error(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF upload partial metadata is invalid"
            );
        }
    }

    private Document createVerified(
            SafRoot root,
            String parentDocumentId,
            String finalDisplayName,
            String requestedDisplayName
    ) throws ProviderCatalogException {
        if (!finalDisplayName.equals(requestedDisplayName)
                && uniqueExactChild(
                        root,
                        parentDocumentId,
                        finalDisplayName
                ) != null) {
            throw error(
                    ErrorCode.ERROR_CODE_ALREADY_EXISTS,
                    "SAF upload destination already exists"
            );
        }
        if (uniqueExactChild(root, parentDocumentId, requestedDisplayName) != null) {
            throw error(
                    ErrorCode.ERROR_CODE_ALREADY_EXISTS,
                    "SAF upload destination already exists"
            );
        }
        Document created = documentStore.create(
                root,
                parentDocumentId,
                finalDisplayName,
                requestedDisplayName
        );
        Document exact = uniqueExactChild(root, parentDocumentId, requestedDisplayName);
        if (exact == null
                || exact.kind != FileKind.FILE_KIND_FILE
                || !created.documentId.equals(exact.documentId)) {
            throw error(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF provider did not create the exact requested document"
            );
        }
        return created;
    }

    private Document uniqueExactChild(
            SafRoot root,
            String parentDocumentId,
            String displayName
    ) throws ProviderCatalogException {
        List<Document> matches = documentStore.exactChildren(
                root,
                parentDocumentId,
                displayName
        );
        if (matches.size() > 1) {
            throw error(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF upload document name is ambiguous"
            );
        }
        return matches.isEmpty() ? null : matches.get(0);
    }

    private void deleteExactDocumentQuietly(SafRoot root, Document document) {
        if (document == null) {
            return;
        }
        try {
            documentStore.delete(root, document);
        } catch (ProviderCatalogException | RuntimeException ignored) {
            // Preserve the primary open/verification failure. This deletion is
            // scoped to the create-returned document identity.
        }
    }

    private static ProviderCatalogException error(ErrorCode code, String message) {
        return new ProviderCatalogException(code, message);
    }
}
