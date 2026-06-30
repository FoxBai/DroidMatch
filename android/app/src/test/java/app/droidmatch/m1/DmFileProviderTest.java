package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.FileEntry;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;

import org.junit.Test;

public final class DmFileProviderTest {
    @Test
    public void rootsPathListsVirtualProviderRoots() {
        DmFileProvider provider = new DmFileProvider();

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .build());

        assertFalse(response.hasError());
        assertEquals(3, response.getEntriesCount());
        FileEntry first = response.getEntries(0);
        assertEquals("dm://media-images/", first.getPath());
        assertEquals("Images", first.getName());
        assertEquals(FileKind.FILE_KIND_VIRTUAL, first.getKind());
        assertTrue(first.getCanRead());
        for (FileEntry entry : response.getEntriesList()) {
            assertFalse(entry.getCanWrite());
        }
    }

    @Test
    public void pageTokensAreRejectedUntilPagingIsImplemented() {
        DmFileProvider provider = new DmFileProvider();

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath(DmFileProvider.ROOTS_PATH)
                .setPageToken("opaque")
                .build());

        assertTrue(response.hasError());
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, response.getError().getCode());
    }

    @Test
    public void unknownPathsReturnNotFound() {
        DmFileProvider provider = new DmFileProvider();

        ListDirResponse response = provider.listDir(ListDirRequest.newBuilder()
                .setPath("dm://media-images/")
                .build());

        assertTrue(response.hasError());
        assertEquals(ErrorCode.ERROR_CODE_NOT_FOUND, response.getError().getCode());
    }
}
