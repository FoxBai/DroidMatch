package app.droidmatch.m1;

import java.util.Locale;

/** Locale-stable, case-insensitive matching shared by non-MediaStore catalogs. */
final class ProviderNameSearch {
    private ProviderNameSearch() {
    }

    static boolean matches(String displayName, String query) {
        if (query == null || query.isEmpty()) return true;
        String safeName = displayName == null ? "" : displayName;
        return safeName.toLowerCase(Locale.ROOT).contains(query.toLowerCase(Locale.ROOT));
    }

    static String escapeSqlLike(String query) {
        return query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_");
    }
}
