package app.droidmatch.m1;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.net.Uri;
import android.provider.DocumentsContract;
import android.provider.MediaStore;

import app.droidmatch.proto.v1.ErrorCode;

import java.io.Closeable;
import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;

/**
 * Provider-specific upload commit/cleanup state machines.
 *
 * <p>{@link DmFileProvider} owns logical path and permission routing. These
 * writers own only ordered chunk validation, provider commit, and non-final
 * close behavior. Keeping that boundary explicit prevents catalog growth from
 * obscuring atomicity and partial-file cleanup rules.</p>
 */
final class ProviderUploadWriters {
    private ProviderUploadWriters() {
    }

    static long validatedNextOffset(
            boolean closed,
            long currentOffsetBytes,
            long expectedSizeBytes,
            long offsetBytes,
            byte[] data,
            boolean finalChunk
    ) throws DmFileProvider.ProviderCatalogException {
        if (closed) {
            throw invalid("upload writer is closed");
        }
        if (offsetBytes != currentOffsetBytes) {
            throw invalid("transfer chunk offset does not match the expected write boundary");
        }
        if (data.length == 0 && !finalChunk) {
            throw invalid("empty upload chunks must be final");
        }
        long nextOffset = currentOffsetBytes + data.length;
        if (expectedSizeBytes >= 0 && nextOffset > expectedSizeBytes) {
            throw invalid("upload chunk exceeds expected_size_bytes");
        }
        if (finalChunk && expectedSizeBytes >= 0 && nextOffset != expectedSizeBytes) {
            throw invalid("final upload chunk does not match expected_size_bytes");
        }
        return nextOffset;
    }

    private static DmFileProvider.ProviderCatalogException invalid(String message) {
        return new DmFileProvider.ProviderCatalogException(
                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                message
        );
    }
}

interface SafDocumentOperations {
    boolean rename(String displayName) throws IOException;

    void delete() throws IOException;
}

interface MediaStoreEntryOperations {
    boolean publish() throws IOException;

    void delete();
}

interface AppSandboxCommitOperations {
    void replaceAtomically(File partialFile, File destinationFile) throws IOException;
}

interface AppSandboxPartialOutput extends Closeable {
    void write(byte[] data) throws IOException;

    void synchronize() throws IOException;
}

final class NioAppSandboxCommitOperations implements AppSandboxCommitOperations {
    @Override
    public void replaceAtomically(File partialFile, File destinationFile) throws IOException {
        // A final ACK is a commitment that the old destination was replaced as
        // one filesystem operation. Never downgrade this to a copy/delete move.
        // 中文：最终 ACK 只认可原子替换，不允许静默退回非原子移动。
        Files.move(
                partialFile.toPath(),
                destinationFile.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE
        );
    }
}

final class AndroidMediaStoreEntryOperations implements MediaStoreEntryOperations {
    private final ContentResolver contentResolver;
    private final Uri mediaUri;

    AndroidMediaStoreEntryOperations(ContentResolver contentResolver, Uri mediaUri) {
        this.contentResolver = contentResolver;
        this.mediaUri = mediaUri;
    }

    @Override
    public boolean publish() {
        ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.IS_PENDING, 0);
        return contentResolver.update(mediaUri, values, null, null) == 1;
    }

    @Override
    public void delete() {
        contentResolver.delete(mediaUri, null, null);
    }
}

final class AndroidSafDocumentOperations implements SafDocumentOperations {
    private final ContentResolver contentResolver;
    private final Uri documentUri;

    AndroidSafDocumentOperations(ContentResolver contentResolver, Uri documentUri) {
        this.contentResolver = contentResolver;
        this.documentUri = documentUri;
    }

    @Override
    public boolean rename(String displayName) throws IOException {
        return DocumentsContract.renameDocument(
                contentResolver,
                documentUri,
                displayName
        ) != null;
    }

    @Override
    public void delete() throws IOException {
        DocumentsContract.deleteDocument(contentResolver, documentUri);
    }
}

final class AppSandboxUploadWriter implements DmFileProvider.UploadWriter {
    private static final AppSandboxCommitOperations PLATFORM_COMMIT_OPERATIONS =
            new NioAppSandboxCommitOperations();

