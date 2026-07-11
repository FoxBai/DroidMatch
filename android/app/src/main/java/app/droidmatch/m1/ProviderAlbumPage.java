package app.droidmatch.m1;

import java.util.List;

final class ProviderAlbumPage {
    final List<ProviderAlbum> items;
    final boolean hasMore;

    ProviderAlbumPage(List<ProviderAlbum> items, boolean hasMore) {
        this.items = items;
        this.hasMore = hasMore;
    }
}
