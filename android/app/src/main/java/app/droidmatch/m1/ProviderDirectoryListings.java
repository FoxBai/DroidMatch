package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.AppSandboxItem;
import app.droidmatch.m1.DmFileProvider.AppSandboxPage;
import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.m1.DmFileProvider.ProviderQuery;
import app.droidmatch.m1.DmFileProvider.RootKind;
import app.droidmatch.m1.DmFileProvider.SafItem;
import app.droidmatch.m1.DmFileProvider.SafPage;
import app.droidmatch.m1.DmFileProvider.SafRoot;
import app.droidmatch.m1.ProviderPathRouter.AppSandboxTarget;
import app.droidmatch.m1.ProviderPathRouter.SafTarget;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileEntry;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;
import app.droidmatch.proto.v1.SortField;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/** Owns directory query dispatch and response assembly, but no transfer or mutation state. */
final class ProviderDirectoryListings {
    private static final StaticRoot[] STATIC_ROOTS = new StaticRoot[] {
            new StaticRoot("Images", DmFileProvider.MEDIA_IMAGES_PATH, RootKind.MEDIA_IMAGES),
            new StaticRoot("Image Albums", DmFileProvider.MEDIA_IMAGE_ALBUMS_PATH, RootKind.MEDIA_IMAGE_ALBUMS),
            new StaticRoot("Videos", DmFileProvider.MEDIA_VIDEOS_PATH, RootKind.MEDIA_VIDEOS),
            new StaticRoot("App Sandbox", DmFileProvider.APP_SANDBOX_PATH, RootKind.APP_SANDBOX)
    };

    private ProviderDirectoryListings() {}

    static String[] listRoots(ProviderSafCatalog safCatalog) {
        List<SafRoot> safRoots = safCatalog.roots();
        String[] paths = new String[STATIC_ROOTS.length + safRoots.size()];
        int index = 0;
        for (StaticRoot root : STATIC_ROOTS) paths[index++] = root.path;
        for (SafRoot root : safRoots) paths[index++] = root.path();
        return paths;
    }

