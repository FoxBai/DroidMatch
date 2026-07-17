package app.droidmatch.m1;

import android.content.ContentResolver;
import android.content.UriPermission;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;

import app.droidmatch.m1.DmFileProvider.DownloadChunk;
import app.droidmatch.m1.DmFileProvider.DownloadReader;
import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.m1.DmFileProvider.ProviderQuery;
import app.droidmatch.m1.DmFileProvider.SafItem;
import app.droidmatch.m1.DmFileProvider.SafPage;
import app.droidmatch.m1.DmFileProvider.SafRoot;
import app.droidmatch.m1.DmFileProvider.UploadWriter;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;

import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

/**
 * Storage Access Framework catalog backed by persisted tree permissions.
 *
 * <p>The provider facade owns process-local logical-token mapping. This catalog
 * owns platform tree/document IDs, live permission failures, sorted paging,
 * seekable/stream reads, and mutation admission. The extracted upload opener
 * owns transfer-ID partial creation, reconciliation, and pre-writer cleanup.</p>
 */
final class AndroidSafCatalog implements ProviderSafCatalog {
    private final ContentResolver contentResolver;
    private final AndroidSafUploadOpener uploadOpener;

    AndroidSafCatalog(ContentResolver contentResolver) {
        this.contentResolver = contentResolver;
        this.uploadOpener = new AndroidSafUploadOpener(contentResolver);
    }

    @Override
    public List<SafRoot> roots() {
        ArrayList<SafRoot> roots = new ArrayList<>();
        for (UriPermission permission : contentResolver.getPersistedUriPermissions()) {
            if (!permission.isReadPermission()) {
                continue;
            }
            Uri treeUri = permission.getUri();
            String documentId;
            try {
                documentId = DocumentsContract.getTreeDocumentId(treeUri);
            } catch (RuntimeException exception) {
                continue;
            }
            String stableId = ProviderOpaqueIds.stable(treeUri.toString(), 6);
            String displayName = documentDisplayName(
                    treeUri,
                    documentId,
                    "SAF Root " + stableId
            );
            roots.add(new SafRoot(stableId, treeUri, documentId, displayName, permission.isWritePermission()));
        }
        Collections.sort(roots, Comparator.comparing(root -> root.displayName, String.CASE_INSENSITIVE_ORDER));
        return roots;
    }

