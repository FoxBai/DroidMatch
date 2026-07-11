package app.droidmatch.m1;

import android.provider.DocumentsContract;

import app.droidmatch.m1.DmFileProvider.SafItem;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.SortField;

import java.util.Comparator;

/** Pure interpretation of SAF metadata; owns no URI, cursor, or resolver state. */
final class SafDocumentPolicy {
    private SafDocumentPolicy() {}

    static FileKind kind(String mimeType, int flags) {
        if (DocumentsContract.Document.MIME_TYPE_DIR.equals(mimeType)) {
            return FileKind.FILE_KIND_DIRECTORY;
        }
        return (flags & DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT) != 0
                ? FileKind.FILE_KIND_VIRTUAL
                : FileKind.FILE_KIND_FILE;
    }

    static boolean supportsCreate(FileKind kind, int flags) {
        return kind == FileKind.FILE_KIND_DIRECTORY
                && (flags & DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE) != 0;
    }

    static boolean supportsWrite(FileKind kind, int flags) {
        if (kind == FileKind.FILE_KIND_DIRECTORY) {
            return supportsCreate(kind, flags);
        }
        return (flags & (DocumentsContract.Document.FLAG_SUPPORTS_WRITE
                | DocumentsContract.Document.FLAG_SUPPORTS_DELETE)) != 0;
    }

    static String uploadPartialDisplayName(
            String rootStableId,
            String parentDocumentId,
            String displayName,
            String transferId
    ) {
        return ".droidmatch-upload-"
                + ProviderOpaqueIds.stable(
                        rootStableId + "\n" + parentDocumentId + "\n" + displayName + "\n" + transferId,
                        10
                )
                + ".part";
    }

    static Comparator<SafItem> comparator(SortField sortField, boolean descending) {
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
}
