package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNull;

import org.junit.Test;

public final class ProviderSafDocumentCacheTest {
    private static final DmFileProvider.SafRoot DOCUMENTS =
            new DmFileProvider.SafRoot("documents", "primary:Documents", "Documents", true);

    @Test
    public void resolvesOpaqueIdentityAndEvictsLeastRecentlyUsedDocument() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(2);
        String first = cache.remember(DOCUMENTS, "primary:Documents/one.txt");
        String second = cache.remember(DOCUMENTS, "primary:Documents/two.txt");

        assertEquals("primary:Documents/one.txt", cache.documentId(DOCUMENTS, first));
        String third = cache.remember(DOCUMENTS, "primary:Documents/three.txt");

        assertEquals("primary:Documents/one.txt", cache.documentId(DOCUMENTS, first));
        assertNull(cache.documentId(DOCUMENTS, second));
        assertEquals("primary:Documents/three.txt", cache.documentId(DOCUMENTS, third));
    }

    @Test
    public void scopesSameDocumentIdentityToItsPersistedRoot() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(2);
        DmFileProvider.SafRoot pictures =
                new DmFileProvider.SafRoot("pictures", "primary:Pictures", "Pictures", true);
        String documentsToken = cache.remember(DOCUMENTS, "shared-document-id");
        String picturesToken = cache.remember(pictures, "shared-document-id");

        assertNotEquals(documentsToken, picturesToken);
        assertEquals("shared-document-id", cache.documentId(DOCUMENTS, documentsToken));
        assertEquals("shared-document-id", cache.documentId(pictures, picturesToken));
        assertNull(cache.documentId(pictures, documentsToken));
        assertNull(cache.documentId(DOCUMENTS, picturesToken));
    }
}
