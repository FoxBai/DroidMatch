package app.droidmatch.m1;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import android.database.Cursor;
import android.provider.DocumentsContract;

import app.droidmatch.m1.DmFileProvider.SafItem;
import app.droidmatch.proto.v1.FileKind;

import java.lang.reflect.Proxy;
import java.util.Comparator;
import java.util.List;

import org.junit.Test;

public final class SafDocumentCursorReaderTest {
    private static final String[] PROJECTION = new String[] {
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_FLAGS
    };

    @Test
    public void projectionAndMetadataPreserveProviderDefaults() {
        assertArrayEquals(PROJECTION, SafDocumentCursorReader.projection());
        Cursor cursor = cursor(PROJECTION, new Object[][] {
                row(
                        "directory-id",
                        "Directory",
                        DocumentsContract.Document.MIME_TYPE_DIR,
                        99L,
                        null,
                        DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
                )
        });

        SafDocumentCursorReader.Metadata metadata = SafDocumentCursorReader.firstMetadata(cursor);

        assertNotNull(metadata);
        assertEquals(FileKind.FILE_KIND_DIRECTORY, metadata.kind);
        assertEquals(-1L, metadata.sizeBytes);
        assertEquals(0L, metadata.modifiedUnixMillis);
        assertTrue(metadata.canCreate);
        assertNull(SafDocumentCursorReader.firstMetadata(cursor(PROJECTION, new Object[0][])));
    }

    @Test
    public void itemRowsPreserveFallbacksSearchAndRootWriteGate() {
        Object[][] rows = new Object[][] {
                row(
                        "directory-id",
                        null,
                        DocumentsContract.Document.MIME_TYPE_DIR,
                        99L,
                        null,
                        DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
                ),
                row(
                        "photo-id",
                        "Photo.JPG",
                        "image/jpeg",
                        42L,
                        7L,
                        DocumentsContract.Document.FLAG_SUPPORTS_WRITE
                ),
                row("plain-id", "notes.txt", "text/plain", null, null, null)
        };
        ProviderBoundedPageSelector<SafItem> selector = selector();
        SafDocumentCursorReader.readItems(cursor(PROJECTION, rows), true, "", selector);
        List<SafItem> items = selector.page().items;

        assertEquals(3, items.size());
        SafItem directory = item(items, "directory-id");
        assertEquals("directory-id", directory.displayName);
        assertEquals(FileKind.FILE_KIND_DIRECTORY, directory.kind);
        assertEquals(0L, directory.sizeBytes);
        assertEquals(0L, directory.modifiedUnixMillis);
        assertTrue(directory.canWrite);

        SafItem photo = item(items, "photo-id");
        assertEquals(42L, photo.sizeBytes);
        assertEquals(7L, photo.modifiedUnixMillis);
        assertTrue(photo.canWrite);

        ProviderBoundedPageSelector<SafItem> readOnlySelector = selector();
        SafDocumentCursorReader.readItems(
                cursor(PROJECTION, new Object[][] { rows[1] }),
                false,
                "photo",
                readOnlySelector
        );
        List<SafItem> readOnlyItems = readOnlySelector.page().items;
        assertEquals(1, readOnlyItems.size());
        assertEquals("photo-id", readOnlyItems.get(0).documentId);
        assertFalse(readOnlyItems.get(0).canWrite);
    }

    @Test
    public void childLookupMatchesExactNameAndPreservesUnknownDirectorySize() {
        Object[][] rows = new Object[][] {
                row("other-id", null, "text/plain", 1L, 1L, 0),
                row("partial-id", "partial.part", "application/octet-stream", 128L, 2L, 0),
                row("folder-id", "Folder", DocumentsContract.Document.MIME_TYPE_DIR, 999L, 3L, 0)
        };

        SafDocumentCursorReader.ChildDocument partial = SafDocumentCursorReader.childByDisplayName(
                cursor(PROJECTION, rows),
                "partial.part"
        );
        assertNotNull(partial);
        assertEquals("partial-id", partial.documentId);
        assertEquals(FileKind.FILE_KIND_FILE, partial.kind);
        assertEquals(128L, partial.sizeBytes);

        SafDocumentCursorReader.ChildDocument folder = SafDocumentCursorReader.childByDisplayName(
                cursor(PROJECTION, rows),
                "Folder"
        );
        assertNotNull(folder);
        assertEquals(FileKind.FILE_KIND_DIRECTORY, folder.kind);
        assertEquals(-1L, folder.sizeBytes);
        assertNull(SafDocumentCursorReader.childByDisplayName(
                cursor(PROJECTION, rows),
                "folder"
        ));
    }

