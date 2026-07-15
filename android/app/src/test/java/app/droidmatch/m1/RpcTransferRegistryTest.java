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

        for (long streamId = 1;
             streamId <= RpcTransferRegistry.MAX_TERMINAL_STREAMS_PER_SESSION + 1L;
             streamId += 1) {
            registry.markTerminalStream(30, streamId);
        }
        assertFalse(registry.isTerminalStream(30, 1));
        assertTrue(registry.isTerminalStream(
                30,
                RpcTransferRegistry.MAX_TERMINAL_STREAMS_PER_SESSION + 1L
        ));

        registry.markTerminalStream(40, 99);
        assertEquals(4, RpcTransferRegistry.MAX_DRAIN_FRAMES_PER_TERMINAL_STREAM);
        for (int frame = 0;
             frame < RpcTransferRegistry.MAX_DRAIN_FRAMES_PER_TERMINAL_STREAM;
             frame += 1) {
            assertTrue(registry.consumeTerminalFrame(40, 99));
        }
        assertFalse(registry.consumeTerminalFrame(40, 99));
        assertTrue(registry.isTerminalStream(40, 99));
        assertTrue(registry.hasStream(40, 99));
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
        registry.markTerminalStream(10, 9);
        registry.markTerminalStream(20, 9);

        registry.closeSession(10);

        assertEquals(1, firstReader.closeCount);
        assertEquals(1, firstWriter.closeCount);
        assertEquals(0, otherReader.closeCount);
        assertEquals(0, registry.count(10));
        assertEquals(1, registry.count(20));
        assertFalse(registry.isTerminalStream(10, 9));
        assertTrue(registry.isTerminalStream(20, 9));
    }

    private static Download download(String transferId, CloseProbeReader reader) {
        return new Download(1, transferId, reader, 256, 0);
    }

    private static Upload upload(String transferId, CloseProbeWriter writer) {
        return new Upload(1, transferId, writer, 256);
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
