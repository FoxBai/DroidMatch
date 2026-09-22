package app.droidmatch.m1;

import android.provider.MediaStore;
import java.util.ArrayList;

/** Provider-owned search across Audio labels; all user values remain bound.
 * 中文：音频按文件名及标签搜索，通配符先转义，用户内容只作为绑定参数。 */
final class MediaStoreSearch {
    static String append(
            DmFileProvider.RootKind kind, String query, String existing,
            ArrayList<String> arguments
    ) {
        if (query.isEmpty()) return existing;
        String[] columns = kind == DmFileProvider.RootKind.MEDIA_AUDIO
                ? new String[] {MediaStore.MediaColumns.DISPLAY_NAME,
                    MediaStore.Audio.AudioColumns.TITLE, MediaStore.Audio.AudioColumns.ARTIST,
                    MediaStore.Audio.AudioColumns.ALBUM}
                : new String[] {MediaStore.MediaColumns.DISPLAY_NAME};
        String pattern = "%" + ProviderNameSearch.escapeSqlLike(query) + "%";
        ArrayList<String> predicates = new ArrayList<>();
        for (String column : columns) {
            predicates.add(column + " LIKE ? ESCAPE '\\'");
            arguments.add(pattern);
        }
        String clause = "(" + String.join(" OR ", predicates) + ")";
        return existing == null ? clause : existing + " AND " + clause;
    }
}
