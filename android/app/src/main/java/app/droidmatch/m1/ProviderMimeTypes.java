package app.droidmatch.m1;

import java.net.URLConnection;

/** MIME inference shared by provider upload catalogs. */
final class ProviderMimeTypes {
    private ProviderMimeTypes() {
    }

    static String fromDisplayName(String displayName) {
        String guessed = URLConnection.guessContentTypeFromName(displayName);
        return guessed == null || guessed.isEmpty() ? "application/octet-stream" : guessed;
    }
}
