package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;

import org.junit.Test;

public final class ProviderSafDocumentCacheTest {
    private static final DmFileProvider.SafRoot DOCUMENTS =
            new DmFileProvider.SafRoot("documents", "primary:Documents", "Documents", true);

    @Test
    public void resolvesOpaqueIdentityAndEvictsLeastRecentlyUsedDocument() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(2);
        String first = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                "primary:Documents/one.txt"
        );
        String second = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                "primary:Documents/two.txt"
        );

        assertEquals("primary:Documents/one.txt", cache.documentId(DOCUMENTS, first));
        String third = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                "primary:Documents/three.txt"
        );

        assertEquals("primary:Documents/one.txt", cache.documentId(DOCUMENTS, first));
        assertNull(cache.documentId(DOCUMENTS, second));
        assertEquals("primary:Documents/three.txt", cache.documentId(DOCUMENTS, third));
    }

    @Test
    public void scopesSameDocumentIdentityToItsPersistedRoot() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(2);
        DmFileProvider.SafRoot pictures =
                new DmFileProvider.SafRoot("pictures", "primary:Pictures", "Pictures", true);
        String documentsToken = cache.remember(
                DOCUMENTS,
                DOCUMENTS.documentId,
                "shared-document-id"
        );
        String picturesToken = cache.remember(
                pictures,
                pictures.documentId,
                "shared-document-id"
        );

        assertNotEquals(documentsToken, picturesToken);
        assertEquals("shared-document-id", cache.documentId(DOCUMENTS, documentsToken));
        assertEquals("shared-document-id", cache.documentId(pictures, picturesToken));
        assertNull(cache.documentId(pictures, documentsToken));
        assertNull(cache.documentId(DOCUMENTS, picturesToken));
    }

    @Test
    public void bindsSameDocumentIdentityToItsListedParent() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(2);
        String firstParent = "primary:Documents/first";
        String secondParent = "primary:Documents/second";
        String firstToken = cache.remember(DOCUMENTS, firstParent, "shared-document-id");
        String secondToken = cache.remember(DOCUMENTS, secondParent, "shared-document-id");

        ProviderSafDocumentCache.DocumentTarget first = cache.target(DOCUMENTS, firstToken);
        ProviderSafDocumentCache.DocumentTarget second = cache.target(DOCUMENTS, secondToken);

        assertNotEquals(firstToken, secondToken);
        assertNotNull(first);
        assertNotNull(second);
        assertEquals("shared-document-id", first.documentId);
        assertEquals(firstParent, first.parentDocumentId);
        assertEquals("shared-document-id", second.documentId);
        assertEquals(secondParent, second.parentDocumentId);
    }

    @Test
    public void parentAndDocumentTupleBoundariesCannotAlias() {
        ProviderSafDocumentCache cache = new ProviderSafDocumentCache(3);

        String first = cache.remember(DOCUMENTS, "parent\nchild", "leaf");
        String second = cache.remember(DOCUMENTS, "parent", "child\nleaf");
        String missingParent = cache.remember(DOCUMENTS, null, "leaf");

        assertNotEquals(first, second);
        assertNotEquals(first, missingParent);
        assertEquals("parent\nchild", cache.target(DOCUMENTS, first).parentDocumentId);
        assertEquals("parent", cache.target(DOCUMENTS, second).parentDocumentId);
        assertNull(cache.target(DOCUMENTS, missingParent).parentDocumentId);
    }
}