    @Override
    public SafPage listChildren(
            SafRoot root,
            String documentId,
            ProviderQuery query
    ) throws ProviderCatalogException {
        if (root.treeUri == null) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF root is missing its platform URI"
            );
        }

        Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(root.treeUri, documentId);
        try (Cursor cursor = contentResolver.query(
                childrenUri,
                SafDocumentCursorReader.projection(),
                null,
                null,
                null
        )) {
            if (cursor == null) {
                return new SafPage(new ArrayList<>(), false);
            }
            ProviderBoundedPageSelector<SafItem> selector = new ProviderBoundedPageSelector<>(
                    SafDocumentPolicy.comparator(query.sortField(), query.descending()),
                    query.offset(),
                    query.limit()
            );
            SafDocumentCursorReader.readItems(cursor, root.canWrite, query.searchQuery(), selector);
            ProviderBoundedPageSelector.Page<SafItem> page = selector.page();
            return new SafPage(page.items, page.hasMore);
        } catch (ProviderBoundedPageSelector.ScanLimitExceededException exception) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "directory query exceeds the M1 scan horizon"
            );
        } catch (SecurityException exception) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF permission is required to list this root"
            );
        } catch (RuntimeException exception) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF query failed"
            );
        }
    }

    @Override
    public DownloadChunk readDocument(
            SafRoot root,
            String documentId,
            long offsetBytes,
            int chunkSizeBytes
    ) throws ProviderCatalogException {
        try (DownloadReader reader = openDocument(root, documentId, offsetBytes, chunkSizeBytes)) {
            return reader.readNextChunk();
        }
    }

    @Override
    public DownloadReader openDocument(
            SafRoot root,
            String documentId,
            long offsetBytes,
            int chunkSizeBytes
    ) throws ProviderCatalogException {
        if (root.treeUri == null) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF root is missing its platform URI"
            );
        }
        ProviderLiveAuthorization authorization = () -> requirePersistedPermission(
                root,
                false,
                "SAF permission is required to read this document"
        );
        authorization.requireAuthorized();

        SafDocumentCursorReader.Metadata metadata = safDocumentMetadata(root.treeUri, documentId);
        if (metadata.kind == FileKind.FILE_KIND_DIRECTORY) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "transfer source_path must identify a file entry"
            );
        }
        if (metadata.kind != FileKind.FILE_KIND_FILE) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "SAF virtual documents are not supported for transfer"
            );
        }

        Uri documentUri = DocumentsContract.buildDocumentUriUsingTree(root.treeUri, documentId);
        String providerEtag = "saf:" + root.stableId + ":" + ProviderOpaqueIds.stable(documentId, 8) + ":"
                + metadata.modifiedUnixMillis + ":" + metadata.sizeBytes;
        DownloadReader seekableReader = ProviderDownloadReaders.seekableOrNull(
                contentResolver,
                documentUri,
                offsetBytes,
                chunkSizeBytes,
                metadata.sizeBytes,
                metadata.modifiedUnixMillis,
                providerEtag,
                "SAF permission is required to read this document",
                "SAF read failed"
        );
        if (seekableReader != null) {
            return ProviderAuthorizedTransfers.download(seekableReader, authorization);
        }

        InputStream inputStream = null;
        try {
            inputStream = contentResolver.openInputStream(documentUri);
            if (inputStream == null) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "SAF document is not available"
                );
            }
            ProviderDownloadReaders.skipFully(inputStream, offsetBytes);
            return ProviderAuthorizedTransfers.download(ProviderDownloadReaders.stream(
                    inputStream,
                    offsetBytes,
                    chunkSizeBytes,
                    metadata.sizeBytes,
                    metadata.modifiedUnixMillis,
                    providerEtag,
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF permission is required to read this document",
                    "SAF read failed"
            ), authorization);
        } catch (SecurityException exception) {
            ProviderIoCleanup.closeQuietly(inputStream);
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF permission is required to read this document"
            );
        } catch (ProviderCatalogException exception) {
            ProviderIoCleanup.closeQuietly(inputStream);
            throw exception;
        } catch (IOException exception) {
            ProviderIoCleanup.closeQuietly(inputStream);
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF read failed"
            );
        }
    }

    @Override
    public UploadWriter openUploadDocument(
            SafRoot root,
            String parentDocumentId,
            String displayName,
            String transferId,
            long offsetBytes,
            long expectedSizeBytes
    ) throws ProviderCatalogException {
        if (root.treeUri == null) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF root is missing its platform URI"
            );
        }
        ProviderLiveAuthorization authorization = () -> requirePersistedPermission(
                root,
                true,
                "SAF write permission is required to upload this document"
        );
        authorization.requireAuthorized();
        if (!root.canWrite) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF write permission is required to upload this document"
            );
        }
        SafDocumentCursorReader.Metadata parentMetadata = safDocumentMetadata(root.treeUri, parentDocumentId);
        if (parentMetadata.kind != FileKind.FILE_KIND_DIRECTORY) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "SAF upload destination parent must identify a directory"
            );
        }
        if (!parentMetadata.canCreate) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "SAF directory does not support creating files"
            );
        }

        UploadWriter writer = uploadOpener.open(
                root,
                parentDocumentId,
                displayName,
                transferId,
                offsetBytes,
                expectedSizeBytes,
                authorization
        );
        return ProviderAuthorizedTransfers.upload(writer, authorization);
    }

    @Override
    public void discardUploadPartial(
            SafRoot root,
            String parentDocumentId,
            String displayName,
            String transferId,
            long expectedSizeBytes
    ) throws ProviderCatalogException {
        if (root.treeUri == null) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF root is missing its platform URI"
            );
        }
        requirePersistedPermission(
                root,
                true,
                "SAF write permission is required to discard the upload partial"
        );
        SafDocumentCursorReader.Metadata parentMetadata = safDocumentMetadata(
                root.treeUri,
                parentDocumentId
        );
        if (parentMetadata.kind != FileKind.FILE_KIND_DIRECTORY) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "SAF upload destination parent must identify a directory"
            );
        }
        uploadOpener.discardPartial(
                root,
                parentDocumentId,
                displayName,
                transferId,
                expectedSizeBytes
        );
    }

    @Override
    public void createDirectory(SafRoot root, String parentDocumentId, String displayName)
            throws ProviderCatalogException {
        if (root.treeUri == null) {
            throw new ProviderCatalogException(ErrorCode.ERROR_CODE_INTERNAL, "SAF root is missing its platform URI");
        }
        if (!root.canWrite) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF write permission is required to create a directory"
            );
        }
        SafDocumentCursorReader.Metadata parentMetadata = safDocumentMetadata(root.treeUri, parentDocumentId);
        if (parentMetadata.kind != FileKind.FILE_KIND_DIRECTORY) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "SAF directory parent must identify a directory"
            );
        }
        if (!parentMetadata.canCreate) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "SAF directory does not support creating children"
            );
        }
        Uri parentUri = DocumentsContract.buildDocumentUriUsingTree(root.treeUri, parentDocumentId);
        try {
            Uri created = DocumentsContract.createDocument(
                    contentResolver,
                    parentUri,
                    DocumentsContract.Document.MIME_TYPE_DIR,
                    displayName
            );
            if (created == null) {
                throw new ProviderCatalogException(ErrorCode.ERROR_CODE_INTERNAL, "SAF directory could not be created");
            }
        } catch (SecurityException exception) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF write permission is required to create a directory"
            );
        } catch (FileNotFoundException exception) {
            throw new ProviderCatalogException(ErrorCode.ERROR_CODE_NOT_FOUND, "SAF parent directory is unavailable");
        } catch (RuntimeException exception) {
            throw new ProviderCatalogException(ErrorCode.ERROR_CODE_INTERNAL, "SAF directory creation failed");
        }
    }

    @Override
    public void renameDocument(SafRoot root, String documentId, String displayName)
            throws ProviderCatalogException {
        if (root.treeUri == null) {
            throw new ProviderCatalogException(ErrorCode.ERROR_CODE_INTERNAL, "SAF root is missing its platform URI");
        }
        if (!root.canWrite) {
            throw new ProviderCatalogException(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, "SAF write permission is required to rename");
        }
        Uri documentUri = DocumentsContract.buildDocumentUriUsingTree(root.treeUri, documentId);
        try {
            Uri renamed = DocumentsContract.renameDocument(contentResolver, documentUri, displayName);
            if (renamed == null) {
                throw new ProviderCatalogException(ErrorCode.ERROR_CODE_INTERNAL, "SAF document could not be renamed");
            }
        } catch (SecurityException exception) {
            throw new ProviderCatalogException(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, "SAF write permission is required to rename");
        } catch (FileNotFoundException exception) {
            throw new ProviderCatalogException(ErrorCode.ERROR_CODE_NOT_FOUND, "SAF document is unavailable");
        } catch (RuntimeException exception) {
            throw new ProviderCatalogException(ErrorCode.ERROR_CODE_INTERNAL, "SAF rename failed");
        }
    }

    @Override
    public void deleteDocument(SafRoot root, String documentId, boolean recursive)
            throws ProviderCatalogException {
        if (root.treeUri == null) {
            throw new ProviderCatalogException(ErrorCode.ERROR_CODE_INTERNAL, "SAF root is missing its platform URI");
        }
        if (!root.canWrite) {
            throw new ProviderCatalogException(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, "SAF write permission is required to delete");
        }
        SafDocumentCursorReader.Metadata metadata = safDocumentMetadata(root.treeUri, documentId);
        if (metadata.kind == FileKind.FILE_KIND_DIRECTORY && !recursive) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "SAF directory deletion requires recursive confirmation"
            );
        }
        Uri documentUri = DocumentsContract.buildDocumentUriUsingTree(root.treeUri, documentId);
        try {
            if (!DocumentsContract.deleteDocument(contentResolver, documentUri)) {
                throw new ProviderCatalogException(ErrorCode.ERROR_CODE_INTERNAL, "SAF document could not be deleted");
            }
        } catch (SecurityException exception) {
            throw new ProviderCatalogException(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, "SAF write permission is required to delete");
        } catch (FileNotFoundException exception) {
            throw new ProviderCatalogException(ErrorCode.ERROR_CODE_NOT_FOUND, "SAF document is unavailable");
        } catch (RuntimeException exception) {
            throw new ProviderCatalogException(ErrorCode.ERROR_CODE_INTERNAL, "SAF delete failed");
        }
    }

    private String documentDisplayName(Uri treeUri, String documentId, String fallback) {
        Uri documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId);
        try (Cursor cursor = contentResolver.query(
                documentUri,
                new String[] { DocumentsContract.Document.COLUMN_DISPLAY_NAME },
                null,
                null,
                null
        )) {
            if (cursor != null) {
                return SafDocumentCursorReader.firstDisplayName(cursor, fallback);
            }
        } catch (RuntimeException exception) {
            return fallback;
        }
        return fallback;
    }

    private SafDocumentCursorReader.Metadata safDocumentMetadata(
            Uri treeUri,
            String documentId
    ) throws ProviderCatalogException {
        Uri documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId);
        try (Cursor cursor = contentResolver.query(
                documentUri,
                SafDocumentCursorReader.projection(),
                null,
                null,
                null
        )) {
            if (cursor == null) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "SAF document is not available"
                );
            }
            SafDocumentCursorReader.Metadata metadata = SafDocumentCursorReader.firstMetadata(cursor);
            if (metadata == null) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "SAF document is not available"
                );
            }
            return metadata;
        } catch (SecurityException exception) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF permission is required to read this document"
            );
        } catch (ProviderCatalogException exception) {
            throw exception;
        } catch (RuntimeException exception) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF metadata query failed"
            );
        }
    }

    private void requirePersistedPermission(
            SafRoot root,
            boolean requireWrite,
            String failureMessage
    ) throws ProviderCatalogException {
        try {
            for (UriPermission permission : contentResolver.getPersistedUriPermissions()) {
                if (root.treeUri.equals(permission.getUri())
                        && permission.isReadPermission()
                        && (!requireWrite || permission.isWritePermission())) {
                    return;
                }
            }
        } catch (SecurityException exception) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    failureMessage
            );
        } catch (RuntimeException exception) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF permission state could not be read"
            );
        }
        throw new ProviderCatalogException(
                ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                failureMessage
        );
    }

}
