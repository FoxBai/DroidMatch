package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.SafRoot;
import app.droidmatch.m1.ProviderPathRouter.AppSandboxTarget;
import app.droidmatch.m1.ProviderPathRouter.MediaTarget;
import app.droidmatch.m1.ProviderPathRouter.MediaUploadTarget;
import app.droidmatch.m1.ProviderPathRouter.SafTarget;
import app.droidmatch.m1.ProviderPathRouter.SafUploadTarget;
import app.droidmatch.proto.v1.ErrorCode;

import java.util.List;

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
        final List<SafRoot> safRoots = ProviderSafCatalog.snapshotRoots(safCatalog);
        SafTarget saf = ProviderPathRouter.safDirectory(
                path, safRoots, safDocumentCache
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
            ProviderPathCoordinator pathCoordinator
    ) throws DmFileProvider.ProviderCatalogException {
        validateUploadOffsets(offsetBytes, expectedSizeBytes);

        AppSandboxTarget appSandbox = ProviderPathRouter.appSandboxUploadFile(path);
        if (appSandbox != null) {
            if (appSandbox.downloadError != null) {
                throw appSandbox.downloadError;
            }
            if (offsetBytes != 0 && transferId.isEmpty()) {
                throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "app sandbox upload resume requires a transfer_id");
            }
            return pathCoordinator.openLeased(
                    ProviderPathCoordinator.Claim.appSandbox(appSandbox.relativePath),
                    () -> appSandboxCatalog.openUploadFile(
                            appSandbox.relativePath,
                            transferId,
                            offsetBytes,
                            expectedSizeBytes
                    )
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
            if (ProviderMimeTypes.mediaTypeFor(media.rootKind, media.displayName) == null) {
                throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "media upload file type does not match destination");
            }
            if (!mediaCatalog.canUploadMedia(media.rootKind)) {
                throw error(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                        "MediaStore upload is not available on this device");
            }
            return pathCoordinator.openLeased(
                    ProviderPathCoordinator.Claim.media(media.rootKind, media.displayName),
                    () -> mediaCatalog.openUploadMedia(
                            media.rootKind,
                            media.displayName,
                            offsetBytes,
                            expectedSizeBytes
                    )
            );
        }
        final List<SafRoot> safRoots = ProviderSafCatalog.snapshotRoots(safCatalog);
        SafUploadTarget saf = ProviderPathRouter.safUpload(
                path, safRoots, safDocumentCache
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
            return pathCoordinator.openLeased(
                    ProviderPathCoordinator.Claim.safChild(
                            saf.root,
                            saf.rootsSnapshot,
                            saf.parentDocumentId,
                            saf.displayName,
                            safDocumentCache.ancestorDocumentIds(
                                    saf.root,
                                    saf.parentDocumentId
                            )
                    ),
                    () -> {
                        try {
                            DmFileProvider.UploadWriter delegate =
                                    safCatalog.openUploadDocument(
                                            saf.root,
                                            saf.parentDocumentId,
                                            saf.displayName,
                                            transferId,
                                            offsetBytes,
                                            expectedSizeBytes
                                    );
                            if (delegate == null) {
                                return null;
                            }
                            return mutationAwareSafUpload(
                                    delegate,
                                    saf.root,
                                    saf.parentDocumentId,
                                    saf.displayName,
                                    safDocumentCache
                            );
                        } finally {
                            // Open may create, truncate, or clean up a document
                            // before either returning or failing.
                            safDocumentCache.invalidateChildAfterMutation(
                                    saf.root,
                                    saf.parentDocumentId,
                                    saf.displayName
                            );
                        }
                    }
            );
        }
        throw error(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "M1 upload currently supports dm://app-sandbox/, dm://media-images/, dm://media-videos/, and writable dm://saf-.../ destinations only"
        );
    }

    static void discardUploadPartial(
            String path,
            String transferId,
            long expectedSizeBytes,
            ProviderSafCatalog safCatalog,
            ProviderAppSandboxCatalog appSandboxCatalog,
            ProviderSafDocumentCache safDocumentCache,
            ProviderPathCoordinator pathCoordinator
    ) throws DmFileProvider.ProviderCatalogException {
        if (transferId.isEmpty()) {
            throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "transfer_id must be non-empty");
        }
        if (expectedSizeBytes < 0) {
            throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "expected_size_bytes must be non-negative");
        }

        AppSandboxTarget appSandbox = ProviderPathRouter.appSandboxUploadFile(path);
        if (appSandbox != null) {
            if (appSandbox.downloadError != null) {
                throw appSandbox.downloadError;
            }
            pathCoordinator.runLeased(
                    ProviderPathCoordinator.Claim.appSandbox(appSandbox.relativePath),
                    () -> appSandboxCatalog.discardUploadPartial(
                            appSandbox.relativePath,
                            transferId,
                            expectedSizeBytes
                    )
            );
            return;
        }

        final List<SafRoot> safRoots = ProviderSafCatalog.snapshotRoots(safCatalog);
        SafUploadTarget saf = ProviderPathRouter.safUpload(
                path,
                safRoots,
                safDocumentCache
        );
        if (saf != null) {
            if (saf.error != null) {
                throw error(saf.error.code, ProviderErrorLabels.transfer(saf.error.code, "upload"));
            }
            if (!saf.root.canWrite) {
                throw error(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                        "SAF write permission is required to discard the upload partial");
            }
            pathCoordinator.runLeased(
                    ProviderPathCoordinator.Claim.safChild(
                            saf.root,
                            saf.rootsSnapshot,
                            saf.parentDocumentId,
                            saf.displayName,
                            safDocumentCache.ancestorDocumentIds(
                                    saf.root,
                                    saf.parentDocumentId
                            )
                    ),
                    () -> {
                        try {
                            safCatalog.discardUploadPartial(
                                    saf.root,
                                    saf.parentDocumentId,
                                    saf.displayName,
                                    transferId,
                                    expectedSizeBytes
                            );
                        } finally {
                            safDocumentCache.invalidateChildAfterMutation(
                                    saf.root,
                                    saf.parentDocumentId,
                                    saf.displayName
                            );
                        }
                    }
            );
            return;
        }

        throw error(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "upload partial cleanup supports resumable app-sandbox and SAF destinations only"
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

    private static DmFileProvider.UploadWriter mutationAwareSafUpload(
            DmFileProvider.UploadWriter delegate,
            SafRoot root,
            String parentDocumentId,
            String displayName,
            ProviderSafDocumentCache safDocumentCache
    ) {
        return new DmFileProvider.UploadWriter() {
            @Override
            public long nextOffsetBytes() {
                return delegate.nextOffsetBytes();
            }

            @Override
            public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
                    throws DmFileProvider.ProviderCatalogException {
                try {
                    delegate.writeChunk(offsetBytes, data, finalChunk);
                } finally {
                    if (finalChunk) {
                        // Reject any directory page captured before publication,
                        // including a failed provider-side rename attempt.
                        safDocumentCache.invalidateChildAfterMutation(
                                root,
                                parentDocumentId,
                                displayName
                        );
                    }
                }
            }

            @Override
            public void close() {
                try {
                    delegate.close();
                } finally {
                    // A non-final close can delete a fresh upload document.
                    safDocumentCache.invalidateChildAfterMutation(
                            root,
                            parentDocumentId,
                            displayName
                    );
                }
            }
        };
    }

    private static DmFileProvider.ProviderCatalogException error(
            ErrorCode code,
            String message
    ) {
        return new DmFileProvider.ProviderCatalogException(code, message);
    }
}
