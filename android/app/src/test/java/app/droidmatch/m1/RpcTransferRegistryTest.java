package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import app.droidmatch.m1.RpcTransferStreams.Download;
import app.droidmatch.m1.RpcTransferStreams.Upload;

import org.junit.Test;

public final class RpcTransferRegistryTest {
    @Test
    public void registryIsolatesStreamsAndTransferIdsBySession() {
        RpcTransferRegistry registry = new RpcTransferRegistry();
        Download first = download("shared-id", new CloseProbeReader());
        Upload second = upload("shared-id", new CloseProbeWriter());

        registry.installDownload(10, 1, first);
        registry.installUpload(20, 1, second);

        assertEquals(1, registry.count(10));
        assertEquals(1, registry.count(20));
        assertTrue(registry.hasTransferId(10, "shared-id"));
        assertTrue(registry.hasTransferId(20, "shared-id"));
        assertSame(first, registry.download(10, 1));
        assertSame(second, registry.upload(20, 1));
        assertNull(registry.download(20, 1));
    }

    @Test
    public void crossDirectionIdentityAndStreamChecksShareOneNamespace() {
        RpcTransferRegistry registry = new RpcTransferRegistry();
        registry.installDownload(10, 7, download("download-id", new CloseProbeReader()));

        assertTrue(registry.hasStream(10, 7));
        assertTrue(registry.hasTransferId(10, "download-id"));
        assertFalse(registry.hasStream(10, 8));
        assertFalse(registry.hasTransferId(10, "upload-id"));
    }

    @Test
    public void closeSessionReleasesOnlyOwnedHandlesAndClearsRegistry() {
        RpcTransferRegistry registry = new RpcTransferRegistry();
        CloseProbeReader firstReader = new CloseProbeReader();
        CloseProbeWriter firstWriter = new CloseProbeWriter();
        CloseProbeReader otherReader = new CloseProbeReader();
        registry.installDownload(10, 1, download("one", firstReader));
        registry.installUpload(10, 2, upload("two", firstWriter));
        registry.installDownload(20, 1, download("other", otherReader));

        registry.closeSession(10);

        assertEquals(1, firstReader.closeCount);
        assertEquals(1, firstWriter.closeCount);
        assertEquals(0, otherReader.closeCount);
        assertEquals(0, registry.count(10));
        assertEquals(1, registry.count(20));
    }

    private static Download download(String transferId, CloseProbeReader reader) {
        return new Download(transferId, reader, 256, 0);
    }

    private static Upload upload(String transferId, CloseProbeWriter writer) {
        return new Upload(transferId, writer, 256);
    }

    private static final class CloseProbeReader implements DmFileProvider.DownloadReader {
        int closeCount;

        @Override
        public DmFileProvider.DownloadChunk readNextChunk() {
            throw new AssertionError("registry tests do not read provider data");
        }

        @Override
        public void close() {
            closeCount += 1;
        }
    }

    private static final class CloseProbeWriter implements DmFileProvider.UploadWriter {
        int closeCount;

        @Override
        public long nextOffsetBytes() {
            return 0;
        }

        @Override
        public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk) {
            throw new AssertionError("registry tests do not write provider data");
        }

        @Override
        public void close() {
            closeCount += 1;
        }
    }
}
