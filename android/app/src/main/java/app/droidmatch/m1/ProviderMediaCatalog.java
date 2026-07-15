package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.DownloadChunk;
import app.droidmatch.m1.DmFileProvider.DownloadReader;
import app.droidmatch.m1.DmFileProvider.MediaPage;
import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.m1.DmFileProvider.ProviderQuery;
import app.droidmatch.m1.DmFileProvider.RootKind;
import app.droidmatch.m1.DmFileProvider.UploadWriter;
import app.droidmatch.proto.v1.ErrorCode;

import java.util.ArrayList;

/**
 * MediaStore-facing storage port. Platform I/O stays in the Android catalog;
 * the provider facade only composes this contract.
 * 中文：面向 MediaStore 的存储端口；平台 I/O 仍由 Android catalog 独占，facade 只负责组装。
 */
interface ProviderMediaCatalog {
    MediaPage listMedia(RootKind rootKind, ProviderQuery query) throws ProviderCatalogException;

    default boolean canReadMedia(RootKind rootKind) {
        return false;
    }

    default ProviderAlbumPage listAlbums(ProviderQuery query) throws ProviderCatalogException {
        throw new ProviderCatalogException(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "MediaStore albums are not available"
        );
    }

    default MediaPage listMediaInAlbum(String albumToken, ProviderQuery query)
            throws ProviderCatalogException {
        throw new ProviderCatalogException(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "MediaStore albums are not available"
        );
    }

    DownloadChunk readMedia(RootKind rootKind, long mediaId, long offsetBytes, int chunkSizeBytes)
            throws ProviderCatalogException;

    default boolean canUploadMedia(RootKind rootKind) {
        return false;
    }

    default DownloadReader openMedia(RootKind rootKind, long mediaId, long offsetBytes, int chunkSizeBytes)
            throws ProviderCatalogException {
        return ProviderDownloadReaders.oneShot(
                readMedia(rootKind, mediaId, offsetBytes, chunkSizeBytes)
        );
    }

    default UploadWriter openUploadMedia(
            RootKind rootKind,
            String displayName,
            long offsetBytes,
            long expectedSizeBytes
    ) throws ProviderCatalogException {
        throw new ProviderCatalogException(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "MediaStore upload is not available"
        );
    }

    default ProviderThumbnail thumbnail(RootKind rootKind, long mediaId, int maxDimensionPx)
            throws ProviderCatalogException {
        throw new ProviderCatalogException(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "MediaStore thumbnail is not available"
        );
    }

    default ProviderThumbnail thumbnailAlbum(String albumToken, int maxDimensionPx)
            throws ProviderCatalogException {
        throw new ProviderCatalogException(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "MediaStore album thumbnails are not available"
        );
    }

    static ProviderMediaCatalog empty() {
        return new ProviderMediaCatalog() {
            @Override
            public MediaPage listMedia(RootKind rootKind, ProviderQuery query) {
                return new MediaPage(new ArrayList<>(), false);
            }

            @Override
            public DownloadChunk readMedia(
                    RootKind rootKind,
                    long mediaId,
                    long offsetBytes,
                    int chunkSizeBytes
            ) throws ProviderCatalogException {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "media entry is not available"
                );
            }
        };
    }
}
