package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.fail;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ErrorCode;

import java.nio.charset.StandardCharsets;
import java.util.Locale;

import org.junit.Test;

public final class DmFileProviderMediaTransferTest {
    private static final String[][] IMAGE_MEDIA_TYPES = new String[][] {
            { "avif", "image/avif" },
            { "bmp", "image/bmp" },
            { "dng", "image/x-adobe-dng" },
            { "gif", "image/gif" },
            { "heic", "image/heic" },
            { "heif", "image/heif" },
            { "jpeg", "image/jpeg" },
            { "jpg", "image/jpeg" },
            { "png", "image/png" },
            { "tif", "image/tiff" },
            { "tiff", "image/tiff" },
            { "webp", "image/webp" },
    };
    private static final String[][] VIDEO_MEDIA_TYPES = new String[][] {
            { "3gp", "video/3gpp" },
            { "3gpp", "video/3gpp" },
            { "avi", "video/x-msvideo" },
            { "m2ts", "video/mp2t" },
            { "m4v", "video/mp4" },
            { "mkv", "video/x-matroska" },
            { "mov", "video/quicktime" },
            { "mp4", "video/mp4" },
            { "mpeg", "video/mpeg" },
            { "mpg", "video/mpeg" },
            { "ogv", "video/ogg" },
            { "webm", "video/webm" },
    };

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

        try {
            provider.openUpload("dm://media-images/payload.jpg", 0, 6);
            fail("expected unavailable MediaStore upload to fail closed");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            assertEquals(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, exception.code);
        }
        catalog.canUploadMedia = true;

        for (String[] mediaType : IMAGE_MEDIA_TYPES) {
            String extension = mediaType[0];
            String expectedMimeType = mediaType[1];
            assertEquals(expectedMimeType, ProviderMimeTypes.mediaTypeFor(
                    DmFileProvider.RootKind.MEDIA_IMAGES,
                    "photo." + extension
            ));
            assertEquals(expectedMimeType, ProviderMimeTypes.mediaTypeFor(
                    DmFileProvider.RootKind.MEDIA_IMAGES,
                    "photo." + extension.toUpperCase(Locale.ROOT)
            ));
            assertEquals(null, ProviderMimeTypes.mediaTypeFor(
                    DmFileProvider.RootKind.MEDIA_VIDEOS,
                    "photo." + extension
            ));
        }
        for (String[] mediaType : VIDEO_MEDIA_TYPES) {
            String extension = mediaType[0];
            String expectedMimeType = mediaType[1];
            assertEquals(expectedMimeType, ProviderMimeTypes.mediaTypeFor(
                    DmFileProvider.RootKind.MEDIA_VIDEOS,
                    "clip." + extension
            ));
            assertEquals(expectedMimeType, ProviderMimeTypes.mediaTypeFor(
                    DmFileProvider.RootKind.MEDIA_VIDEOS,
                    "clip." + extension.toUpperCase(Locale.ROOT)
            ));
            assertEquals(null, ProviderMimeTypes.mediaTypeFor(
                    DmFileProvider.RootKind.MEDIA_IMAGES,
                    "clip." + extension
            ));
        }
        for (String extension : new String[] { "ts", "TS" }) {
            assertEquals(null, ProviderMimeTypes.mediaTypeFor(
                    DmFileProvider.RootKind.MEDIA_VIDEOS,
                    "ambiguous." + extension
            ));
        }
        assertTrue(ProviderMimeTypes.isCanonicalVideoMetadata("VIDEO/MP4"));
        assertTrue(ProviderMimeTypes.isCanonicalVideoMetadata("video/x-matroska"));
        assertFalse(ProviderMimeTypes.isCanonicalVideoMetadata("image/jpeg"));
        assertFalse(ProviderMimeTypes.isCanonicalVideoMetadata("video/mp4; charset=utf-8"));
        assertFalse(ProviderMimeTypes.isCanonicalVideoMetadata("video/mp4\n"));
        assertFalse(ProviderMimeTypes.isCanonicalVideoMetadata("video//mp4"));
        assertFalse(ProviderMimeTypes.isCanonicalVideoMetadata("video/-mp4"));
        assertFalse(ProviderMimeTypes.isCanonicalVideoMetadata(
                "video/" + "a".repeat(122)
        ));

        for (String path : new String[] {
                "dm://media-images/payload.mp4",
                "dm://media-videos/payload.jpg",
                "dm://media-images/payload.bin"
        }) {
            try {
                provider.openUpload(path, 0, 6);
                fail("expected mismatched MediaStore type to fail closed");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
                assertEquals(
                        "media upload file type does not match destination",
                        exception.getMessage()
                );
                assertFalse(exception.getMessage().contains("payload"));
            }
        }

        String supplementaryFormat = new String(Character.toChars(0xE0001));
        for (String displayName : new String[] {
                "private%name.jpg",
                "private" + String.valueOf((char) 0x0001) + "name.jpg",
                "private" + String.valueOf((char) 0x0085) + "name.jpg",
                "private\u200Dname.jpg",
                "private\u202Ename.jpg",
                "private\u2068name.jpg",
                "private" + supplementaryFormat + "name.jpg",
        }) {
            try {
                provider.openUpload("dm://media-images/" + displayName, 0, 6);
                fail("expected unsafe MediaStore display name to fail closed");
            } catch (DmFileProvider.ProviderCatalogException exception) {
                assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, exception.code);
                assertEquals("malformed MediaStore upload file name", exception.getMessage());
                assertFalse(exception.getMessage().contains("private"));
            }
        }

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
