package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;
import app.droidmatch.proto.v1.SortField;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;

import org.junit.Test;

public final class DmFileProviderLargeDirectoryTest {
    @Test
    public void appSandboxPaginatesMoreThanOneThousandEntriesWithoutGaps() throws Exception {
        File root = Files.createTempDirectory("droidmatch-large-directory").toFile();
        try {
            for (int index = 0; index < 1_005; index++) {
                assertTrue(new File(root, String.format("file-%04d.bin", index)).createNewFile());
            }
            DmFileProvider provider = new DmFileProvider(root);
            ListDirRequest firstRequest = ListDirRequest.newBuilder()
                    .setPath(DmFileProvider.APP_SANDBOX_PATH)
                    .setPageSize(1_000)
                    .setSortField(SortField.SORT_FIELD_NAME)
                    .build();

            ListDirResponse first = provider.listDir(firstRequest);
            ListDirResponse second = provider.listDir(firstRequest.toBuilder()
                    .setPageToken(first.getNextPageToken())
                    .build());

            assertFalse(first.hasError());
            assertEquals(1_000, first.getEntriesCount());
            assertFalse(first.getNextPageToken().isEmpty());
            assertEquals("file-0000.bin", first.getEntries(0).getName());
            assertEquals("file-0999.bin", first.getEntries(999).getName());
            assertFalse(second.hasError());
            assertEquals(5, second.getEntriesCount());
            assertEquals("file-1000.bin", second.getEntries(0).getName());
            assertEquals("file-1004.bin", second.getEntries(4).getName());
            assertTrue(second.getNextPageToken().isEmpty());
        } finally {
            deleteRecursively(root);
        }
    }

    private static void deleteRecursively(File file) throws IOException {
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) {
                deleteRecursively(child);
            }
        }
        Files.deleteIfExists(file.toPath());
    }
}
