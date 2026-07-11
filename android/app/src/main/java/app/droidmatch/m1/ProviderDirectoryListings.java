package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.AppSandboxCatalog;
import app.droidmatch.m1.DmFileProvider.AppSandboxItem;
import app.droidmatch.m1.DmFileProvider.AppSandboxPage;
import app.droidmatch.m1.DmFileProvider.MediaCatalog;
import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.m1.DmFileProvider.ProviderQuery;
import app.droidmatch.m1.DmFileProvider.RootKind;
import app.droidmatch.m1.DmFileProvider.SafCatalog;
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

import java.util.List;
import java.util.Map;

/** Owns directory query dispatch and response assembly, but no transfer or mutation state. */
final class ProviderDirectoryListings {
    private static final StaticRoot[] STATIC_ROOTS = new StaticRoot[] {
            new StaticRoot("Images", DmFileProvider.MEDIA_IMAGES_PATH, RootKind.MEDIA_IMAGES),
            new StaticRoot("Image Albums", DmFileProvider.MEDIA_IMAGE_ALBUMS_PATH, RootKind.MEDIA_IMAGE_ALBUMS),
            new StaticRoot("Videos", DmFileProvider.MEDIA_VIDEOS_PATH, RootKind.MEDIA_VIDEOS),
            new StaticRoot("App Sandbox", DmFileProvider.APP_SANDBOX_PATH, RootKind.APP_SANDBOX)
    };

    private ProviderDirectoryListings() {}

    static String[] listRoots(SafCatalog safCatalog) {
        List<SafRoot> safRoots = safCatalog.roots();
        String[] paths = new String[STATIC_ROOTS.length + safRoots.size()];
        int index = 0;
        for (StaticRoot root : STATIC_ROOTS) paths[index++] = root.path;
        for (SafRoot root : safRoots) paths[index++] = root.path();
        return paths;
    }

    static ListDirResponse list(
            ListDirRequest request,
            MediaCatalog mediaCatalog,
            SafCatalog safCatalog,
            AppSandboxCatalog appSandboxCatalog,
            Map<String, String> safDocumentIdsByLogicalId
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
                request.getPath(), safCatalog.roots(), safDocumentIdsByLogicalId
        );
        if (safTarget != null) {
            return safTarget.error != null
                    ? safTarget.error
                    : listSafDirectory(safTarget, request, safCatalog, safDocumentIdsByLogicalId);
        }
        return error(ErrorCode.ERROR_CODE_NOT_FOUND,
                "unknown DroidMatch provider path: " + request.getPath());
    }

    private static ListDirResponse listRootDirectory(
            ListDirRequest request, MediaCatalog mediaCatalog, SafCatalog safCatalog
    ) {
        if (!request.getPageToken().isEmpty()) {
            return error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "page_token is not supported by the M1 root provider");
        }
        ListDirResponse.Builder response = ListDirResponse.newBuilder();
        for (StaticRoot root : STATIC_ROOTS) {
            if (ProviderNameSearch.matches(root.displayName, request.getSearchQuery())) {
                response.addEntries(rootEntry(root.path, root.displayName, rootCanWrite(root, mediaCatalog)));
            }
        }
        for (SafRoot root : safCatalog.roots()) {
            if (ProviderNameSearch.matches(root.displayName, request.getSearchQuery())) {
                response.addEntries(rootEntry(root.path(), root.displayName, root.canWrite));
            }
        }
        return response.build();
    }

    private static boolean rootCanWrite(StaticRoot root, MediaCatalog mediaCatalog) {
        if (root.kind == RootKind.APP_SANDBOX) return true;
        if (root.kind == RootKind.MEDIA_IMAGE_ALBUMS) return false;
        return mediaCatalog.canUploadMedia(root.kind);
    }

    private static FileEntry rootEntry(String path, String displayName, boolean canWrite) {
        return FileEntry.newBuilder()
                .setPath(path).setName(displayName).setKind(FileKind.FILE_KIND_VIRTUAL)
                .setCanRead(true).setCanWrite(canWrite).setMimeType("vnd.droidmatch.root")
                .build();
    }

    private static ListDirResponse listAppSandboxDirectory(
            String relativePath, ListDirRequest request, AppSandboxCatalog catalog
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
            if (result.hasMore()) response.setNextPageToken(ProviderPagePolicy.nextToken(request, page));
            return response.build();
        } catch (ProviderCatalogException exception) {
            return error(exception.code, exception.getMessage());
        }
    }

    private static ListDirResponse listSafDirectory(
            SafTarget target, ListDirRequest request, SafCatalog catalog,
            Map<String, String> safDocumentIdsByLogicalId
    ) {
        ProviderPagePolicy.PageRequest page = ProviderPagePolicy.parse(request);
        if (page.error != null) return page.error;
        try {
            SafPage result = catalog.listChildren(target.root, target.documentId, query(request, page));
            ListDirResponse.Builder response = ListDirResponse.newBuilder();
            for (SafItem item : result.items()) {
                response.addEntries(FileEntry.newBuilder()
                        .setPath(target.root.path() + ProviderPathRouter.SAF_DOCUMENT_PREFIX
                                + ProviderPathRouter.cacheSafDocumentId(
                                        safDocumentIdsByLogicalId, target.root, item.documentId))
                        .setName(item.displayName).setKind(item.kind).setSizeBytes(item.sizeBytes)
                        .setModifiedUnixMillis(item.modifiedUnixMillis).setCanRead(true)
                        .setCanWrite(item.canWrite).setMimeType(item.mimeType).build());
            }
            if (result.hasMore()) response.setNextPageToken(ProviderPagePolicy.nextToken(request, page));
            return response.build();
        } catch (ProviderCatalogException exception) {
            return error(exception.code, exception.getMessage());
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
}
