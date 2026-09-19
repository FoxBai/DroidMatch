package app.droidmatch.m1;

import android.content.Context;
import android.content.SharedPreferences;

import java.io.IOException;
import java.io.File;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** One atomic private preference value; this stores operation state, never consent. */
final class AndroidApkInstallJournal implements ApkInstallJournal {
    private static final String NAME = "droidmatch_apk_installs_v1";
    private static final String KEY = "journal";
    private final SharedPreferences preferences;
    private final File backingFile;
    private final File backupFile;

    AndroidApkInstallJournal(Context context) {
        Context application = context.getApplicationContext();
        preferences = application.getSharedPreferences(NAME, Context.MODE_PRIVATE);
        File directory = new File(application.getDataDir(), "shared_prefs");
        backingFile = new File(directory, NAME + ".xml");
        backupFile = new File(directory, NAME + ".xml.bak");
    }

    AndroidApkInstallJournal(SharedPreferences preferences, File backingFile, File backupFile) {
        this.preferences = preferences; this.backingFile = backingFile; this.backupFile = backupFile;
    }

    @Override public List<ApkInstallRecord> load() throws IOException {
        try {
            Map<String, ?> values = preferences.getAll();
            if (values.isEmpty()) {
                // Android can return an empty map after an XML read failure.
                // Only proven absence represents a fresh journal.
                // 中文：XML 读取失败也可能返回空集合；仅文件确实不存在时视为首次使用。
                if (!Files.notExists(backingFile.toPath(), LinkOption.NOFOLLOW_LINKS)
                        || !Files.notExists(backupFile.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                    throw unavailable();
                }
                return new ArrayList<>();
            }
            if (values.size() != 1 || !(values.get(KEY) instanceof String)) throw unavailable();
            return ApkInstallJournalCodec.decode((String) values.get(KEY));
        } catch (RuntimeException failure) {
            throw unavailable();
        }
    }

    @Override public void save(List<ApkInstallRecord> records) throws IOException {
        String encoded = ApkInstallJournalCodec.encode(records);
        try {
            // apply() cannot prove persistence before PackageInstaller.commit().
            // 中文：必须同步确认持久化成功，才能提交系统安装；不能使用 apply()。
            if (!preferences.edit().putString(KEY, encoded).commit()) throw unavailable();
        } catch (RuntimeException failure) {
            throw unavailable();
        }
    }

    private static IOException unavailable() {
        return new IOException("installation journal is unavailable");
    }
}