    private final File destinationFile;
    private final File tempFile;
    private final AppSandboxPartialOutput partialOutput;
    private final long expectedSizeBytes;
    private final AppSandboxCommitOperations commitOperations;
    private long nextOffsetBytes;
    private boolean closed;

    AppSandboxUploadWriter(
            File destinationFile,
            File tempFile,
            AppSandboxPartialOutput partialOutput,
            long expectedSizeBytes,
            long nextOffsetBytes
    ) {
        this(
                destinationFile,
                tempFile,
                partialOutput,
                expectedSizeBytes,
                nextOffsetBytes,
                PLATFORM_COMMIT_OPERATIONS
        );
    }

    AppSandboxUploadWriter(
            File destinationFile,
            File tempFile,
            AppSandboxPartialOutput partialOutput,
            long expectedSizeBytes,
            long nextOffsetBytes,
            AppSandboxCommitOperations commitOperations
    ) {
        this.destinationFile = destinationFile;
        this.tempFile = tempFile;
        this.partialOutput = partialOutput;
        this.expectedSizeBytes = expectedSizeBytes;
        this.nextOffsetBytes = nextOffsetBytes;
        this.commitOperations = commitOperations;
    }

    @Override
    public long nextOffsetBytes() {
        return nextOffsetBytes;
    }

    @Override
    public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
            throws DmFileProvider.ProviderCatalogException {
        long nextOffset = ProviderUploadWriters.validatedNextOffset(
                closed,
                nextOffsetBytes,
                expectedSizeBytes,
                offsetBytes,
                data,
                finalChunk
        );

        try {
            partialOutput.write(data);
            nextOffsetBytes = nextOffset;
            if (finalChunk) {
                commit();
            }
        } catch (IOException | RuntimeException exception) {
            close();
            throw new DmFileProvider.ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "app sandbox upload write failed"
            );
        }
    }

    private void commit() throws IOException {
        // Force the exact no-follow channel before its path is atomically
        // published. A flush/close alone is not a durable final-ACK boundary.
        // 中文：必须先同步同一 channel，再关闭并原子发布。
        partialOutput.synchronize();
        partialOutput.close();
        commitOperations.replaceAtomically(tempFile, destinationFile);
        closed = true;
    }

    @Override
    public void close() {
        if (closed) {
            return;
        }
        closed = true;
        try {
            partialOutput.close();
        } catch (IOException ignored) {
        }
        // A later app-sandbox open may resume from this durable partial.
    }
}

final class SafUploadWriter implements DmFileProvider.UploadWriter {
    private final SafDocumentOperations documentOperations;
    private final OutputStream outputStream;
    private final long expectedSizeBytes;
    private final String finalDisplayName;
    private final boolean deleteOnNonFinalClose;
    private final ProviderLiveAuthorization commitAuthorization;
    private long nextOffsetBytes;
    private boolean closed;
    private boolean committed;

    SafUploadWriter(
            SafDocumentOperations documentOperations,
            OutputStream outputStream,
            long expectedSizeBytes,
            long initialOffsetBytes,
            String finalDisplayName,
            boolean deleteOnNonFinalClose,
            ProviderLiveAuthorization commitAuthorization
    ) {
        this.documentOperations = documentOperations;
        this.outputStream = outputStream;
        this.expectedSizeBytes = expectedSizeBytes;
        this.nextOffsetBytes = initialOffsetBytes;
        this.finalDisplayName = finalDisplayName;
        this.deleteOnNonFinalClose = deleteOnNonFinalClose;
        this.commitAuthorization = commitAuthorization;
    }

    @Override
    public long nextOffsetBytes() {
        return nextOffsetBytes;
    }

