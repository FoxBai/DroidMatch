package app.droidmatch.m1;

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/** All mutable fields are owned by the manager lock, avoiding writer/manager lock inversion. */
final class ApkInstallUploadWriter implements DmFileProvider.UploadWriter {
    final ApkInstallManager manager;
    final String id;
    final ApkInstallBackend.Sink sink;
    final MessageDigest digest;
    long offset;
    boolean closed;

    ApkInstallUploadWriter(ApkInstallManager manager, String id, ApkInstallBackend.Sink sink) {
        this.manager = manager;
        this.id = id;
        this.sink = sink;
        try { digest = MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("required installation digest is unavailable");
        }
    }

    @Override public long nextOffsetBytes() { return manager.nextOffset(this); }
    @Override public void writeChunk(long offset, byte[] data, boolean last)
            throws DmFileProvider.ProviderCatalogException { manager.write(this, offset, data, last); }
    @Override public void cancel() throws DmFileProvider.ProviderCatalogException { manager.cancelWriter(this); }
    @Override public void close() { manager.closeWriter(this); }
    @Override public String toString() { return "ApkInstallUploadWriter[redacted]"; }
}
