package app.droidmatch.m1;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** Provider port: installed-package identity and private source access stay here. */
interface ApkExportCatalog {
    long exportGeneration();
    long applicationGeneration();
    Snapshot capture(String packageIdentifier) throws DmFileProvider.ProviderCatalogException;
    void validate(Snapshot snapshot, boolean complete) throws DmFileProvider.ProviderCatalogException;
    DmFileProvider.DownloadReader open(Snapshot snapshot, int index, int chunkSize)
            throws DmFileProvider.ProviderCatalogException;

    class Snapshot {
        final String packageIdentifier;
        final long versionCode;
        final long updatedMillis;
        final List<Component> components;

        Snapshot(String identifier, long version, long updated, List<Component> components) {
            packageIdentifier = identifier; versionCode = version; updatedMillis = updated;
            this.components = Collections.unmodifiableList(new ArrayList<>(components));
        }
    }

    final class Component {
        final String splitName;
        final long sizeBytes;
        Component(String splitName, long sizeBytes) {
            this.splitName = splitName; this.sizeBytes = sizeBytes;
        }
    }
}
