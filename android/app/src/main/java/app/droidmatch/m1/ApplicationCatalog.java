package app.droidmatch.m1;

import java.util.List;

/** Platform application metadata stays behind this port, not in the dispatcher. */
interface ApplicationCatalog {
    long accessGeneration();
    List<Entry> queryLaunchableApplications() throws Exception;

    final class Entry {
        final String packageIdentifier;
        final String displayName;
        final String versionName;
        final long versionCode;
        final long updatedMillis;
        final boolean systemApplication;

        Entry(String packageIdentifier, String displayName, String versionName,
                long versionCode, long updatedMillis, boolean systemApplication) {
            this.packageIdentifier = packageIdentifier;
            this.displayName = displayName;
            this.versionName = versionName;
            this.versionCode = versionCode;
            this.updatedMillis = updatedMillis;
            this.systemApplication = systemApplication;
        }
    }
}