    static ListDirResponse list(
            ListDirRequest request,
            ProviderMediaCatalog mediaCatalog,
            ProviderSafCatalog safCatalog,
            ProviderAppSandboxCatalog appSandboxCatalog,
            ProviderSafDocumentCache safDocumentCache
    ) {
        if (request.getSearchQuery().length() > 256) {
            return error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "search_query exceeds 256 characters");
        }
        if (DmFileProvider.ROOTS_PATH.equals(request.getPath())) {
            return listRootDirectory(request, mediaCatalog, safCatalog);
        }
        AppSandboxTarget appTarget = ProviderPathRouter.appSandboxDirectory(request.getPath());
        if (appTarget != null) {
            return appTarget.error != null
                    ? appTarget.error
                    : listAppSandboxDirectory(appTarget.relativePath, request, appSandboxCatalog);
        }
        StaticRoot staticRoot = staticRootForPath(request.getPath());
        if (staticRoot != null) {
            return ProviderMediaListings.list(mediaCatalog, staticRoot.kind, staticRoot.path, request);
        }
        if (ProviderMediaListings.isAlbumDirectory(request.getPath())) {
            return ProviderMediaListings.listAlbum(mediaCatalog, request);
        }
        SafTarget safTarget = ProviderPathRouter.safDirectory(
                request.getPath(), safCatalog.roots(), safDocumentCache
        );
        if (safTarget != null) {
            return safTarget.error != null
                    ? safTarget.error
                    : listSafDirectory(safTarget, request, safCatalog, safDocumentCache);
        }
        // The path is caller-controlled and may contain a private file name,
        // an absolute host path, or an accidentally supplied content URI.
        // Keep the wire error useful without echoing that value.
        return error(ErrorCode.ERROR_CODE_NOT_FOUND, "unknown DroidMatch provider path");
    }

    private static ListDirResponse listRootDirectory(
            ListDirRequest request,
            ProviderMediaCatalog mediaCatalog,
            ProviderSafCatalog safCatalog
    ) {
        ArrayList<RootListingEntry> roots = rootListingEntries(mediaCatalog, safCatalog);
        String snapshotIdentity = rootSnapshotIdentity(roots);
        ProviderPagePolicy.PageRequest page = ProviderPagePolicy.parse(
                request, snapshotIdentity
        );
        if (page.error != null) return page.error;
        roots.removeIf(root -> !ProviderNameSearch.matches(
                root.entry.getName(), request.getSearchQuery()
        ));
        roots.sort(rootComparator(request));

        ListDirResponse.Builder response = ListDirResponse.newBuilder();
        int start = Math.min(page.offset, roots.size());
        int end = Math.min(page.offset + page.limit, roots.size());
        for (int index = start; index < end; index++) {
            response.addEntries(roots.get(index).entry);
        }
        return ProviderPagePolicy.finishResponse(
                response, request, page, end < roots.size(), snapshotIdentity
        );
    }

    private static ArrayList<RootListingEntry> rootListingEntries(
            ProviderMediaCatalog mediaCatalog,
            ProviderSafCatalog safCatalog
    ) {
        ArrayList<RootListingEntry> roots = new ArrayList<>();
        int sourceOrder = 0;
        for (StaticRoot root : STATIC_ROOTS) {
            roots.add(new RootListingEntry(rootEntry(
                    root.path,
                    root.displayName,
                    rootCanRead(root, mediaCatalog),
                    rootCanWrite(root, mediaCatalog)
            ), sourceOrder++));
        }
        ArrayList<SafRoot> safRoots = new ArrayList<>(safCatalog.roots());
        safRoots.sort(Comparator
                .comparing((SafRoot root) -> root.displayName, String.CASE_INSENSITIVE_ORDER)
                .thenComparing(SafRoot::path));
        for (SafRoot root : safRoots) {
            roots.add(new RootListingEntry(rootEntry(
                    root.path(), root.displayName, true, root.canWrite
            ), sourceOrder++));
        }
        return roots;
    }

    private static Comparator<RootListingEntry> rootComparator(ListDirRequest request) {
        Comparator<RootListingEntry> comparator;
        SortField field = ProviderPagePolicy.effectiveSortField(request.getSortField());
        switch (field) {
            case SORT_FIELD_NAME:
                comparator = Comparator.comparing(
                        value -> value.entry.getName(), String.CASE_INSENSITIVE_ORDER
                );
                break;
            case SORT_FIELD_SIZE:
                comparator = Comparator.comparingLong(value -> value.entry.getSizeBytes());
                break;
            case SORT_FIELD_KIND:
                comparator = Comparator.comparingInt(value -> value.entry.getKindValue());
                break;
            case SORT_FIELD_MODIFIED_TIME:
            case SORT_FIELD_UNSPECIFIED:
            case UNRECOGNIZED:
            default:
                comparator = Comparator.comparingLong(
                        value -> value.entry.getModifiedUnixMillis()
                );
                break;
        }
        if (ProviderPagePolicy.effectiveDescending(
                request.getSortField(), request.getDescending()
        )) {
            comparator = comparator.reversed();
        }
        return comparator.thenComparingInt(value -> value.sourceOrder);
    }

    private static String rootSnapshotIdentity(List<RootListingEntry> roots) {
        StringBuilder material = new StringBuilder("root-snapshot-v1\n");
        for (RootListingEntry root : roots) {
            appendSnapshotField(material, root.entry.getPath());
            appendSnapshotField(material, root.entry.getName());
            material.append(root.entry.getCanRead() ? '1' : '0');
            material.append(root.entry.getCanWrite() ? '1' : '0').append('\n');
        }
        return ProviderOpaqueIds.stable(material.toString(), 16);
    }

    private static void appendSnapshotField(StringBuilder material, String value) {
        material.append(value.length()).append(':').append(value).append('\n');
    }

    private static boolean rootCanRead(StaticRoot root, ProviderMediaCatalog mediaCatalog) {
        if (root.kind == RootKind.APP_SANDBOX) return true;
        if (root.kind == RootKind.MEDIA_IMAGE_ALBUMS) {
            return mediaCatalog.canReadMedia(RootKind.MEDIA_IMAGES);
        }
        return mediaCatalog.canReadMedia(root.kind);
    }

    private static boolean rootCanWrite(StaticRoot root, ProviderMediaCatalog mediaCatalog) {
        if (root.kind == RootKind.APP_SANDBOX) return true;
        if (root.kind == RootKind.MEDIA_IMAGE_ALBUMS) return false;
        return mediaCatalog.canUploadMedia(root.kind);
    }

    private static FileEntry rootEntry(
            String path,
            String displayName,
            boolean canRead,
            boolean canWrite
    ) {
        return FileEntry.newBuilder()
                .setPath(path).setName(displayName).setKind(FileKind.FILE_KIND_VIRTUAL)
                .setCanRead(canRead).setCanWrite(canWrite).setMimeType("vnd.droidmatch.root")
                .build();
    }

    private static ListDirResponse listAppSandboxDirectory(
            String relativePath,
            ListDirRequest request,
            ProviderAppSandboxCatalog catalog
    ) {
        ProviderPagePolicy.PageRequest page = ProviderPagePolicy.parse(request);
        if (page.error != null) return page.error;
        try {
            AppSandboxPage result = catalog.listDirectory(relativePath, query(request, page));
            ListDirResponse.Builder response = ListDirResponse.newBuilder();
            for (AppSandboxItem item : result.items()) {
                response.addEntries(FileEntry.newBuilder()
                        .setPath(DmFileProvider.APP_SANDBOX_PATH + item.relativePath
                                + (item.kind == FileKind.FILE_KIND_DIRECTORY ? "/" : ""))
                        .setName(item.displayName).setKind(item.kind).setSizeBytes(item.sizeBytes)
                        .setModifiedUnixMillis(item.modifiedUnixMillis).setCanRead(true)
                        .setCanWrite(item.canWrite).setMimeType(item.mimeType).build());
            }
            return ProviderPagePolicy.finishResponse(
                    response, request, page, result.hasMore()
            );
        } catch (ProviderCatalogException exception) {
            return error(
                    exception.code,
                    ProviderErrorLabels.listing(exception.code, "app sandbox")
            );
        }
    }

    private static ListDirResponse listSafDirectory(
            SafTarget target,
            ListDirRequest request,
            ProviderSafCatalog catalog,
            ProviderSafDocumentCache safDocumentCache
    ) {
        ProviderPagePolicy.PageRequest page = ProviderPagePolicy.parse(request);
        if (page.error != null) return page.error;
        try {
            SafPage result = catalog.listChildren(target.root, target.documentId, query(request, page));
            ListDirResponse.Builder response = ListDirResponse.newBuilder();
            for (SafItem item : result.items()) {
                response.addEntries(FileEntry.newBuilder()
                        .setPath(target.root.path() + ProviderPathRouter.SAF_DOCUMENT_PREFIX
                                + safDocumentCache.remember(
                                        target.root,
                                        target.documentId,
                                        item.documentId
                                ))
                        .setName(item.displayName).setKind(item.kind).setSizeBytes(item.sizeBytes)
                        .setModifiedUnixMillis(item.modifiedUnixMillis).setCanRead(true)
                        .setCanWrite(item.canWrite).setMimeType(item.mimeType).build());
            }
            return ProviderPagePolicy.finishResponse(
                    response, request, page, result.hasMore()
            );
        } catch (ProviderCatalogException exception) {
            return error(
                    exception.code,
                    ProviderErrorLabels.listing(exception.code, "SAF")
            );
        }
    }

    private static ProviderQuery query(ListDirRequest request, ProviderPagePolicy.PageRequest page) {
        return new ProviderQuery(
                page.offset, page.limit,
                ProviderPagePolicy.effectiveSortField(request.getSortField()),
                ProviderPagePolicy.effectiveDescending(request.getSortField(), request.getDescending()),
                request.getSearchQuery()
        );
    }

    private static StaticRoot staticRootForPath(String path) {
        for (StaticRoot root : STATIC_ROOTS) if (root.path.equals(path)) return root;
        return null;
    }

    private static ListDirResponse error(ErrorCode code, String message) {
        return ListDirResponse.newBuilder()
                .setError(DroidMatchError.newBuilder().setCode(code).setMessage(message).build())
                .build();
    }

    private static final class StaticRoot {
        final String displayName;
        final String path;
        final RootKind kind;

        StaticRoot(String displayName, String path, RootKind kind) {
            this.displayName = displayName;
            this.path = path;
            this.kind = kind;
        }
    }

    private static final class RootListingEntry {
        final FileEntry entry;
        final int sourceOrder;

        RootListingEntry(FileEntry entry, int sourceOrder) {
            this.entry = entry;
            this.sourceOrder = sourceOrder;
        }
    }
}
