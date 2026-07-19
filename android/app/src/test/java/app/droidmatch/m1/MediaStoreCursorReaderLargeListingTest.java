package app.droidmatch.m1;

import static app.droidmatch.m1.CursorTestFixture.cursor;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import android.database.Cursor;
import android.provider.BaseColumns;
import android.provider.MediaStore;

import java.util.concurrent.TimeUnit;

import org.junit.Test;

/** Host-JVM stress evidence for the maximum MediaStore page plus lookahead row. */
public final class MediaStoreCursorReaderLargeListingTest {
    private static final int PAGE_SIZE = 1_000;
    private static final long MAXIMUM_DECODE_NANOS = TimeUnit.SECONDS.toNanos(2);

    @Test
    public void maximumPagePreservesOneThousandRowsAndOneExtraRowBoundary() {
        String[] projection = MediaStoreCursorReader.mediaProjection();
        Object[][] rows = new Object[PAGE_SIZE + 1][];
        for (int index = 0; index < rows.length; index++) {
            rows[index] = mediaRow(index);
        }
        Cursor source = cursor(projection, rows);

        long started = System.nanoTime();
        DmFileProvider.MediaPage firstPage = MediaStoreCursorReader.readPage(
                source,
                PAGE_SIZE
        );
        long elapsed = System.nanoTime() - started;

        assertEquals(PAGE_SIZE, firstPage.items.size());
        assertTrue(firstPage.hasMore);
        for (int index = 0; index < PAGE_SIZE; index++) {
            assertEquals(index, firstPage.items.get(index).id);
            assertEquals(String.format("photo-%04d.jpg", index),
                    firstPage.items.get(index).displayName);
        }
        assertEquals(PAGE_SIZE, source.getPosition());
        assertTrue("maximum MediaStore page decode exceeded two seconds", elapsed < MAXIMUM_DECODE_NANOS);

        DmFileProvider.MediaPage finalPage = MediaStoreCursorReader.readPage(
                cursor(projection, new Object[][] { mediaRow(PAGE_SIZE) }),
                PAGE_SIZE
        );
        assertEquals(1, finalPage.items.size());
        assertEquals(PAGE_SIZE, finalPage.items.get(0).id);
        assertFalse(finalPage.hasMore);
    }

    private static Object[] mediaRow(int index) {
        return new Object[] {
                (long) index,
                String.format("photo-%04d.jpg", index),
                1_024L + index,
                1_700_000_000L + index,
                "image/jpeg"
        };
    }
}
