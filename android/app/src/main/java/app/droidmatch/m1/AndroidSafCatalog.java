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
import app.droidmatch.m1.DmFileProvider.SafCatalog;
import app.droidmatch.m1.DmFileProvider.SafItem;
import app.droidmatch.m1.DmFileProvider.SafPage;
import app.droidmatch.m1.DmFileProvider.SafRoot;
import app.droidmatch.m1.DmFileProvider.UploadWriter;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.SortField;

import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

/**
 * Storage Access Framework catalog backed by persisted tree permissions.
 *
 * <p>The provider facade owns process-local logical-token mapping. This catalog
 * owns platform tree/document IDs, live permission failures, sorted paging,
 * seekable/stream reads, and transfer-ID-keyed upload partial documents.</p>
 */
final class AndroidSafCatalog implements SafCatalog {
    private static final String[] DOCUMENT_PROJECTION = new String[] {
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_FLAGS
    };

    private final ContentResolver contentResolver;

    AndroidSafCatalog(ContentResolver contentResolver) {
        this.contentResolver = contentResolver;
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
        try (Cursor cursor = contentResolver.query(childrenUri, DOCUMENT_PROJECTION, null, null, null)) {
            if (cursor == null) {
                return new SafPage(new ArrayList<>(), false);
            }
            ArrayList<SafItem> allItems = readSafCursor(cursor, root.canWrite);
            Collections.sort(allItems, safComparator(query.sortField(), query.descending()));
            return pageSafItems(allItems, query.offset(), query.limit());
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

        SafDocumentMetadata metadata = safDocumentMetadata(root.treeUri, documentId);
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
            return seekableReader;
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
            return ProviderDownloadReaders.stream(
                    inputStream,
                    offsetBytes,
                    chunkSizeBytes,
                    metadata.sizeBytes,
                    metadata.modifiedUnixMillis,
                    providerEtag,
                    "SAF read failed"
            );
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
        if (!root.canWrite) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF write permission is required to upload this document"
            );
        }
        SafDocumentMetadata parentMetadata = safDocumentMetadata(root.treeUri, parentDocumentId);
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

