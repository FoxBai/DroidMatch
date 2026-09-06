package app.droidmatch.m1;

import static org.junit.Assert.*;
import app.droidmatch.proto.v1.ApplicationSortField;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.ListApplicationsRequest;
import app.droidmatch.proto.v1.ListApplicationsResponse;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import org.junit.Test;

public final class ApplicationListProviderTest {
    @Test public void explicitConsentAndRevocationBoundEverySnapshot() {
        Catalog catalog = new Catalog();
        ApplicationListProvider provider = new ApplicationListProvider(catalog);
        ListApplicationsRequest request = request();
        assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, provider.list(request, 1).getError().getCode());
        assertEquals(0, catalog.queries);
        catalog.access.setEnabled(true);
        assertEquals(2, provider.list(request, 1).getEntriesCount());
        catalog.duringQuery = () -> {
            catalog.access.setEnabled(false);
            catalog.access.setEnabled(true);
        };
        ListApplicationsResponse revoked = provider.list(request, 1);
        assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, revoked.getError().getCode());
        assertEquals(0, revoked.getEntriesCount());
        catalog.duringQuery = () -> {};
        assertEquals(2, provider.list(request, 1).getEntriesCount());
    }

    @Test public void pagingBindsSessionQueryOrderSnapshotAndConsent() {
        Catalog catalog = new Catalog();
        catalog.access.setEnabled(true);
        ApplicationListProvider provider = new ApplicationListProvider(catalog);
        ListApplicationsRequest first = request().toBuilder().setPageSize(1).build();
        ListApplicationsResponse page = provider.list(first, 11);
        assertEquals("Alpha", page.getEntries(0).getDisplayName());
        assertEquals(2, page.getTotalCount());
        assertFalse(page.getNextPageToken().isEmpty());
        ListApplicationsRequest next = first.toBuilder().setPageToken(page.getNextPageToken()).build();
        assertEquals("Zulu", provider.list(next, 11).getEntries(0).getDisplayName());
        assertTrue(provider.list(next, 11).getNextPageToken().isEmpty());
        assertStale(provider.list(next, 12));
        assertStale(provider.list(next.toBuilder().setQuery("Alpha").build(), 11));
        assertStale(provider.list(next.toBuilder().setDescending(true).build(), 11));
        assertStale(new ApplicationListProvider(catalog).list(next, 11));
        String forged = page.getNextPageToken().substring(0, 91)
                + (page.getNextPageToken().endsWith("A") ? "B" : "A");
        assertStale(provider.list(next.toBuilder().setPageToken(forged).build(), 11));
        catalog.entries = Arrays.asList(entry("alpha", "Alpha", 10), entry("zulu", "Zulu", 31));
        assertStale(provider.list(next, 11));
        catalog.access.setEnabled(false);
        catalog.access.setEnabled(true);
        assertStale(provider.list(next, 11));
        assertEquals("Zulu", provider.list(request().toBuilder()
                .setSortField(ApplicationSortField.APPLICATION_SORT_FIELD_UPDATED)
                .setDescending(true).build(), 11).getEntries(0).getDisplayName());
        assertEquals(1, provider.list(request().toBuilder().setQuery("EXAMPLE.ALPHA").build(), 11)
                .getTotalCount());
    }

    @Test public void metadataIsBoundedAndRequestsAreCheckedBeforeCatalogWork() {
        Catalog catalog = new Catalog();
        catalog.access.setEnabled(true);
        catalog.entries = Collections.singletonList(new ApplicationCatalog.Entry(
                "example.alpha", "  e\u0301\u202e\n", "1.0\u0000", 7, 23, true));
        ApplicationListProvider provider = new ApplicationListProvider(catalog);
        ListApplicationsResponse page = provider.list(request(), 1);
        assertEquals("é", page.getEntries(0).getDisplayName());
        assertEquals("1.0", page.getEntries(0).getVersionName());
        assertEquals(7, page.getEntries(0).getVersionCode());
        assertTrue(page.getEntries(0).getSystemApplication());
        for (ListApplicationsRequest invalid : Arrays.asList(
                request().toBuilder().setPageSize(-1).build(),
                request().toBuilder().setPageSize(101).build(),
                request().toBuilder().setSortFieldValue(999).build(),
                request().toBuilder().setQuery("query\n").build(),
                request().toBuilder().setQuery(String.join("", Collections.nCopies(129, "a"))).build())) {
            assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, provider.list(invalid, 1).getError().getCode());
        }
        assertEquals(1, catalog.queries);
    }

    @Test public void invalidCatalogAndPlatformErrorsDoNotLeakMetadata() {
        Catalog catalog = new Catalog();
        catalog.access.setEnabled(true);
        ApplicationListProvider provider = new ApplicationListProvider(catalog);
        catalog.entries = Collections.nCopies(ApplicationListProvider.MAX_APPLICATIONS + 1,
                entry("alpha", "Alpha", 10));
        assertEquals(ErrorCode.ERROR_CODE_INTERNAL, provider.list(request(), 1).getError().getCode());
        catalog.entries = Collections.singletonList(new ApplicationCatalog.Entry(
                "../private", "invalid", "", 1, 0, false));
        assertEquals(ErrorCode.ERROR_CODE_INTERNAL, provider.list(request(), 1).getError().getCode());
        catalog.duringQuery = () -> { throw new SecurityException("provider-private-detail"); };
        ListApplicationsResponse failed = provider.list(request(), 1);
        assertEquals(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED, failed.getError().getCode());
        assertEquals(0, failed.getEntriesCount());
        assertFalse(failed.getError().getMessage().contains("provider-private-detail"));
    }

    private static void assertStale(ListApplicationsResponse response) {
        assertEquals(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, response.getError().getCode());
        assertEquals(0, response.getEntriesCount());
    }

    static ListApplicationsRequest request() {
        return ListApplicationsRequest.newBuilder().setPageSize(100)
                .setSortField(ApplicationSortField.APPLICATION_SORT_FIELD_NAME).build();
    }

    private static ApplicationCatalog.Entry entry(String suffix, String name, long updated) {
        return new ApplicationCatalog.Entry("example." + suffix, name, "1.0", updated, updated, false);
    }

    static final class Catalog implements ApplicationCatalog {
        final ApplicationAccess access = new ApplicationAccess();
        List<Entry> entries = Arrays.asList(entry("zulu", "Zulu", 30), entry("alpha", "Alpha", 10));
        Runnable duringQuery = () -> {};
        int queries;
        @Override public long accessGeneration() { return access.generation(); }
        @Override public List<Entry> queryLaunchableApplications() {
            queries++;
            duringQuery.run();
            return entries;
        }
    }
}
