package app.droidmatch.m1;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/** Bounded in-memory resolution cache; neither side persists MediaStore bucket IDs. */
final class ProviderAlbumTokenCache {
    private final Map<String, String> bucketIdsByToken;

    ProviderAlbumTokenCache(int maximumEntries) {
        final int boundedMaximum = Math.max(1, maximumEntries);
        bucketIdsByToken = Collections.synchronizedMap(
                new LinkedHashMap<String, String>(boundedMaximum, 0.75f, true) {
                    @Override
                    protected boolean removeEldestEntry(Map.Entry<String, String> eldest) {
                        return size() > boundedMaximum;
                    }
                }
        );
    }

    void remember(String bucketId) {
        if (bucketId == null || bucketId.isEmpty()) return;
        bucketIdsByToken.put(ProviderMediaAlbums.token(bucketId), bucketId);
    }

    String bucketId(String token) {
        return bucketIdsByToken.get(token);
    }
}
