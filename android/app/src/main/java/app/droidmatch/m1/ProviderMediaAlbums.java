package app.droidmatch.m1;

import app.droidmatch.proto.v1.SortField;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.Locale;

/** Pure album aggregation and paging policy over MediaStore bucket rows. */
final class ProviderMediaAlbums {
    private final LinkedHashMap<String, AlbumAccumulator> albums = new LinkedHashMap<>();

    void include(String bucketId, String displayName, long modifiedUnixMillis) {
        if (bucketId == null || bucketId.isEmpty() || displayName == null
                || displayName.trim().isEmpty()) return;
        AlbumAccumulator album = albums.get(bucketId);
        if (album == null) {
            albums.put(bucketId, new AlbumAccumulator(bucketId, displayName, modifiedUnixMillis));
        } else {
            album.include(displayName, modifiedUnixMillis);
        }
    }

    ProviderAlbumPage page(DmFileProvider.ProviderQuery query) {
        ArrayList<ProviderAlbum> filtered = new ArrayList<>();
        for (AlbumAccumulator value : albums.values()) {
            if (ProviderNameSearch.matches(value.displayName, query.searchQuery())) {
                filtered.add(value.album());
            }
        }
        sort(filtered, query.sortField(), query.descending());
        int from = Math.min(query.offset(), filtered.size());
        int to = Math.min(from + query.limit(), filtered.size());
        return new ProviderAlbumPage(
                new ArrayList<>(filtered.subList(from, to)),
                to < filtered.size()
        );
    }

    static String token(String bucketId) {
        return ProviderOpaqueIds.stable("media-album\n" + bucketId, 12);
    }

    private static void sort(
            ArrayList<ProviderAlbum> values,
            SortField field,
            boolean descending
    ) {
        Comparator<ProviderAlbum> comparator;
        switch (field) {
            case SORT_FIELD_SIZE:
                comparator = Comparator.comparingLong(value -> value.itemCount);
                break;
            case SORT_FIELD_MODIFIED_TIME:
                comparator = Comparator.comparingLong(value -> value.modifiedUnixMillis);
                break;
            case SORT_FIELD_NAME:
            case SORT_FIELD_KIND:
            case SORT_FIELD_UNSPECIFIED:
            case UNRECOGNIZED:
            default:
                comparator = Comparator.comparing(
                        value -> value.displayName.toLowerCase(Locale.ROOT)
                );
                break;
        }
        comparator = comparator.thenComparing(value -> value.token);
        if (descending) comparator = comparator.reversed();
        Collections.sort(values, comparator);
    }

    private static final class AlbumAccumulator {
        private final String bucketId;
        private String displayName;
        private long modifiedUnixMillis;
        private long itemCount = 1;

        private AlbumAccumulator(String bucketId, String displayName, long modifiedUnixMillis) {
            this.bucketId = bucketId;
            this.displayName = displayName;
            this.modifiedUnixMillis = modifiedUnixMillis;
        }

        private void include(String candidateName, long candidateModifiedUnixMillis) {
            itemCount += 1;
            modifiedUnixMillis = Math.max(modifiedUnixMillis, candidateModifiedUnixMillis);
            if (displayName.isEmpty() && !candidateName.isEmpty()) displayName = candidateName;
        }

        private ProviderAlbum album() {
            return new ProviderAlbum(token(bucketId), displayName, modifiedUnixMillis, itemCount);
        }
    }
}
