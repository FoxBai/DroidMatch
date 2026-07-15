package app.droidmatch.m1;

import app.droidmatch.m1.ProviderPathRouter.AppSandboxTarget;
import app.droidmatch.m1.ProviderPathRouter.MediaTarget;
import app.droidmatch.m1.ProviderPathRouter.MediaUploadTarget;
import app.droidmatch.m1.ProviderPathRouter.SafTarget;
import app.droidmatch.m1.ProviderPathRouter.SafUploadTarget;
import app.droidmatch.proto.v1.ErrorCode;

/** Stateless provider selection and argument validation for transfer opens. */
final class ProviderTransfers {
    private ProviderTransfers() {}

    static DmFileProvider.DownloadReader openDownload(
            String path,
            long offsetBytes,
            int chunkSizeBytes,
            ProviderMediaCatalog mediaCatalog,
            ProviderSafCatalog safCatalog,
            ProviderAppSandboxCatalog appSandboxCatalog,
            ProviderSafDocumentCache safDocumentCache
    ) throws DmFileProvider.ProviderCatalogException {
        if (offsetBytes < 0) {
            throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "requested_offset_bytes must be non-negative");
        }
        if (chunkSizeBytes <= 0) {
            throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "chunk_size_bytes must be positive");
        }

        MediaTarget media = ProviderPathRouter.mediaDownload(path);
        if (media != null) {
            if (media.error != null) {
                throw media.error;
            }
            return mediaCatalog.openMedia(
                    media.rootKind, media.mediaId, offsetBytes, chunkSizeBytes
            );
        }
        AppSandboxTarget appSandbox = ProviderPathRouter.appSandboxFile(path);
        if (appSandbox != null) {
            if (appSandbox.downloadError != null) {
                throw appSandbox.downloadError;
            }
            return appSandboxCatalog.openFile(
                    appSandbox.relativePath, offsetBytes, chunkSizeBytes
            );
        }
        SafTarget saf = ProviderPathRouter.safDirectory(
                path, safCatalog.roots(), safDocumentCache
        );
        if (saf != null) {
            if (saf.error != null) {
                ErrorCode code = saf.error.getError().getCode();
                throw error(code, ProviderErrorLabels.transfer(code, "download"));
            }
            return safCatalog.openDocument(
                    saf.root, saf.documentId, offsetBytes, chunkSizeBytes
            );
        }
        // Do not reflect the caller's path into the protocol error. The path
        // can carry a private file name or an invalid platform URI.
        throw error(ErrorCode.ERROR_CODE_NOT_FOUND, "unknown DroidMatch provider path");
    }

    static DmFileProvider.UploadWriter openUpload(
            String path,
            String transferId,
            long offsetBytes,
            long expectedSizeBytes,
            ProviderMediaCatalog mediaCatalog,
            ProviderSafCatalog safCatalog,
            ProviderAppSandboxCatalog appSandboxCatalog,
            ProviderSafDocumentCache safDocumentCache,
            ProviderUploadLeases uploadLeases
    ) throws DmFileProvider.ProviderCatalogException {
        validateUploadOffsets(offsetBytes, expectedSizeBytes);

        AppSandboxTarget appSandbox = ProviderPathRouter.appSandboxFile(path);
        if (appSandbox != null) {
            if (appSandbox.downloadError != null) {
                throw appSandbox.downloadError;
            }
            return appSandboxCatalog.openUploadFile(
                    appSandbox.relativePath,
                    offsetBytes,
                    expectedSizeBytes,
                    uploadLeases
            );
        }
        MediaUploadTarget media = ProviderPathRouter.mediaUpload(path);
        if (media != null) {
            if (media.error != null) {
                throw media.error;
            }
            if (offsetBytes != 0) {
                throw error(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                        "MediaStore upload resume is not supported");
            }
            return uploadLeases.openLeased(
                    ProviderUploadLeases.Destination.media(media.rootKind, media.displayName),
                    () -> mediaCatalog.openUploadMedia(
                            media.rootKind,
                            media.displayName,
                            offsetBytes,
                            expectedSizeBytes
                    )
            );
        }
        SafUploadTarget saf = ProviderPathRouter.safUpload(
                path, safCatalog.roots(), safDocumentCache
        );
        if (saf != null) {
            if (saf.error != null) {
                throw error(saf.error.code, ProviderErrorLabels.transfer(saf.error.code, "upload"));
            }
            if (!saf.root.canWrite) {
                throw error(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "SAF write permission is required to upload this document");
            }
            if (offsetBytes != 0 && transferId.isEmpty()) {
                throw error(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                        "SAF upload resume requires a transfer_id");
            }
            return uploadLeases.openLeased(
                    ProviderUploadLeases.Destination.saf(
                            saf.root,
                            saf.parentDocumentId,
                            saf.displayName
                    ),
                    () -> safCatalog.openUploadDocument(
                            saf.root,
                            saf.parentDocumentId,
                            saf.displayName,
                            transferId,
                            offsetBytes,
                            expectedSizeBytes
                    )
            );
        }
        throw error(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "M1 upload currently supports dm://app-sandbox/, dm://media-images/, dm://media-videos/, and writable dm://saf-.../ destinations only"
        );
    }

    private static void validateUploadOffsets(long offsetBytes, long expectedSizeBytes)
            throws DmFileProvider.ProviderCatalogException {
        if (offsetBytes < 0) {
            throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "requested_offset_bytes must be non-negative");
        }
        if (expectedSizeBytes < -1) {
            throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "expected_size_bytes must be -1 or non-negative");
        }
        if (expectedSizeBytes >= 0 && offsetBytes > expectedSizeBytes) {
            throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "requested_offset_bytes is beyond expected_size_bytes");
        }
    }

    private static DmFileProvider.ProviderCatalogException error(
            ErrorCode code,
            String message
    ) {
        return new DmFileProvider.ProviderCatalogException(code, message);
    }
}