    @Test
    public void displayNameUsesFirstNonNullValueOrFallback() {
        String[] projection = new String[] { DocumentsContract.Document.COLUMN_DISPLAY_NAME };
        assertEquals("Camera", SafDocumentCursorReader.firstDisplayName(
                cursor(projection, new Object[][] { new Object[] { "Camera" } }),
                "Fallback"
        ));
        assertEquals("Fallback", SafDocumentCursorReader.firstDisplayName(
                cursor(projection, new Object[][] { new Object[] { null } }),
                "Fallback"
        ));
        assertEquals("Fallback", SafDocumentCursorReader.firstDisplayName(
                cursor(projection, new Object[0][]),
                "Fallback"
        ));
    }

    private static ProviderBoundedPageSelector<SafItem> selector() {
        return new ProviderBoundedPageSelector<>(
                Comparator.comparing(item -> item.documentId),
                0,
                20
        );
    }

    private static SafItem item(List<SafItem> items, String documentId) {
        return items.stream()
                .filter(item -> documentId.equals(item.documentId))
                .findFirst()
                .orElseThrow(AssertionError::new);
    }

    private static Object[] row(
            String documentId,
            String displayName,
            String mimeType,
            Long sizeBytes,
            Long modifiedUnixMillis,
            Integer flags
    ) {
        return new Object[] {
                documentId,
                displayName,
                mimeType,
                sizeBytes,
                modifiedUnixMillis,
                flags
        };
    }

    private static Cursor cursor(String[] columns, Object[][] rows) {
        int[] position = new int[] { -1 };
        return (Cursor) Proxy.newProxyInstance(
                Cursor.class.getClassLoader(),
                new Class<?>[] { Cursor.class },
                (proxy, method, arguments) -> {
                    String name = method.getName();
                    if ("getColumnIndexOrThrow".equals(name) || "getColumnIndex".equals(name)) {
                        String column = (String) arguments[0];
                        for (int index = 0; index < columns.length; index++) {
                            if (columns[index].equals(column)) {
                                return index;
                            }
                        }
                        if ("getColumnIndex".equals(name)) {
                            return -1;
                        }
                        throw new IllegalArgumentException("missing column");
                    }
                    if ("moveToNext".equals(name)) {
                        if (position[0] + 1 < rows.length) {
                            position[0]++;
                            return true;
                        }
                        position[0] = rows.length;
                        return false;
                    }
                    if ("moveToFirst".equals(name)) {
                        position[0] = rows.length == 0 ? -1 : 0;
                        return rows.length != 0;
                    }
                    if ("isNull".equals(name)) {
                        return value(rows, position[0], (Integer) arguments[0]) == null;
                    }
                    if ("getString".equals(name)) {
                        Object value = value(rows, position[0], (Integer) arguments[0]);
                        return value == null ? null : value.toString();
                    }
                    if ("getInt".equals(name)) {
                        return ((Number) value(rows, position[0], (Integer) arguments[0])).intValue();
                    }
                    if ("getLong".equals(name)) {
                        return ((Number) value(rows, position[0], (Integer) arguments[0])).longValue();
                    }
                    if ("getCount".equals(name)) {
                        return rows.length;
                    }
                    if ("getPosition".equals(name)) {
                        return position[0];
                    }
                    if ("getColumnNames".equals(name)) {
                        return columns.clone();
                    }
                    if ("close".equals(name)) {
                        return null;
                    }
                    Class<?> type = method.getReturnType();
                    if (type == boolean.class) {
                        return false;
                    }
                    if (type == int.class) {
                        return 0;
                    }
                    if (type == long.class) {
                        return 0L;
                    }
                    if (type == float.class) {
                        return 0F;
                    }
                    if (type == double.class) {
                        return 0D;
                    }
                    return null;
                }
        );
    }

    private static Object value(Object[][] rows, int row, int column) {
        if (row < 0 || row >= rows.length) {
            throw new IllegalStateException("cursor is not positioned on a row");
        }
        return rows[row][column];
    }
}
