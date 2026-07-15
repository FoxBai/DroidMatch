package app.droidmatch.m1;

import android.content.ContentResolver;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;

import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.m1.DmFileProvider.SafRoot;
import app.droidmatch.m1.DmFileProvider.UploadWriter;
import app.droidmatch.proto.v1.ErrorCode;

import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;

/**
 * Owns SAF upload-open resolver calls from destination creation through writer
 * handoff. The catalog validates the live root and parent capability first;
 * this boundary then keeps partial lookup, ACK-loss truncation, and every
 * pre-writer cleanup path together.
 *
 * <p>中文：独占 SAF 上传从目标创建到 writer 交接的 resolver 生命周期；catalog
 * 先验证实时 root/parent 能力，本边界集中管理 partial 查找、ACK 丢失截断和
 * writer 交接前的全部清理路径。</p>
 */
final class AndroidSafUploadOpener {
    private final ContentResolver contentResolver;

    AndroidSafUploadOpener(ContentResolver contentResolver) {
        this.contentResolver = contentResolver;
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
        Uri parentUri = DocumentsContract.buildDocumentUriUsingTree(root.treeUri, parentDocumentId);
        Uri documentUri = null;
        OutputStream outputStream = null;
        long initialOffsetBytes = offsetBytes;
        String finalDisplayName = null;
        boolean deleteOnNonFinalClose = true;
        boolean deleteDocumentOnOpenFailure = false;
        try {
            SafUploadOpenPolicy.Mode mode = SafUploadOpenPolicy.mode(transferId, offsetBytes);
            if (mode == SafUploadOpenPolicy.Mode.FRESH) {
                documentUri = createSafDocument(parentUri, displayName, displayName);
                deleteDocumentOnOpenFailure = true;
            } else {
                String partialDisplayName = SafDocumentPolicy.uploadPartialDisplayName(
                        root.stableId,
                        parentDocumentId,
                        displayName,
                        transferId
                );
                finalDisplayName = displayName;
                deleteOnNonFinalClose = false;
                if (mode == SafUploadOpenPolicy.Mode.RESTART_RESUMABLE) {
                    deleteSafChildByDisplayName(root, parentDocumentId, partialDisplayName);
                    documentUri = createSafDocument(parentUri, displayName, partialDisplayName);
                    deleteDocumentOnOpenFailure = true;
                } else {
                    SafDocumentCursorReader.ChildDocument partialDocument = safChildByDisplayName(
                            root,
                            parentDocumentId,
                            partialDisplayName
                    );
                    boolean requiresTruncation = SafUploadOpenPolicy.requiresTruncation(
                            partialDocument,
                            offsetBytes
                    );
                    documentUri = DocumentsContract.buildDocumentUriUsingTree(
                            root.treeUri,
                            partialDocument.documentId
                    );
                    if (requiresTruncation) {
                        truncateSafUploadPartial(documentUri, offsetBytes);
                    }
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
                    new AndroidSafDocumentOperations(contentResolver, documentUri),
                    outputStream,
                    expectedSizeBytes,
                    initialOffsetBytes,
                    finalDisplayName,
                    deleteOnNonFinalClose,
                    commitAuthorization
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

    /**
     * Reconciles an ACK-loss window to the last durable Mac acknowledgement.
     *
     * <p>SAF providers are not uniformly seekable, so truncation is attempted
     * only when the provider reports that its hidden partial is ahead. A
     * provider that cannot expose a seekable descriptor fails with a stable
     * capability error instead of appending duplicate bytes.</p>
     */
    private void truncateSafUploadPartial(Uri documentUri, long offsetBytes)
            throws ProviderCatalogException {
        try {
            ParcelFileDescriptor descriptor = contentResolver.openFileDescriptor(documentUri, "rw");
            if (descriptor == null) {
                throw new IOException("SAF provider returned no writable descriptor");
            }
            try (FileOutputStream stream = new ParcelFileDescriptor.AutoCloseOutputStream(descriptor)) {
                stream.getChannel().truncate(offsetBytes);
            }
        } catch (FileNotFoundException exception) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "SAF upload partial is not available"
            );
        } catch (SecurityException exception) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF write permission is required to reconcile the upload partial"
            );
        } catch (IOException | RuntimeException exception) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                    "SAF provider cannot reconcile the upload partial"
            );
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
        SafDocumentCursorReader.ChildDocument child = safChildByDisplayName(
                root,
                parentDocumentId,
                displayName
        );
        if (child != null) {
            ProviderIoCleanup.deleteDocumentQuietly(
                    contentResolver,
                    DocumentsContract.buildDocumentUriUsingTree(root.treeUri, child.documentId)
            );
        }
    }

    private SafDocumentCursorReader.ChildDocument safChildByDisplayName(
            SafRoot root,
            String parentDocumentId,
            String displayName
    ) throws ProviderCatalogException {
        Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(root.treeUri, parentDocumentId);
        try (Cursor cursor = contentResolver.query(
                childrenUri,
                SafDocumentCursorReader.projection(),
                null,
                null,
                null
        )) {
            if (cursor == null) {
                return null;
            }
            return SafDocumentCursorReader.childByDisplayName(cursor, displayName);
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
}
