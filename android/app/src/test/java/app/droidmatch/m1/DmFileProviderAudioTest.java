package app.droidmatch.m1;

import static app.droidmatch.m1.CursorTestFixture.cursor;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;
import app.droidmatch.proto.v1.SortField;

import java.nio.charset.StandardCharsets;
import java.util.Locale;
import org.junit.Test;

public final class DmFileProviderAudioTest {
    @Test
    public void audioRootKeepsLiveReadAndWriteIndependentFromVisualAccess() {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.canReadImages = false;
        catalog.canReadVideos = true;
        catalog.canReadAudio = false;
        catalog.canUploadMedia = true;
        DmFileProvider provider = new DmFileProvider(catalog);
        ListDirRequest roots = ListDirRequest.newBuilder().setPath(DmFileProvider.ROOTS_PATH).build();
        ListDirResponse denied = provider.listDir(roots);
        assertFalse(denied.hasError());
        assertEquals(DmFileProvider.MEDIA_AUDIO_PATH, denied.getEntries(3).getPath());
        assertFalse(denied.getEntries(3).getCanRead());
        assertTrue(denied.getEntries(3).getCanWrite());
        catalog.canReadAudio = true;
        assertTrue(provider.listDir(roots).getEntries(3).getCanRead());
        catalog.canReadAudio = false;
        catalog.canUploadMedia = false;
        assertFalse(provider.listDir(roots).getEntries(3).getCanRead());
        assertFalse(provider.listDir(roots).getEntries(3).getCanWrite());
    }

    @Test
    public void audioListingUsesBoundedCursorDurationAndCanonicalDownloadPath() throws Exception {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.page = MediaStoreCursorReader.readPage(cursor(
                MediaStoreCursorReader.listingProjection(DmFileProvider.RootKind.MEDIA_AUDIO),
                new Object[][] {
                    {42L, "Track.mp3", 6L, 3L, "audio/mpeg", 185_000L},
                    {43L, "Unknown.flac", 8L, 4L, "audio/flac", -1L},
                    {44L, "Wrong.mp4", 9L, 5L, "video/mp4", 42_000L},
                    {45L, "Invalid.mp3", 9L, 6L, "audio/mpeg; x=y", 42_000L},
                    {46L, "Next.mp3", 10L, 7L, "audio/mpeg", 10L}
                }), 4);
        DmFileProvider provider = new DmFileProvider(catalog);
        ListDirResponse page = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_AUDIO_PATH).setPageSize(4)
                .setSortField(SortField.SORT_FIELD_NAME).setSearchQuery("track").build());
        assertFalse(page.hasError());
        assertEquals(4, page.getEntriesCount());
        assertFalse(page.getNextPageToken().isEmpty());
        assertEquals(DmFileProvider.RootKind.MEDIA_AUDIO, catalog.rootKind);
        assertEquals("track", catalog.query.searchQuery());
        assertEquals(SortField.SORT_FIELD_NAME, catalog.query.sortField());
        assertEquals("dm://media-audio/media/42", page.getEntries(0).getPath());
        assertEquals(185_000L, page.getEntries(0).getDurationMillis());
        for (int index = 1; index < 4; index++) assertEquals(0, page.getEntries(index).getDurationMillis());
        assertFalse(page.getEntries(0).getCanWrite());

        catalog.streamData = "abcdef".getBytes(StandardCharsets.UTF_8);
        try (DmFileProvider.DownloadReader reader = provider.openDownload(
                page.getEntries(0).getPath(), 2, 2)) {
            assertEquals("cd", new String(reader.readNextChunk().data, StandardCharsets.UTF_8));
            assertTrue(reader.readNextChunk().finalChunk);
        }
        assertEquals(DmFileProvider.RootKind.MEDIA_AUDIO, catalog.readRootKind);
        assertEquals(42, catalog.mediaId);
        assertEquals(1, catalog.closeReaderCount);
        for (String suffix : new String[] {"", "media/-1", "media/+1", "media/١", "media/9223372036854775808", "media/42/child"}) {
            try {
                provider.openDownload("dm://media-audio/" + suffix, 0, 2);
                fail("invalid audio item admitted");
            } catch (DmFileProvider.ProviderCatalogException expected) {
                assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, expected.code);
            }
        }
    }

    @Test
    public void audioImportUsesExactTypesAndRemainsFreshOnly() throws Exception {
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.canReadAudio = false;
        catalog.canUploadMedia = true;
        DmFileProvider provider = new DmFileProvider(catalog);
        String[][] types = {{"aac", "audio/aac"}, {"flac", "audio/flac"},
                {"m4a", "audio/mp4"}, {"mp3", "audio/mpeg"}, {"oga", "audio/ogg"},
                {"ogg", "audio/ogg"}, {"opus", "audio/ogg"}, {"wav", "audio/wav"}};
        for (String[] type : types) {
            String name = "Track." + type[0].toUpperCase(Locale.ROOT);
            assertEquals(type[1], ProviderMimeTypes.mediaTypeFor(DmFileProvider.RootKind.MEDIA_AUDIO, name));
            assertNull(ProviderMimeTypes.mediaTypeFor(DmFileProvider.RootKind.MEDIA_IMAGES, name));
            assertNull(ProviderMimeTypes.mediaTypeFor(DmFileProvider.RootKind.MEDIA_VIDEOS, name));
        }
        try (DmFileProvider.UploadWriter writer = provider.openUpload("dm://media-audio/Track.mp3", 0, 6)) {
            writer.writeChunk(0, "abc".getBytes(StandardCharsets.UTF_8), false);
            writer.writeChunk(3, "def".getBytes(StandardCharsets.UTF_8), true);
        }
        assertEquals(DmFileProvider.RootKind.MEDIA_AUDIO, catalog.uploadRootKind);
        assertEquals("Track.mp3", catalog.uploadDisplayName);
        assertEquals("abcdef", catalog.uploadedText());
        for (String name : new String[] {"Clip.mp4", "Photo.jpg", "Track.bin", "nested/Track.mp3", "Track%20.mp3"}) {
            try {
                provider.openUpload("dm://media-audio/" + name, 0, 6);
                fail("unsupported audio import admitted");
            } catch (DmFileProvider.ProviderCatalogException expected) {
                assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, expected.code);
            }
        }
        try {
            provider.openUpload("dm://media-audio/Track.mp3", 1, 6);
            fail("audio resume admitted");
        } catch (DmFileProvider.ProviderCatalogException expected) {
            assertEquals(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, expected.code);
        }
    }
}
