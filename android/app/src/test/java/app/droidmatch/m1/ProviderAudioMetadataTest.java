package app.droidmatch.m1;

import static app.droidmatch.m1.CursorTestFixture.cursor;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ListDirRequest;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import org.junit.Test;

public final class ProviderAudioMetadataTest {
    @Test
    public void displayProjectionBoundsUnicodeWorkAndUnknownValues() {
        ProviderAudioMetadata labels = new ProviderAudioMetadata(
                "  Cafe\u0301\n\u202eSong ", "<UNKNOWN>", "\u200b\u0001");
        assertEquals("Café Song", labels.title);
        assertEquals("", labels.artist);
        assertEquals("", labels.album);
        String emoji = String.join("", Collections.nCopies(121, "🎵"));
        ProviderAudioMetadata bounded = new ProviderAudioMetadata(emoji, null, null);
        assertEquals(120, bounded.title.codePointCount(0, bounded.title.length()));
        assertTrue(bounded.title.endsWith("…"));
        assertTrue(bounded.title.getBytes(StandardCharsets.UTF_8).length <= 512);
        assertTrue(new ProviderAudioMetadata(
                String.join("", Collections.nCopies(2049, "x")), null, "<unknown>").isEmpty());
    }

    @Test
    public void absentColumnsAndOtherRootsKeepFilenameOnlyRows() {
        DmFileProvider.MediaPage oldPage = MediaStoreCursorReader.readPage(cursor(
                MediaStoreCursorReader.mediaProjection(),
                new Object[][] {{9L, "old.mp3", 20L, 1L, "audio/mpeg"}}), 1);
        assertTrue(oldPage.items.get(0).audioMetadata.isEmpty());
        FakeMediaCatalog catalog = new FakeMediaCatalog();
        catalog.page = new DmFileProvider.MediaPage(Collections.singletonList(
                new DmFileProvider.MediaItem(9L, "original.mp3", 20L, 1L, "audio/mpeg", 1L,
                        new ProviderAudioMetadata("Visible", "Artist", "Album"))), false);
        DmFileProvider provider = new DmFileProvider(catalog);
        for (String root : Arrays.asList(DmFileProvider.MEDIA_IMAGES_PATH, DmFileProvider.MEDIA_VIDEOS_PATH)) {
            var response = provider.listDir(ListDirRequest.newBuilder().setPath(root).build());
            assertFalse(response.hasError());
            assertEquals("original.mp3", response.getEntries(0).getName());
            assertFalse(response.getEntries(0).hasAudioMetadata());
        }
        catalog.page = new DmFileProvider.MediaPage(Collections.singletonList(
                new DmFileProvider.MediaItem(-1L, "original.mp3", 20L, 1L, "audio/mpeg", 1L,
                        new ProviderAudioMetadata("Ignored", null, null))), false);
        assertFalse(provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.MEDIA_AUDIO_PATH).build()).getEntries(0).hasAudioMetadata());
    }

    @Test
    public void audioSearchBindsEveryLabelAndKeepsExistingConstraintOutsideOrGroup() {
        ArrayList<String> arguments = new ArrayList<>(Collections.singletonList("bucket"));
        String query = "50%_\\' OR 1=1";
        String selection = MediaStoreSearch.append(DmFileProvider.RootKind.MEDIA_AUDIO,
                query, "bucket_id = ?", arguments);
        assertEquals("bucket_id = ? AND (_display_name LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'"
                + " OR artist LIKE ? ESCAPE '\\' OR album LIKE ? ESCAPE '\\')", selection);
        assertEquals(5, arguments.size());
        assertEquals("bucket", arguments.get(0));
        for (int index = 1; index < 5; index++) {
            assertEquals("%50\\%\\_\\\\' OR 1=1%", arguments.get(index));
        }
        assertFalse(selection.contains(query));
    }

    @Test
    public void otherMediaSearchStaysFilenameOnlyAndEmptyQueryAddsNothing() {
        ArrayList<String> arguments = new ArrayList<>();
        assertEquals("(_display_name LIKE ? ESCAPE '\\')", MediaStoreSearch.append(
                DmFileProvider.RootKind.MEDIA_IMAGES, "photo", null, arguments));
        assertEquals(Collections.singletonList("%photo%"), arguments);
        assertEquals("existing", MediaStoreSearch.append(
                DmFileProvider.RootKind.MEDIA_AUDIO, "", "existing", arguments));
        assertEquals(1, arguments.size());
    }
}
