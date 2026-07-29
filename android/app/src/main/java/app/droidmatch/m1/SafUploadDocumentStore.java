package app.droidmatch.m1;

import android.content.ContentResolver;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;

import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.m1.DmFileProvider.SafRoot;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;

import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * Narrow SAF document seam used by upload-open orchestration.
 *
 * <p>The Android implementation owns resolver/URI calls. Tests use an
 * in-memory provider so delete, re-query, duplicate-name, and auto-rename
 * outcomes can be exercised deterministically without a device.</p>
 */
interface SafUploadDocumentStore {
    List<Document> exactChildren(
            DmFileProvider.SafRoot root,
            String parentDocumentId,
            String displayName
    ) throws ProviderCatalogException;

    Document create(
            DmFileProvider.SafRoot root,
            String parentDocumentId,
            String finalDisplayName,
            String requestedDisplayName
    ) throws ProviderCatalogException;

    boolean delete(DmFileProvider.SafRoot root, Document document)
            throws ProviderCatalogException;

    OutputStream openOutput(
            DmFileProvider.SafRoot root,
            Document document,
            boolean append
    ) throws ProviderCatalogException;

    void truncate(
            DmFileProvider.SafRoot root,
            Document document,
            long offsetBytes
    ) throws ProviderCatalogException;

    SafDocumentOperations operations(
            DmFileProvider.SafRoot root,
            String parentDocumentId,
            Document document
    );

    final class Document {
        final String documentId;
        final String displayName;
        final FileKind kind;
        final long sizeBytes;
        final Object platformHandle;

        Document(
                String documentId,
                String displayName,
                FileKind kind,
                long sizeBytes,
                Object platformHandle
        ) {
            this.documentId = documentId;
            this.displayName = displayName;
            this.kind = kind;
            this.sizeBytes = sizeBytes;
            this.platformHandle = platformHandle;
        }
    }
}

final class AndroidSafUploadDocumentStore implements SafUploadDocumentStore {
    private final ContentResolver contentResolver;

    AndroidSafUploadDocumentStore(ContentResolver contentResolver) {
        this.contentResolver = contentResolver;
    }

