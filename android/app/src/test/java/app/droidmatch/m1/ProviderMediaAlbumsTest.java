package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.SortField;

import org.junit.Test;

public final class ProviderMediaAlbumsTest {
    @Test
    public void aggregatesBucketsWithoutExposingBucketIdentity() {
        ProviderMediaAlbums albums = new ProviderMediaAlbums();
        albums.include("/storage/emulated/0/DCIM/Camera", "Camera", 1000);
        albums.include("/storage/emulated/0/DCIM/Camera", "Camera", 3000);

        ProviderAlbumPage page = albums.page(query(0, 10, SortField.SORT_FIELD_NAME, false, ""));

        assertEquals(1, page.items.size());
        ProviderAlbum album = page.items.get(0);
        assertEquals("Camera", album.displayName);
        assertEquals(2, album.itemCount);
        assertEquals(3000, album.modifiedUnixMillis);
        assertFalse(album.token.contains("storage"));
        assertEquals(24, album.token.length());
        assertNotEquals("/storage/emulated/0/DCIM/Camera", album.token);
    }

    @Test
    public void filtersSortsAndPagesAlbumsBeforeReturningRows() {
        ProviderMediaAlbums albums = new ProviderMediaAlbums();
        albums.include("1", "Screenshots", 1000);
        albums.include("2", "Camera", 3000);
        albums.include("3", "Chat Images", 2000);

        ProviderAlbumPage first = albums.page(query(
                0, 1, SortField.SORT_FIELD_MODIFIED_TIME, true, "a"
        ));
        ProviderAlbumPage second = albums.page(query(
                1, 1, SortField.SORT_FIELD_MODIFIED_TIME, true, "a"
        ));

        assertEquals("Camera", first.items.get(0).displayName);
        assertTrue(first.hasMore);
        assertEquals("Chat Images", second.items.get(0).displayName);
        assertFalse(second.hasMore);
    }

    @Test
    public void ignoresMissingBucketNamesAndKeepsTokensDeterministic() {
        ProviderMediaAlbums albums = new ProviderMediaAlbums();
        albums.include("1", "", 1000);
        albums.include(null, "Camera", 1000);
        albums.include("2", "Camera", 1000);

        ProviderAlbumPage page = albums.page(query(0, 10, SortField.SORT_FIELD_NAME, false, ""));

        assertEquals(1, page.items.size());
        assertEquals(ProviderMediaAlbums.token("2"), page.items.get(0).token);
        assertEquals(ProviderMediaAlbums.token("2"), ProviderMediaAlbums.token("2"));
    }

    private static DmFileProvider.ProviderQuery query(
            int offset,
            int limit,
            SortField field,
            boolean descending,
            String search
    ) {
        return new DmFileProvider.ProviderQuery(offset, limit, field, descending, search);
    }
}
