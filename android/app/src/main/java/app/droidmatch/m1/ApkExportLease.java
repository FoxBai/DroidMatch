package app.droidmatch.m1;

import app.droidmatch.proto.v1.ApkExportComponent;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.PrepareApkExportResponse;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;

/** One bounded immutable installed set owned by exactly one paired RPC session. */
final class ApkExportLease {
    static final String PREFIX = "dm://apk-export/";
    static final int MAX_COMPONENTS = 256;
    static final long MAX_COMPONENT_BYTES = 8L * 1024 * 1024 * 1024;
    static final long MAX_TOTAL_BYTES = 64L * 1024 * 1024 * 1024;
    final String id = UUID.randomUUID().toString();
    private final ApkExportCatalog catalog;
    private final ApkExportCatalog.Snapshot snapshot;
    private final long exportGeneration;
    private final long applicationGeneration;
    private boolean active = true;

    ApkExportLease(ApkExportCatalog catalog, String identifier)
            throws DmFileProvider.ProviderCatalogException {
        this.catalog = catalog;
        exportGeneration = catalog.exportGeneration();
        applicationGeneration = catalog.applicationGeneration();
        requireConsent();
        if (!ApplicationListProvider.validIdentifier(identifier)) throw failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
        snapshot = catalog.capture(identifier);
        if (snapshot == null || !identifier.equals(snapshot.packageIdentifier)
                || snapshot.versionCode < 0 || snapshot.updatedMillis < 0
                || snapshot.components.isEmpty() || snapshot.components.size() > MAX_COMPONENTS) {
            throw failure(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY);
        }
        long total = 0;
        Set<String> names = new HashSet<>();
        for (int i = 0; i < snapshot.components.size(); i++) {
            ApkExportCatalog.Component part = snapshot.components.get(i);
            if (part == null || !validSplitName(part.splitName, i == 0)
                    || !names.add(part.splitName) || part.sizeBytes <= 0
                    || part.sizeBytes > MAX_COMPONENT_BYTES) {
                throw failure(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY);
            }
            total += part.sizeBytes;
            if (total > MAX_TOTAL_BYTES) throw failure(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY);
        }
        validate(true);
    }

    PrepareApkExportResponse manifest() throws DmFileProvider.ProviderCatalogException {
        validate(true);
        PrepareApkExportResponse.Builder result = PrepareApkExportResponse.newBuilder()
                .setExportId(id).setPackageIdentifier(snapshot.packageIdentifier)
                .setVersionCode(snapshot.versionCode).setUpdatedMillis(snapshot.updatedMillis);
        for (int i = 0; i < snapshot.components.size(); i++) {
            ApkExportCatalog.Component part = snapshot.components.get(i);
            result.addComponents(ApkExportComponent.newBuilder().setIndex(i)
                    .setSplitName(part.splitName).setSizeBytes(part.sizeBytes));
        }
        return result.build();
    }

    synchronized void invalidate() { active = false; }

    synchronized void validate(boolean complete) throws DmFileProvider.ProviderCatalogException {
        if (!active) throw failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
        requireConsent();
        catalog.validate(snapshot, complete);
        requireConsent();
    }

    DmFileProvider.DownloadReader open(String path, long offset, int chunkSize)
            throws DmFileProvider.ProviderCatalogException {
        validate(true);
        if (offset != 0) throw failure(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY);
        int index = -1;
        for (int i = 0; i < snapshot.components.size(); i++) {
            if (path.equals(PREFIX + id + "/" + i + ".apk")) { index = i; break; }
        }
        if (index < 0) throw failure(ErrorCode.ERROR_CODE_NOT_FOUND);
        final long expectedSize = snapshot.components.get(index).sizeBytes;
        final String etag = id + ":" + index;
        final DmFileProvider.DownloadReader reader = catalog.open(snapshot, index, chunkSize);
        if (reader == null) throw failure(ErrorCode.ERROR_CODE_INTERNAL);
        return new DmFileProvider.DownloadReader() {
            private long received;
            private boolean closed;
            @Override public DmFileProvider.DownloadChunk readNextChunk()
                    throws DmFileProvider.ProviderCatalogException {
                if (closed) throw failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
                try {
                    validate(false);
                    DmFileProvider.DownloadChunk chunk = reader.readNextChunk();
                    validate(chunk.finalChunk);
                    if (chunk.data.length == 0 || chunk.data.length > chunkSize
                            || chunk.data.length > expectedSize - received) {
                        throw failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
                    }
                    received += chunk.data.length;
                    if (chunk.finalChunk != (received == expectedSize)) {
                        throw failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
                    }
                    if (chunk.finalChunk) close();
                    return new DmFileProvider.DownloadChunk(chunk.data, expectedSize, 0, etag, chunk.finalChunk);
                } catch (DmFileProvider.ProviderCatalogException | RuntimeException failure) {
                    close(); throw failure;
                }
            }
            @Override public void close() { if (!closed) { closed = true; reader.close(); } }
        };
    }

    private void requireConsent() throws DmFileProvider.ProviderCatalogException {
        if (exportGeneration == 0 || applicationGeneration == 0
                || catalog.exportGeneration() != exportGeneration
                || catalog.applicationGeneration() != applicationGeneration) {
            throw failure(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED);
        }
    }

    static boolean validSplitName(String name, boolean base) {
        if (name == null) return false;
        if (base) return name.isEmpty();
        if (name.isEmpty() || name.length() > 160) return false;
        for (int i = 0; i < name.length(); i++) {
            char c = name.charAt(i);
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                    || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-')) return false;
        }
        return true;
    }

    static DmFileProvider.ProviderCatalogException failure(ErrorCode code) {
        return new DmFileProvider.ProviderCatalogException(code, "APK export is unavailable");
    }
}
