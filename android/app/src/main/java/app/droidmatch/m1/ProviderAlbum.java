package app.droidmatch.m1;

/** Privacy-safe MediaStore album metadata exposed through a logical token. */
final class ProviderAlbum {
    final String token;
    final String displayName;
    final long modifiedUnixMillis;
    final long itemCount;

    ProviderAlbum(String token, String displayName, long modifiedUnixMillis, long itemCount) {
        this.token = token;
        this.displayName = displayName;
        this.modifiedUnixMillis = modifiedUnixMillis;
        this.itemCount = itemCount;
    }
}
