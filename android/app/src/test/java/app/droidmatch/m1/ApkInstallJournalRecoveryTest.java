package app.droidmatch.m1;

import android.content.SharedPreferences;
import java.io.File;
import java.io.IOException;
import java.lang.reflect.Proxy;
import java.nio.file.Files;
import java.util.Collections;
import org.junit.Test;
import static org.junit.Assert.*;

public final class ApkInstallJournalRecoveryTest {
    @Test public void emptyPreferencesAreFreshOnlyWhenBothBackingFilesAreAbsent() throws Exception {
        File directory = Files.createTempDirectory("droidmatch-install-journal").toFile();
        File xml = new File(directory, "journal.xml"), backup = new File(directory, "journal.xml.bak");
        SharedPreferences preferences = (SharedPreferences) Proxy.newProxyInstance(
                SharedPreferences.class.getClassLoader(), new Class<?>[]{SharedPreferences.class},
                (proxy, method, args) -> {
                    if (method.getName().equals("getAll")) return Collections.emptyMap();
                    throw new AssertionError("unexpected preference operation");
                });
        AndroidApkInstallJournal journal = new AndroidApkInstallJournal(preferences, xml, backup);
        try {
            assertTrue(journal.load().isEmpty());
            assertTrue(xml.createNewFile());
            assertUnreadable(journal);
            assertTrue(xml.delete());
            assertTrue(backup.createNewFile());
            assertUnreadable(journal);
        } finally {
            Files.deleteIfExists(xml.toPath()); Files.deleteIfExists(backup.toPath());
            Files.deleteIfExists(directory.toPath());
        }
    }
    private static void assertUnreadable(AndroidApkInstallJournal journal) throws Exception {
        try { journal.load(); fail("existing unreadable journal must not be treated as empty"); }
        catch (IOException expected) { assertEquals("installation journal is unavailable", expected.getMessage()); }
    }
}
