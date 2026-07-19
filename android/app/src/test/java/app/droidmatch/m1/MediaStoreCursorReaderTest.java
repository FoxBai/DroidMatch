package app.droidmatch.m1;

import static app.droidmatch.m1.CursorTestFixture.cursor;
import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import android.database.Cursor;
import android.provider.BaseColumns;
import android.provider.MediaStore;

import app.droidmatch.proto.v1.SortField;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import org.junit.Test;

public final class MediaStoreCursorReaderTest {
    private static final String[] MEDIA_PROJECTION = new String[] {
            BaseColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.MIME_TYPE
    };
    private static final String[] VIDEO_PROJECTION = new String[] {
            BaseColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.Video.VideoColumns.DURATION
    };
    private static final String[] ALBUM_PROJECTION = new String[] {
            MediaStore.Images.ImageColumns.BUCKET_ID,
            MediaStore.Images.ImageColumns.BUCKET_DISPLAY_NAME,
            MediaStore.MediaColumns.DATE_MODIFIED
    };

    @Test
    public void projectionsAreExactAndDefensive() {
        String[] mediaProjection = MediaStoreCursorReader.mediaProjection();
        assertArrayEquals(MEDIA_PROJECTION, mediaProjection);
        assertArrayEquals(VIDEO_PROJECTION, MediaStoreCursorReader.videoProjection());
        assertArrayEquals(
                MEDIA_PROJECTION,
                MediaStoreCursorReader.listingProjection(DmFileProvider.RootKind.MEDIA_IMAGES)
        );
        assertArrayEquals(
                VIDEO_PROJECTION,
                MediaStoreCursorReader.listingProjection(DmFileProvider.RootKind.MEDIA_VIDEOS)
        );
        assertArrayEquals(ALBUM_PROJECTION, MediaStoreCursorReader.albumProjection());
        assertArrayEquals(
                new String[] { MediaStore.Images.ImageColumns.BUCKET_ID },
                MediaStoreCursorReader.bucketIdProjection()
        );
        assertArrayEquals(
                new String[] { BaseColumns._ID },
                MediaStoreCursorReader.mediaIdProjection()
        );

        mediaProjection[0] = "mutated";
        assertArrayEquals(MEDIA_PROJECTION, MediaStoreCursorReader.mediaProjection());
    }

    @Test
    public void mediaPagePreservesFallbacksUnitsAndOneExtraRowPagination() {
        Cursor cursor = cursor(MEDIA_PROJECTION, new Object[][] {
                mediaRow(7L, null, null, null, null),
                mediaRow(8L, "Photo.JPG", 42L, 3L, "image/jpeg"),
                mediaRow(9L, "extra.jpg", 99L, 4L, "image/jpeg")
        });

        DmFileProvider.MediaPage page = MediaStoreCursorReader.readPage(cursor, 2);

        assertEquals(2, page.items.size());
        assertTrue(page.hasMore);
        DmFileProvider.MediaItem fallback = page.items.get(0);
        assertEquals(7L, fallback.id);
        assertEquals("7", fallback.displayName);
        assertEquals(0L, fallback.sizeBytes);
        assertEquals(0L, fallback.modifiedUnixMillis);
        assertEquals("", fallback.mimeType);
        assertEquals(0L, fallback.durationMillis);
        DmFileProvider.MediaItem photo = page.items.get(1);
        assertEquals(42L, photo.sizeBytes);
        assertEquals(3_000L, photo.modifiedUnixMillis);
        assertEquals("image/jpeg", photo.mimeType);
        assertEquals(0L, photo.durationMillis);

        DmFileProvider.MediaPage complete = MediaStoreCursorReader.readPage(
                cursor(MEDIA_PROJECTION, new Object[][] { mediaRow(1L, "one", 1L, 1L, "") }),
                2
        );
        assertFalse(complete.hasMore);
    }