    @Override
    public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
            throws DmFileProvider.ProviderCatalogException {
        long nextOffset = ProviderUploadWriters.validatedNextOffset(
                closed,
                nextOffsetBytes,
                expectedSizeBytes,
                offsetBytes,
                data,
                finalChunk
        );

        try {
            outputStream.write(data);
            nextOffsetBytes = nextOffset;
            if (finalChunk) {
                commit();
            }
        } catch (DmFileProvider.ProviderCatalogException exception) {
            close();
            throw exception;
        } catch (SecurityException exception) {
            close();
            throw new DmFileProvider.ProviderCatalogException(
                    ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                    "SAF write permission is required to upload this document"
            );
        } catch (IOException | RuntimeException exception) {
            close();
            throw new DmFileProvider.ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "SAF upload write failed"
            );
        }
    }

    private void commit() throws IOException, DmFileProvider.ProviderCatalogException {
        // Final bytes may already be in a provider-owned partial. Revalidate
        // once more before flush/close/rename so a revoked grant can never
        // produce a successful final ACK. 中文：最终发布前再次检查实时授权。
        commitAuthorization.requireAuthorized();
        outputStream.flush();
        outputStream.close();
        if (finalDisplayName != null
                && !documentOperations.rename(finalDisplayName)) {
            throw new IOException("SAF upload document could not be renamed");
        }
        committed = true;
        closed = true;
    }

    @Override
    public void close() {
        if (closed) {
            return;
        }
        closed = true;
        closeQuietly(outputStream);
        if (!committed && deleteOnNonFinalClose) {
            deleteDocumentQuietly(documentOperations);
        }
    }

    private static void deleteDocumentQuietly(
            SafDocumentOperations documentOperations
    ) {
        try {
            documentOperations.delete();
        } catch (IOException | RuntimeException ignored) {
        }
    }

    private static void closeQuietly(Closeable closeable) {
        try {
            closeable.close();
        } catch (IOException | RuntimeException ignored) {
        }
    }
}

final class MediaStoreUploadWriter implements DmFileProvider.UploadWriter {
    private final MediaStoreEntryOperations entryOperations;
    private final OutputStream outputStream;
    private final long expectedSizeBytes;
    private final boolean publishOnCommit;
    private long nextOffsetBytes;
    private boolean closed;
    private boolean committed;

    MediaStoreUploadWriter(
            MediaStoreEntryOperations entryOperations,
            OutputStream outputStream,
            long expectedSizeBytes,
            boolean publishOnCommit
    ) {
        this.entryOperations = entryOperations;
        this.outputStream = outputStream;
        this.expectedSizeBytes = expectedSizeBytes;
        this.publishOnCommit = publishOnCommit;
    }

    @Override
    public long nextOffsetBytes() {
        return nextOffsetBytes;
    }

    @Override
    public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
            throws DmFileProvider.ProviderCatalogException {
        long nextOffset = ProviderUploadWriters.validatedNextOffset(
                closed,
                nextOffsetBytes,
                expectedSizeBytes,
                offsetBytes,
                data,
                finalChunk
        );

        try {
            outputStream.write(data);
            nextOffsetBytes = nextOffset;
            if (finalChunk) {
                commit();
            }
        } catch (SecurityException exception) {
            close();
            throw permission("MediaStore write permission is required to upload this item");
        } catch (IOException exception) {
            close();
            throw internal("MediaStore upload write failed");
        } catch (RuntimeException exception) {
            close();
            throw internal("MediaStore upload failed");
        }
    }

    private void commit() throws IOException {
        outputStream.flush();
        outputStream.close();
        // A zero-row update means the item disappeared or the provider rejected
        // publication. Never acknowledge a final chunk for an inaccessible
        // pending item. 中文：发布未命中目标时不得返回最终成功 ACK。
        if (publishOnCommit && !entryOperations.publish()) {
            throw new IOException("MediaStore upload item could not be published");
        }
        committed = true;
        closed = true;
    }

    @Override
    public void close() {
        if (closed) {
            return;
        }
        closed = true;
        closeQuietly(outputStream);
        if (!committed) {
            deleteEntryQuietly(entryOperations);
        }
    }

    private static DmFileProvider.ProviderCatalogException internal(String message) {
        return new DmFileProvider.ProviderCatalogException(
                ErrorCode.ERROR_CODE_INTERNAL,
                message
        );
    }

    private static DmFileProvider.ProviderCatalogException permission(String message) {
        return new DmFileProvider.ProviderCatalogException(
                ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                message
        );
    }

    private static void deleteEntryQuietly(MediaStoreEntryOperations entryOperations) {
        try {
            entryOperations.delete();
        } catch (RuntimeException ignored) {
        }
    }

    private static void closeQuietly(Closeable closeable) {
        try {
            closeable.close();
        } catch (IOException | RuntimeException ignored) {
        }
    }
}
