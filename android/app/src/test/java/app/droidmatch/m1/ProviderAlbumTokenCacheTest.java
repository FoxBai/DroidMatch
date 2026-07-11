package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import org.junit.Test;

public final class ProviderAlbumTokenCacheTest {
    @Test
    public void resolvesOpaqueTokenAndEvictsLeastRecentlyUsedBucket() {
        ProviderAlbumTokenCache cache = new ProviderAlbumTokenCache(2);
        cache.remember("camera");
        cache.remember("screenshots");

        assertEquals("camera", cache.bucketId(ProviderMediaAlbums.token("camera")));
        cache.remember("downloads");

        assertEquals("camera", cache.bucketId(ProviderMediaAlbums.token("camera")));
        assertNull(cache.bucketId(ProviderMediaAlbums.token("screenshots")));
        assertEquals("downloads", cache.bucketId(ProviderMediaAlbums.token("downloads")));
    }

    @Test
    public void ignoresMissingBucketIdentity() {
        ProviderAlbumTokenCache cache = new ProviderAlbumTokenCache(1);
        cache.remember(null);
        cache.remember("");
        assertNull(cache.bucketId(ProviderMediaAlbums.token("")));
    }
}
