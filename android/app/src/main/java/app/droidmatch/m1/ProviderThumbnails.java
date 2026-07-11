package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.MediaCatalog;
import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.m1.ProviderPathRouter.MediaTarget;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.ThumbnailRequest;
import app.droidmatch.proto.v1.ThumbnailResponse;
import com.google.protobuf.ByteString;

/** Validates and routes bounded MediaStore thumbnail requests. */
final class ProviderThumbnails {
    private final MediaCatalog mediaCatalog;

    ProviderThumbnails(MediaCatalog mediaCatalog) {
        this.mediaCatalog = mediaCatalog;
    }

    ThumbnailResponse thumbnail(ThumbnailRequest request) {
        int maxDimension = request.getMaxDimensionPx();
        if (maxDimension < 32 || maxDimension > 512) {
            return error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "max_dimension_px must be between 32 and 512");
        }
        MediaTarget target = ProviderPathRouter.mediaDownload(request.getPath());
        if (target == null) {
            return error(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, "thumbnails are available for MediaStore entries only");
        }
        if (target.error != null) {
            return error(target.error.code, target.error.getMessage());
        }
        try {
            ProviderThumbnail thumbnail = mediaCatalog.thumbnail(
                    target.rootKind,
                    target.mediaId,
                    maxDimension
            );
            return ThumbnailResponse.newBuilder()
                    .setEncodedImage(ByteString.copyFrom(thumbnail.encodedImage))
                    .setMimeType(thumbnail.mimeType)
                    .setWidthPx(thumbnail.widthPx)
                    .setHeightPx(thumbnail.heightPx)
                    .build();
        } catch (ProviderCatalogException exception) {
            return error(exception.code, exception.getMessage());
        }
    }

    private static ThumbnailResponse error(ErrorCode code, String message) {
        return ThumbnailResponse.newBuilder().setError(DroidMatchError.newBuilder()
                .setCode(code)
                .setMessage(message == null ? "" : message))
                .build();
    }
}
