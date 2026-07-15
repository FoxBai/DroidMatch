package app.droidmatch.m1;

import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileEntry;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.ListDirRequest;
import app.droidmatch.proto.v1.ListDirResponse;

/** Builds logical media and album listings without owning Android queries. */
final class ProviderMediaListings {
    static final String IMAGE_ALBUMS_PATH = DmFileProvider.MEDIA_IMAGES_PATH + "albums/";

    private ProviderMediaListings() {}

    static boolean isAlbumDirectory(String path) {
        return albumToken(path) != null;
    }

    static String albumToken(String path) {
        if (!path.startsWith(IMAGE_ALBUMS_PATH) || !path.endsWith("/")) return null;
        String token = path.substring(IMAGE_ALBUMS_PATH.length(), path.length() - 1);
        if (token.length() != 24) return null;
        for (int index = 0; index < token.length(); index++) {
            char value = token.charAt(index);
            if ((value < '0' || value > '9') && (value < 'a' || value > 'f')) return null;
        }
        return token;
    }

    static ListDirResponse list(
            ProviderMediaCatalog catalog,
            DmFileProvider.RootKind rootKind,
            String rootPath,
            ListDirRequest request
    ) {
        ProviderPagePolicy.PageRequest page = ProviderPagePolicy.parse(request);
        if (page.error != null) return page.error;
        DmFileProvider.ProviderQuery query = query(request, page);
        try {
            if (rootKind == DmFileProvider.RootKind.MEDIA_IMAGE_ALBUMS) {
                return albums(catalog.listAlbums(query), request, page);
            }
            return media(catalog.listMedia(rootKind, query), rootPath, request, page);
        } catch (DmFileProvider.ProviderCatalogException exception) {
            return error(exception.code, ProviderErrorLabels.listing(exception.code, "media"));
        }
    }

    static ListDirResponse listAlbum(
            ProviderMediaCatalog catalog,
            ListDirRequest request
    ) {
        ProviderPagePolicy.PageRequest page = ProviderPagePolicy.parse(request);
        if (page.error != null) return page.error;
        String token = albumToken(request.getPath());
        try {
            return media(
                    catalog.listMediaInAlbum(token, query(request, page)),
                    DmFileProvider.MEDIA_IMAGES_PATH,
                    request,
                    page
            );
        } catch (DmFileProvider.ProviderCatalogException exception) {
            return error(exception.code, ProviderErrorLabels.listing(exception.code, "media"));
        }
    }

    private static ListDirResponse albums(
            ProviderAlbumPage albumPage,
            ListDirRequest request,
            ProviderPagePolicy.PageRequest page
    ) {
        ListDirResponse.Builder response = ListDirResponse.newBuilder();
        for (ProviderAlbum album : albumPage.items) {
            response.addEntries(FileEntry.newBuilder()
                    .setPath(IMAGE_ALBUMS_PATH + album.token + "/")
                    .setName(album.displayName)
                    .setKind(FileKind.FILE_KIND_DIRECTORY)
                    .setModifiedUnixMillis(album.modifiedUnixMillis)
                    .setCanRead(true)
                    .setCanWrite(false)
                    .setMimeType("vnd.droidmatch.media-album")
                    .build());
        }
        if (albumPage.hasMore) response.setNextPageToken(ProviderPagePolicy.nextToken(request, page));
        return response.build();
    }

    private static ListDirResponse media(
            DmFileProvider.MediaPage mediaPage,
            String rootPath,
            ListDirRequest request,
            ProviderPagePolicy.PageRequest page
    ) {
        ListDirResponse.Builder response = ListDirResponse.newBuilder();
        for (DmFileProvider.MediaItem item : mediaPage.items) {
            response.addEntries(FileEntry.newBuilder()
                    .setPath(rootPath + "media/" + item.id)
                    .setName(item.displayName)
                    .setKind(FileKind.FILE_KIND_FILE)
                    .setSizeBytes(item.sizeBytes)
                    .setModifiedUnixMillis(item.modifiedUnixMillis)
                    .setCanRead(true)
                    .setCanWrite(false)
                    .setMimeType(item.mimeType)
                    .build());
        }
        if (mediaPage.hasMore) response.setNextPageToken(ProviderPagePolicy.nextToken(request, page));
        return response.build();
    }

    private static DmFileProvider.ProviderQuery query(
            ListDirRequest request,
            ProviderPagePolicy.PageRequest page
    ) {
        return new DmFileProvider.ProviderQuery(
                page.offset,
                page.limit,
                ProviderPagePolicy.effectiveSortField(request.getSortField()),
                ProviderPagePolicy.effectiveDescending(request.getSortField(), request.getDescending()),
                request.getSearchQuery()
        );
    }

    private static ListDirResponse error(ErrorCode code, String message) {
        return ListDirResponse.newBuilder().setError(
                DroidMatchError.newBuilder().setCode(code).setMessage(message).build()
        ).build();
    }
}