        Uri parentUri = DocumentsContract.buildDocumentUriUsingTree(root.treeUri, parentDocumentId);
        Uri documentUri = null;
        OutputStream outputStream = null;
        long initialOffsetBytes = offsetBytes;
        String finalDisplayName = null;
        boolean deleteOnNonFinalClose = true;
        boolean deleteDocumentOnOpenFailure = false;
        try {
            if (transferId.isEmpty()) {
                if (offsetBytes != 0) {
                    throw new ProviderCatalogException(
                            ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                            "SAF upload resume requires a transfer_id"
                    );
                }
                documentUri = createSafDocument(parentUri, displayName, displayName);
                deleteDocumentOnOpenFailure = true;
            } else {
                String partialDisplayName = safUploadPartialDisplayName(
                        root,
                        parentDocumentId,
                        displayName,
                        transferId
                );
                finalDisplayName = displayName;
                deleteOnNonFinalClose = false;
                if (offsetBytes == 0) {
                    deleteSafChildByDisplayName(root, parentDocumentId, partialDisplayName);
                    documentUri = createSafDocument(parentUri, displayName, partialDisplayName);
                    deleteDocumentOnOpenFailure = true;
                } else {
                    SafChildDocument partialDocument = safChildByDisplayName(
                            root,
                            parentDocumentId,
                            partialDisplayName
                    );
                    if (partialDocument == null) {
                        throw new ProviderCatalogException(
                                ErrorCode.ERROR_CODE_NOT_FOUND,
                                "SAF upload partial is not available"
                        );
                    }
                    if (partialDocument.kind != FileKind.FILE_KIND_FILE) {
                        throw new ProviderCatalogException(
                                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                                "SAF upload partial must identify a file entry"
                        );
                    }
                    if (partialDocument.sizeBytes != offsetBytes) {
                        throw new ProviderCatalogException(
                                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                                "requested_offset_bytes does not match SAF upload partial"
                        );
                    }
                    documentUri = DocumentsContract.buildDocumentUriUsingTree(
                            root.treeUri,
                            partialDocument.documentId
                    );
                }
            }
            outputStream = contentResolver.openOutputStream(documentUri, offsetBytes == 0 ? "w" : "wa");
            if (outputStream == null) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "SAF upload document could not be opened"
                );
            }
            return new SafUploadWriter(
                    contentResolver,
                    documentUri,
                    outputStream,
                    expectedSizeBytes,
                    initialOffsetBytes,
                    finalDisplayName,
                    deleteOnNonFinalClose
            );
        } catch (SecurityException exception) {
            ProviderIoCleanup.closeQuietly(outputStream);
            if (deleteDocumentOnOpenFailure) {
                ProviderIoCleanup.deleteDocumentQuietly(contentResolver, documentUri);
            }
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF write permission is required to upload this document"
            );
        } catch (ProviderCatalogException exception) {
            ProviderIoCleanup.closeQuietly(outputStream);
            if (deleteDocumentOnOpenFailure) {
                ProviderIoCleanup.deleteDocumentQuietly(contentResolver, documentUri);
            }
            throw exception;
        } catch (FileNotFoundException exception) {
            ProviderIoCleanup.closeQuietly(outputStream);
            if (deleteDocumentOnOpenFailure) {
                ProviderIoCleanup.deleteDocumentQuietly(contentResolver, documentUri);
            }
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "SAF upload destination is not available"
            );
        } catch (RuntimeException exception) {
            ProviderIoCleanup.closeQuietly(outputStream);
            if (deleteDocumentOnOpenFailure) {
                ProviderIoCleanup.deleteDocumentQuietly(contentResolver, documentUri);
            }
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF upload failed"
            );
        }
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
        SafDocumentMetadata parentMetadata = safDocumentMetadata(root.treeUri, parentDocumentId);
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

    private Uri createSafDocument(Uri parentUri, String finalDisplayName, String displayName)
            throws ProviderCatalogException {
        try {
            Uri documentUri = DocumentsContract.createDocument(
                    contentResolver,
                    parentUri,
                    ProviderMimeTypes.fromDisplayName(finalDisplayName),
                    displayName
            );
            if (documentUri == null) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "SAF upload document could not be created"
                );
            }
            return documentUri;
        } catch (FileNotFoundException exception) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "SAF upload destination is not available"
            );
        }
    }

    private void deleteSafChildByDisplayName(SafRoot root, String parentDocumentId, String displayName)
            throws ProviderCatalogException {
        SafChildDocument child = safChildByDisplayName(root, parentDocumentId, displayName);
        if (child != null) {
            ProviderIoCleanup.deleteDocumentQuietly(
                    contentResolver,
                    DocumentsContract.buildDocumentUriUsingTree(root.treeUri, child.documentId)
            );
        }
    }

    private SafChildDocument safChildByDisplayName(SafRoot root, String parentDocumentId, String displayName)
            throws ProviderCatalogException {
        Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(root.treeUri, parentDocumentId);
        try (Cursor cursor = contentResolver.query(childrenUri, DOCUMENT_PROJECTION, null, null, null)) {
            if (cursor == null) {
                return null;
            }
            int idColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID);
            int nameColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME);
            int mimeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE);
            int sizeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE);
            int flagsColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_FLAGS);
            while (cursor.moveToNext()) {
                String candidateName = cursor.isNull(nameColumn) ? "" : cursor.getString(nameColumn);
                if (!displayName.equals(candidateName)) {
                    continue;
                }
                String mimeType = cursor.isNull(mimeColumn) ? "" : cursor.getString(mimeColumn);
                int flags = cursor.isNull(flagsColumn) ? 0 : cursor.getInt(flagsColumn);
                boolean isDirectory = DocumentsContract.Document.MIME_TYPE_DIR.equals(mimeType);
                FileKind kind = isDirectory
                        ? FileKind.FILE_KIND_DIRECTORY
                        : ((flags & DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT) != 0
                                ? FileKind.FILE_KIND_VIRTUAL
                                : FileKind.FILE_KIND_FILE);
                long sizeBytes = isDirectory || cursor.isNull(sizeColumn) ? -1 : cursor.getLong(sizeColumn);
                return new SafChildDocument(cursor.getString(idColumn), kind, sizeBytes);
            }
            return null;
        } catch (SecurityException exception) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF permission is required to read this root"
            );
        } catch (RuntimeException exception) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF query failed"
            );
        }
    }

    private static String safUploadPartialDisplayName(
            SafRoot root,
            String parentDocumentId,
            String displayName,
            String transferId
    ) {
        return ".droidmatch-upload-"
                + ProviderOpaqueIds.stable(
                        root.stableId + "\n" + parentDocumentId + "\n" + displayName + "\n" + transferId,
                        10
                )
                + ".part";
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
            if (cursor != null && cursor.moveToFirst() && !cursor.isNull(0)) {
                return cursor.getString(0);
            }
        } catch (RuntimeException exception) {
            return fallback;
        }
        return fallback;
    }

    private SafDocumentMetadata safDocumentMetadata(Uri treeUri, String documentId) throws ProviderCatalogException {
        Uri documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId);
        try (Cursor cursor = contentResolver.query(documentUri, DOCUMENT_PROJECTION, null, null, null)) {
            if (cursor == null || !cursor.moveToFirst()) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "SAF document is not available"
                );
            }
            int mimeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE);
            int sizeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE);
            int modifiedColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED);
            int flagsColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_FLAGS);
            String mimeType = cursor.isNull(mimeColumn) ? "" : cursor.getString(mimeColumn);
            int flags = cursor.isNull(flagsColumn) ? 0 : cursor.getInt(flagsColumn);
            boolean isDirectory = DocumentsContract.Document.MIME_TYPE_DIR.equals(mimeType);
            FileKind kind = isDirectory
                    ? FileKind.FILE_KIND_DIRECTORY
                    : ((flags & DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT) != 0
                            ? FileKind.FILE_KIND_VIRTUAL
                            : FileKind.FILE_KIND_FILE);
            long sizeBytes = isDirectory || cursor.isNull(sizeColumn) ? -1 : cursor.getLong(sizeColumn);
            long modifiedMillis = cursor.isNull(modifiedColumn) ? 0 : cursor.getLong(modifiedColumn);
            boolean canCreate = isDirectory
                    && (flags & DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE) != 0;
            return new SafDocumentMetadata(kind, sizeBytes, modifiedMillis, canCreate);
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

    private static ArrayList<SafItem> readSafCursor(Cursor cursor, boolean rootCanWrite) {
        int idColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID);
        int nameColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME);
        int mimeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE);
        int sizeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE);
        int modifiedColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED);
        int flagsColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_FLAGS);
        ArrayList<SafItem> items = new ArrayList<>();

        while (cursor.moveToNext()) {
            String documentId = cursor.getString(idColumn);
            String displayName = cursor.isNull(nameColumn) ? documentId : cursor.getString(nameColumn);
            String mimeType = cursor.isNull(mimeColumn) ? "" : cursor.getString(mimeColumn);
            boolean isDirectory = DocumentsContract.Document.MIME_TYPE_DIR.equals(mimeType);
            int flags = cursor.isNull(flagsColumn) ? 0 : cursor.getInt(flagsColumn);
            FileKind kind = isDirectory
                    ? FileKind.FILE_KIND_DIRECTORY
                    : ((flags & DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT) != 0
                            ? FileKind.FILE_KIND_VIRTUAL
                            : FileKind.FILE_KIND_FILE);
            long sizeBytes = isDirectory || cursor.isNull(sizeColumn) ? 0 : cursor.getLong(sizeColumn);
            long modifiedMillis = cursor.isNull(modifiedColumn) ? 0 : cursor.getLong(modifiedColumn);
            boolean canWrite = rootCanWrite && supportsWrite(kind, flags);
            items.add(new SafItem(
                    documentId,
                    displayName,
                    kind,
                    sizeBytes,
                    modifiedMillis,
                    mimeType,
                    canWrite
            ));
        }
        return items;
    }

    private static boolean supportsWrite(FileKind kind, int flags) {
        if (kind == FileKind.FILE_KIND_DIRECTORY) {
            return (flags & DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE) != 0;
        }
        return (flags & (DocumentsContract.Document.FLAG_SUPPORTS_WRITE
                | DocumentsContract.Document.FLAG_SUPPORTS_DELETE)) != 0;
    }

    private static SafPage pageSafItems(List<SafItem> items, int offset, int limit) {
        if (offset >= items.size()) {
            return new SafPage(new ArrayList<>(), false);
        }
        int endExclusive = Math.min(items.size(), offset + limit);
        boolean hasMore = endExclusive < items.size();
        return new SafPage(new ArrayList<>(items.subList(offset, endExclusive)), hasMore);
    }

    private static Comparator<SafItem> safComparator(SortField sortField, boolean descending) {
        Comparator<SafItem> comparator;
        switch (sortField) {
            case SORT_FIELD_NAME:
                comparator = Comparator.comparing(item -> item.displayName, String.CASE_INSENSITIVE_ORDER);
                break;
            case SORT_FIELD_SIZE:
                comparator = Comparator.comparingLong(item -> item.sizeBytes);
                break;
            case SORT_FIELD_KIND:
                comparator = Comparator.comparingInt(item -> item.kind.getNumber());
                break;
            case SORT_FIELD_MODIFIED_TIME:
            case SORT_FIELD_UNSPECIFIED:
            case UNRECOGNIZED:
            default:
                comparator = Comparator.comparingLong(item -> item.modifiedUnixMillis);
                break;
        }
        if (descending) {
            comparator = comparator.reversed();
        }
        return comparator
                .thenComparing(item -> item.displayName, String.CASE_INSENSITIVE_ORDER)
                .thenComparing(item -> item.documentId);
    }

    private static final class SafDocumentMetadata {
        private final FileKind kind;
        private final long sizeBytes;
        private final long modifiedUnixMillis;
        private final boolean canCreate;

        private SafDocumentMetadata(
                FileKind kind,
                long sizeBytes,
                long modifiedUnixMillis,
                boolean canCreate
        ) {
            this.kind = kind;
            this.sizeBytes = sizeBytes;
            this.modifiedUnixMillis = modifiedUnixMillis;
            this.canCreate = canCreate;
        }
    }

    private static final class SafChildDocument {
        private final String documentId;
        private final FileKind kind;
        private final long sizeBytes;

        private SafChildDocument(String documentId, FileKind kind, long sizeBytes) {
            this.documentId = documentId;
            this.kind = kind;
            this.sizeBytes = sizeBytes;
        }
    }

}
