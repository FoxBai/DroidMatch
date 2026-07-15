package app.droidmatch.m1;

import android.content.ContentResolver;
import android.net.Uri;
import android.provider.DocumentsContract;

import java.io.Closeable;
import java.io.FileNotFoundException;
import java.io.IOException;

/** Best-effort cleanup used only while preserving the primary provider error. */
final class ProviderIoCleanup {
    private ProviderIoCleanup() {
    }

    static void closeQuietly(Closeable closeable) {
        if (closeable == null) {
            return;
        }
        try {
            closeable.close();
        } catch (IOException | RuntimeException ignored) {
        }
    }

    static void deleteDocumentQuietly(ContentResolver contentResolver, Uri documentUri) {
        if (documentUri == null) {
            return;
        }
        try {
            DocumentsContract.deleteDocument(contentResolver, documentUri);
        } catch (FileNotFoundException | RuntimeException ignored) {
        }
    }
}