    @Test
    public void videoPagePreservesPositiveDurationAndNormalizesUnknownValues() {
        Cursor cursor = cursor(VIDEO_PROJECTION, new Object[][] {
                videoRow(10L, "clip.mp4", 123_456L),
                videoRow(11L, "unknown.mp4", null),
                videoRow(12L, "invalid.mp4", -1L)
        });

        DmFileProvider.MediaPage page = MediaStoreCursorReader.readPage(cursor, 3);

        assertFalse(page.hasMore);
        assertEquals(123_456L, page.items.get(0).durationMillis);
        assertEquals(0L, page.items.get(1).durationMillis);
        assertEquals(0L, page.items.get(2).durationMillis);
    }

    @Test
    public void albumRowsPreserveFilteringAggregationUnitsAndCacheTiming() {
        ProviderMediaAlbums albums = new ProviderMediaAlbums();
        List<String> observed = new ArrayList<>();
        MediaStoreCursorReader.readAlbums(
                cursor(ALBUM_PROJECTION, new Object[][] {
                        albumRow(null, "Ignored", 1L),
                        albumRow("empty-name", null, 2L),
                        albumRow("camera", "Camera", 3L),
                        albumRow("camera", "Camera", 5L),
                        albumRow("screens", "Screenshots", null)
                }),
                albums,
                observed::add
        );

        assertEquals(Arrays.asList("camera", "camera", "screens"), observed);
        ProviderAlbumPage page = albums.page(new DmFileProvider.ProviderQuery(
                0,
                10,
                SortField.SORT_FIELD_NAME,
                false,
                ""
        ));
        assertEquals(2, page.items.size());
        assertEquals("Camera", page.items.get(0).displayName);
        assertEquals(2L, page.items.get(0).itemCount);
        assertEquals(5_000L, page.items.get(0).modifiedUnixMillis);
        assertEquals(0L, page.items.get(1).modifiedUnixMillis);
    }

    @Test
    public void bucketLookupObservesEachVisibleIdAndMatchesExactToken() {
        String[] projection = MediaStoreCursorReader.bucketIdProjection();
        Object[][] rows = new Object[][] {
                new Object[] { null },
                new Object[] { "" },
                new Object[] { "camera" },
                new Object[] { "screens" }
        };
        List<String> observed = new ArrayList<>();

        String bucketId = MediaStoreCursorReader.findBucketId(
                cursor(projection, rows),
                ProviderMediaAlbums.token("screens"),
                observed::add
        );

        assertEquals("screens", bucketId);
        assertEquals(Arrays.asList("", "camera", "screens"), observed);
        assertNull(MediaStoreCursorReader.findBucketId(
                cursor(projection, rows),
                ProviderMediaAlbums.token("missing"),
                ignored -> { }
        ));
    }

    @Test
    public void firstIdAndMetadataPreserveEmptyAndUnknownDefaults() {
        assertEquals(Long.valueOf(17L), MediaStoreCursorReader.firstMediaId(cursor(
                MediaStoreCursorReader.mediaIdProjection(),
                new Object[][] { new Object[] { 17L } }
        )));
        assertNull(MediaStoreCursorReader.firstMediaId(cursor(
                MediaStoreCursorReader.mediaIdProjection(),
                new Object[0][]
        )));

        MediaStoreCursorReader.Metadata metadata = MediaStoreCursorReader.firstMetadata(cursor(
                MEDIA_PROJECTION,
                new Object[][] { mediaRow(1L, "one", null, 9L, "image/jpeg") }
        ));
        assertNotNull(metadata);
        assertEquals(-1L, metadata.sizeBytes);
        assertEquals(9_000L, metadata.modifiedUnixMillis);
        assertNull(MediaStoreCursorReader.firstMetadata(cursor(MEDIA_PROJECTION, new Object[0][])));
    }

    private static Object[] mediaRow(
            long id,
            String displayName,
            Long sizeBytes,
            Long modifiedSeconds,
            String mimeType
    ) {
        return new Object[] { id, displayName, sizeBytes, modifiedSeconds, mimeType };
    }

    private static Object[] videoRow(long id, String displayName, Long durationMillis) {
        return new Object[] {
                id, displayName, 1_024L, 1_700_000_000L, "video/mp4", durationMillis
        };
    }

    private static Object[] albumRow(String id, String displayName, Long modifiedSeconds) {
        return new Object[] { id, displayName, modifiedSeconds };
    }
}
