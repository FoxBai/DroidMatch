package app.droidmatch.m1;

import java.io.IOException;
import java.util.List;

/** Private, bounded and atomic. A failed save must prevent the next irreversible action. */
interface ApkInstallJournal {
    List<ApkInstallRecord> load() throws IOException;
    void save(List<ApkInstallRecord> records) throws IOException;
}
