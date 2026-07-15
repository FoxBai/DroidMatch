package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.m1.ProviderPathRouter.MediaTarget;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.ThumbnailRequest;
import app.droidmatch.proto.v1.ThumbnailResponse;
import com.google.protobuf.ByteString;

/** Validates and routes bounded MediaStore thumbnail requests. */
final class ProviderThumbnails {
    private final ProviderMediaCatalog mediaCatalog;

    ProviderThumbnails(ProviderMediaCatalog mediaCatalog) {
        this.mediaCatalog = mediaCatalog;
    }

    ThumbnailResponse thumbnail(ThumbnailRequest request) {
        int maxDimension = request.getMaxDimensionPx();
        if (maxDimension < 32 || maxDimension > 512) {
            return error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "max_dimension_px must be between 32 and 512");
        }
        MediaTarget target = ProviderPathRouter.mediaDownload(request.getPath());
        if (target == null) {
            String albumToken = ProviderMediaListings.albumToken(request.getPath());
            if (albumToken == null) {
                return error(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, "thumbnails are available for MediaStore entries and image albums only");
            }
            try {
                return response(mediaCatalog.thumbnailAlbum(albumToken, maxDimension));
            } catch (ProviderCatalogException exception) {
                return error(exception.code, ProviderErrorLabels.thumbnail(exception.code));
            }
        }
        if (target.error != null) {
            return error(target.error.code, ProviderErrorLabels.thumbnail(target.error.code));
        }
        try {
            return response(mediaCatalog.thumbnail(
                    target.rootKind,
                    target.mediaId,
                    maxDimension
            ));
        } catch (ProviderCatalogException exception) {
            return error(exception.code, ProviderErrorLabels.thumbnail(exception.code));
        }
    }

    private static ThumbnailResponse response(ProviderThumbnail thumbnail) {
        return ThumbnailResponse.newBuilder()
                .setEncodedImage(ByteString.copyFrom(thumbnail.encodedImage))
                .setMimeType(thumbnail.mimeType)
                .setWidthPx(thumbnail.widthPx)
                .setHeightPx(thumbnail.heightPx)
                .build();
    }

    private static ThumbnailResponse error(ErrorCode code, String message) {
        return ThumbnailResponse.newBuilder().setError(DroidMatchError.newBuilder()
                .setCode(code)
                .setMessage(message == null ? "" : message))
                .build();
    }
}
