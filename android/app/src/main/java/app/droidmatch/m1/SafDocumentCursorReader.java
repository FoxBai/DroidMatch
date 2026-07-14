package app.droidmatch.m1;

import android.database.Cursor;
import android.provider.DocumentsContract;

import app.droidmatch.m1.DmFileProvider.SafItem;
import app.droidmatch.proto.v1.FileKind;

/**
 * Stateless decoding of already-open SAF document cursors.
 *
 * <p>The caller retains resolver, URI, permission, cursor lifetime, and error
 * mapping ownership. This boundary only converts platform columns into typed
 * provider values, so its null/default and capability rules are JVM-testable.</p>
 *
 * <p>中文：调用方继续持有 resolver、URI、权限、cursor 生命周期与错误映射；
 * 本边界只把平台列转换为 typed provider 值，使 null/default 与 capability
 * 规则可以直接通过 JVM 测试。</p>
 */
final class SafDocumentCursorReader {
    private SafDocumentCursorReader() {}

    static String[] projection() {
        return new String[] {
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                DocumentsContract.Document.COLUMN_FLAGS
        };
    }

    static void readItems(
            Cursor cursor,
            boolean rootCanWrite,
            String searchQuery,
            ProviderBoundedPageSelector<SafItem> selector
    ) {
        int idColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID);
        int nameColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME);
        int mimeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE);
        int sizeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE);
        int modifiedColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED);
        int flagsColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_FLAGS);
        while (cursor.moveToNext()) {
            String documentId = cursor.getString(idColumn);
            String displayName = cursor.isNull(nameColumn) ? documentId : cursor.getString(nameColumn);
            String mimeType = cursor.isNull(mimeColumn) ? "" : cursor.getString(mimeColumn);
            int flags = cursor.isNull(flagsColumn) ? 0 : cursor.getInt(flagsColumn);
            FileKind kind = SafDocumentPolicy.kind(mimeType, flags);
            long sizeBytes = kind == FileKind.FILE_KIND_DIRECTORY || cursor.isNull(sizeColumn)
                    ? 0
                    : cursor.getLong(sizeColumn);
            long modifiedMillis = cursor.isNull(modifiedColumn) ? 0 : cursor.getLong(modifiedColumn);
            boolean canWrite = rootCanWrite && SafDocumentPolicy.supportsWrite(kind, flags);
            if (!ProviderNameSearch.matches(displayName, searchQuery)) {
                continue;
            }
            selector.accept(new SafItem(
                    documentId,
                    displayName,
                    kind,
                    sizeBytes,
                    modifiedMillis,
                    mimeType,
                    canWrite
            ));
        }
    }

    static Metadata firstMetadata(Cursor cursor) {
        if (!cursor.moveToFirst()) {
            return null;
        }
        int mimeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE);
        int sizeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE);
        int modifiedColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_LAST_MODIFIED);
        int flagsColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_FLAGS);
        String mimeType = cursor.isNull(mimeColumn) ? "" : cursor.getString(mimeColumn);
        int flags = cursor.isNull(flagsColumn) ? 0 : cursor.getInt(flagsColumn);
        FileKind kind = SafDocumentPolicy.kind(mimeType, flags);
        long sizeBytes = kind == FileKind.FILE_KIND_DIRECTORY || cursor.isNull(sizeColumn)
                ? -1
                : cursor.getLong(sizeColumn);
        long modifiedMillis = cursor.isNull(modifiedColumn) ? 0 : cursor.getLong(modifiedColumn);
        return new Metadata(
                kind,
                sizeBytes,
                modifiedMillis,
                SafDocumentPolicy.supportsCreate(kind, flags)
        );
    }

    static ChildDocument childByDisplayName(Cursor cursor, String displayName) {
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
            FileKind kind = SafDocumentPolicy.kind(mimeType, flags);
            long sizeBytes = kind == FileKind.FILE_KIND_DIRECTORY || cursor.isNull(sizeColumn)
                    ? -1
                    : cursor.getLong(sizeColumn);
            return new ChildDocument(cursor.getString(idColumn), kind, sizeBytes);
        }
        return null;
    }

    static String firstDisplayName(Cursor cursor, String fallback) {
        if (cursor.moveToFirst() && !cursor.isNull(0)) {
            return cursor.getString(0);
        }
        return fallback;
    }

    static final class Metadata {
        final FileKind kind;
        final long sizeBytes;
        final long modifiedUnixMillis;
        final boolean canCreate;

        private Metadata(
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

    static final class ChildDocument {
        final String documentId;
        final FileKind kind;
        final long sizeBytes;

        private ChildDocument(String documentId, FileKind kind, long sizeBytes) {
            this.documentId = documentId;
            this.kind = kind;
            this.sizeBytes = sizeBytes;
        }
    }
}