    @Override
    public List<Document> exactChildren(
            SafRoot root,
            String parentDocumentId,
            String displayName
    ) throws ProviderCatalogException {
        Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                root.treeUri,
                parentDocumentId
        );
        try (Cursor cursor = contentResolver.query(
                childrenUri,
                SafDocumentCursorReader.projection(),
                null,
                null,
                null
        )) {
            if (cursor == null) {
                throw error(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "SAF provider did not return a child query"
                );
            }
            ArrayList<Document> documents = new ArrayList<>();
            for (SafDocumentCursorReader.ChildDocument child
                    : SafDocumentCursorReader.childrenByDisplayName(cursor, displayName, 2)) {
                documents.add(new Document(
                        child.documentId,
                        displayName,
                        child.kind,
                        child.sizeBytes,
                        new DocumentHandle(
                                parentDocumentId,
                                DocumentsContract.buildDocumentUriUsingTree(
                                        root.treeUri,
                                        child.documentId
                                )
                        )
                ));
            }
            return documents;
        } catch (SecurityException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF permission is required to read this root"
            );
        } catch (RuntimeException exception) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "SAF query failed");
        }
    }

    @Override
    public Document create(
            SafRoot root,
            String parentDocumentId,
            String finalDisplayName,
            String requestedDisplayName
    ) throws ProviderCatalogException {
        Uri parentUri = DocumentsContract.buildDocumentUriUsingTree(
                root.treeUri,
                parentDocumentId
        );
        Uri createdUri = null;
        try {
            createdUri = DocumentsContract.createDocument(
                    contentResolver,
                    parentUri,
                    ProviderMimeTypes.fromDisplayName(finalDisplayName),
                    requestedDisplayName
            );
            if (createdUri == null) {
                throw error(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "SAF upload document could not be created"
                );
            }
            Uri canonicalUri = AndroidSafMutationIdentityReader.canonicalUri(
                    root.treeUri,
                    createdUri
            );
            String documentId = DocumentsContract.getDocumentId(canonicalUri);
            return new Document(
                    documentId,
                    requestedDisplayName,
                    FileKind.FILE_KIND_FILE,
                    -1,
                    new DocumentHandle(parentDocumentId, canonicalUri)
            );
        } catch (FileNotFoundException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "SAF upload destination is not available"
            );
        } catch (SecurityException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF write permission is required to upload this document"
            );
        } catch (IOException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF upload document identity could not be verified"
            );
        } catch (ProviderCatalogException exception) {
            throw exception;
        } catch (RuntimeException exception) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "SAF upload failed");
        }
    }

    @Override
    public boolean delete(SafRoot root, Document document) throws ProviderCatalogException {
        try {
            ProviderSafCatalog.MutationIdentity exact =
                    AndroidSafMutationIdentityReader.uniqueExactChild(
                            contentResolver,
                            root.treeUri,
                            documentParentId(document),
                            document.displayName
                    );
            if (exact == null
                    || !document.documentId.equals(exact.documentId)
                    || exact.kind != FileKind.FILE_KIND_FILE) {
                throw error(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "SAF upload partial identity could not be verified"
                );
            }
            return DocumentsContract.deleteDocument(contentResolver, uri(document));
        } catch (FileNotFoundException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "SAF upload partial is not available"
            );
        } catch (SecurityException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF write permission is required to discard the upload partial"
            );
        } catch (IOException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF upload partial identity could not be verified"
            );
        } catch (RuntimeException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF upload partial could not be discarded"
            );
        }
    }

    @Override
    public OutputStream openOutput(
            SafRoot root,
            Document document,
            boolean append
    ) throws ProviderCatalogException {
        try {
            OutputStream output = contentResolver.openOutputStream(
                    uri(document),
                    append ? "wa" : "w"
            );
            if (output == null) {
                throw error(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "SAF upload document could not be opened"
                );
            }
            return output;
        } catch (FileNotFoundException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "SAF upload destination is not available"
            );
        } catch (SecurityException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF write permission is required to upload this document"
            );
        } catch (ProviderCatalogException exception) {
            throw exception;
        } catch (RuntimeException exception) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "SAF upload failed");
        }
    }

    @Override
    public void truncate(SafRoot root, Document document, long offsetBytes)
            throws ProviderCatalogException {
        try {
            ParcelFileDescriptor descriptor =
                    contentResolver.openFileDescriptor(uri(document), "rw");
            if (descriptor == null) {
                throw new IOException("SAF provider returned no writable descriptor");
            }
            try (FileOutputStream stream =
                         new ParcelFileDescriptor.AutoCloseOutputStream(descriptor)) {
                stream.getChannel().truncate(offsetBytes);
            }
        } catch (FileNotFoundException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "SAF upload partial is not available"
            );
        } catch (SecurityException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF write permission is required to reconcile the upload partial"
            );
        } catch (IOException | RuntimeException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "SAF provider cannot reconcile the upload partial"
            );
        }
    }

    @Override
    public SafDocumentOperations operations(
            SafRoot root,
            String parentDocumentId,
            Document document
    ) {
        return new AndroidSafDocumentOperations(
                contentResolver,
                root.treeUri,
                parentDocumentId,
                document.documentId,
                document.displayName,
                uri(document)
        );
    }

    private static String documentParentId(Document document) {
        return ((DocumentHandle) document.platformHandle).parentDocumentId;
    }

    private static Uri uri(Document document) {
        Object handle = document.platformHandle;
        return handle instanceof DocumentHandle
                ? ((DocumentHandle) handle).uri
                : (Uri) handle;
    }

    private static final class DocumentHandle {
        final String parentDocumentId;
        final Uri uri;

        private DocumentHandle(String parentDocumentId, Uri uri) {
            this.parentDocumentId = parentDocumentId;
            this.uri = uri;
        }
    }

    private static ProviderCatalogException error(ErrorCode code, String message) {
        return new ProviderCatalogException(code, message);
    }
}
