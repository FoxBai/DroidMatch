package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.fail;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ErrorCode;

import java.nio.charset.StandardCharsets;

import org.junit.Test;

public final class DmFileProviderMediaTransferTest {
    @Test
    public void unknownDownloadPathDoesNotEchoCallerPath() throws Exception {
        DmFileProvider provider = new DmFileProvider();

        try {
            provider.openDownload("dm://private-root/private-report.txt", 0, 1);
            fail("expected unknown provider path to be rejected");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, exception.code);
            assertEquals("unknown DroidMatch provider path", exception.getMessage());
            assertFalse(exception.getMessage().contains("private-report.txt"));
        }
    }

    @Test
    public void mediaFilePathReadsDownloadChunk() throws Exception {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.downloadChunk = new DmFileProvider.DownloadChunk(
                "hello".getBytes(StandardCharsets.UTF_8),
                5,
                1_700_000_000_000L,
                "media-etag",
                true
        );
        DmFileProvider provider = new DmFileProvider(catalog);

        DmFileProvider.DownloadChunk chunk = provider.readDownloadChunk(
                "dm://media-images/media/42",
                1,
                4
        );

        assertEquals(DmFileProvider.RootKind.MEDIA_IMAGES, catalog.readRootKind);
        assertEquals(42, catalog.mediaId);
        assertEquals(1, catalog.readOffsetBytes);
        assertEquals(4, catalog.readChunkSizeBytes);
        assertEquals("hello", new String(chunk.data, StandardCharsets.UTF_8));
        assertTrue(chunk.finalChunk);
    }

    @Test
    public void mediaRootPathUploadsFreshFile() throws Exception {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        DmFileProvider provider = new DmFileProvider(catalog);

        DmFileProvider.UploadWriter writer = provider.openUpload("dm://media-images/payload.jpg", 0, 6);
        writer.writeChunk(0, "abc".getBytes(StandardCharsets.UTF_8), false);
        writer.writeChunk(3, "def".getBytes(StandardCharsets.UTF_8), true);
        writer.close();

        assertEquals(DmFileProvider.RootKind.MEDIA_IMAGES, catalog.uploadRootKind);
        assertEquals("payload.jpg", catalog.uploadDisplayName);
        assertEquals(0, catalog.uploadOffsetBytes);
        assertEquals(6, catalog.uploadExpectedSizeBytes);
        assertEquals("abcdef", catalog.uploadedText());
    }

    @Test
    public void mediaUploadRejectsResumeOffset() throws Exception {
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog());

        try {
            provider.openUpload("dm://media-videos/payload.mp4", 1, 6);
            fail("expected MediaStore upload resume to be rejected");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, exception.code);
        }
    }

    @Test
    public void mediaUploadRejectsNestedPath() throws Exception {
        DmFileProvider provider = new DmFileProvider(new FakeMediaCatalog());

        try {
            provider.openUpload("dm://media-images/nested/payload.jpg", 0, 6);
            fail("expected nested MediaStore upload path to be rejected");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
        }
    }

    @Test
    public void openDownloadReusesOneReaderAcrossChunks() throws Exception {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.streamData = "abcdef".getBytes(StandardCharsets.UTF_8);
        DmFileProvider provider = new DmFileProvider(catalog);

        DmFileProvider.DownloadReader reader = provider.openDownload(
                "dm://media-images/media/42",
                2,
                2
        );
        DmFileProvider.DownloadChunk first = reader.readNextChunk();
        DmFileProvider.DownloadChunk second = reader.readNextChunk();
        reader.close();

        assertEquals(1, catalog.openMediaCount);
        assertEquals(42, catalog.mediaId);
        assertEquals(2, catalog.readOffsetBytes);
        assertEquals(2, catalog.readChunkSizeBytes);
        assertEquals("cd", new String(first.data, StandardCharsets.UTF_8));
        assertFalse(first.finalChunk);
        assertEquals("ef", new String(second.data, StandardCharsets.UTF_8));
        assertTrue(second.finalChunk);
        assertEquals(1, catalog.closeReaderCount);
    }
}
