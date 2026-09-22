package app.droidmatch.m1;

/** Bounded display labels only; the filename and media ID remain operational.
 * 中文：标签只用于展示，不参与文件命名、权限判断或 provider 身份。 */
final class ProviderAudioMetadata {
    final String title;
    final String artist;
    final String album;

    ProviderAudioMetadata(String title, String artist, String album) {
        this.title = label(title);
        this.artist = label(artist);
        this.album = label(album);
    }

    boolean isEmpty() { return title.isEmpty() && artist.isEmpty() && album.isEmpty(); }

    private static String label(String raw) {
        // Bound work before NFC normalization; the shared projection emits at
        // most 120 code points (480 UTF-8 bytes), within the 512-byte wire cap.
        if (raw == null || raw.length() > 2048) return "";
        String visible = ProductDisplayName.name(raw, "");
        return "<unknown>".equalsIgnoreCase(visible) ? "" : visible;
    }
}
