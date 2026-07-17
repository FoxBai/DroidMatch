package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertTrue;

import android.provider.DocumentsContract;

import app.droidmatch.m1.DmFileProvider.SafItem;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.SortField;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import org.junit.Test;

public final class SafDocumentPolicyTest {
    @Test
    public void metadataFlagsClassifyKindAndCapabilitiesIndependently() {
        int directoryFlags = DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE;
        assertEquals(
                FileKind.FILE_KIND_DIRECTORY,
                SafDocumentPolicy.kind(DocumentsContract.Document.MIME_TYPE_DIR, directoryFlags)
        );
        assertTrue(SafDocumentPolicy.supportsCreate(FileKind.FILE_KIND_DIRECTORY, directoryFlags));
        assertTrue(SafDocumentPolicy.supportsWrite(FileKind.FILE_KIND_DIRECTORY, directoryFlags));
        assertFalse(SafDocumentPolicy.supportsCreate(FileKind.FILE_KIND_FILE, directoryFlags));

        int virtualFlags = DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT
                | DocumentsContract.Document.FLAG_SUPPORTS_DELETE;
        assertEquals(FileKind.FILE_KIND_VIRTUAL, SafDocumentPolicy.kind("image/jpeg", virtualFlags));
        assertTrue(SafDocumentPolicy.supportsWrite(FileKind.FILE_KIND_VIRTUAL, virtualFlags));
        assertEquals(FileKind.FILE_KIND_FILE, SafDocumentPolicy.kind("image/jpeg", 0));
        assertFalse(SafDocumentPolicy.supportsWrite(FileKind.FILE_KIND_FILE, 0));
    }

    @Test
    public void uploadPartialNameIsOpaqueStableAndTransferScoped() {
        String first = SafDocumentPolicy.uploadPartialDisplayName(
                "root", "parent", "photo.jpg", "one", 42
        );
        String repeated = SafDocumentPolicy.uploadPartialDisplayName(
                "root", "parent", "photo.jpg", "one", 42
        );
        String second = SafDocumentPolicy.uploadPartialDisplayName(
                "root", "parent", "photo.jpg", "two", 42
        );
        String otherSize = SafDocumentPolicy.uploadPartialDisplayName(
                "root", "parent", "photo.jpg", "one", 43
        );

        assertEquals(first, repeated);
        assertNotEquals(first, second);
        assertNotEquals(first, otherSize);
        assertTrue(first.matches("^\\.droidmatch-upload-[0-9a-f]{20}\\.part$"));
        assertFalse(first.contains("photo"));
    }

    @Test
    public void comparatorUsesStableNameAndDocumentIdTieBreakers() {
        List<SafItem> items = new ArrayList<>(Arrays.asList(
                item("b", "same", 4),
                item("c", "Zulu", 1),
                item("a", "Same", 4)
        ));

        items.sort(SafDocumentPolicy.comparator(SortField.SORT_FIELD_SIZE, false));
        assertEquals(Arrays.asList("c", "a", "b"), Arrays.asList(
                items.get(0).documentId,
                items.get(1).documentId,
                items.get(2).documentId
        ));
    }

    private static SafItem item(String id, String name, long size) {
        return new SafItem(id, name, FileKind.FILE_KIND_FILE, size, 0, "application/octet-stream", false);
    }
}
