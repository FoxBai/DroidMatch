package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.m1.DmFileProvider.SafRoot;
import app.droidmatch.m1.ProviderPathRouter.SafTarget;
import app.droidmatch.m1.ProviderPathRouter.SafUploadTarget;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.FileMutationResponse;

import java.util.Arrays;
import java.util.List;

/** Owns provider-aware create/rename policy outside the listing facade. */
final class ProviderMutations {
    private final ProviderSafCatalog safCatalog;
    private final ProviderAppSandboxCatalog appSandboxCatalog;
    private final ProviderSafDocumentCache safDocumentCache;
    private final ProviderPathCoordinator pathCoordinator;

    ProviderMutations(
            ProviderSafCatalog safCatalog,
            ProviderAppSandboxCatalog appSandboxCatalog,
            ProviderSafDocumentCache safDocumentCache,
            ProviderPathCoordinator pathCoordinator
    ) {
        this.safCatalog = safCatalog;
        this.appSandboxCatalog = appSandboxCatalog;
        this.safDocumentCache = safDocumentCache;
        this.pathCoordinator = pathCoordinator;
    }

    FileMutationResponse createDirectory(String path) {
        if (path == null || !path.endsWith("/")) {
            return error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "directory path must end with /");
        }
        if (path.startsWith(DmFileProvider.APP_SANDBOX_PATH)) {
            String relative = appRelative(path, true);
            if (relative == null) {
                return error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "malformed app sandbox directory path");
            }
            if (relative.isEmpty()) {
                return error(ErrorCode.ERROR_CODE_ALREADY_EXISTS, "app sandbox root already exists");
            }
            try {
                pathCoordinator.runLeased(
                        ProviderPathCoordinator.Claim.appSandbox(relative),
                        () -> appSandboxCatalog.createDirectory(relative)
                );
                return ok();
            } catch (ProviderCatalogException exception) {
                return error(
                        exception.code,
                        ProviderErrorLabels.mutation(exception.code, "app sandbox")
                );
            }
        }

        final List<SafRoot> safRoots = ProviderSafCatalog.snapshotRoots(safCatalog);
        SafUploadTarget target = ProviderPathRouter.safCreateDirectory(
                path, safRoots, safDocumentCache
        );
        if (target != null) {
            if (target.error != null) {
                return error(
                        target.error.code,
                        ProviderErrorLabels.mutation(target.error.code, "SAF")
                );
            }
            try {
                pathCoordinator.runLeased(
                        safChildClaim(target),
                        () -> {
                            ProviderSafCatalog.MutationIdentity created;
                            try {
                                created = safCatalog.createDirectory(
                                        target.root,
                                        target.parentDocumentId,
                                        target.displayName
                                );
                            } catch (ProviderCatalogException exception) {
                                safDocumentCache.invalidateAfterUncertainMutation(
                                        target.root
                                );
                                throw exception;
                            } catch (RuntimeException exception) {
                                safDocumentCache.invalidateAfterUncertainMutation(
                                        target.root
                                );
                                throw internal("SAF directory creation failed");
                            }
                            if (created == null
                                    || created.documentId == null
                                    || created.documentId.isEmpty()
                                    || !target.displayName.equals(created.displayName)
                                    || created.kind != FileKind.FILE_KIND_DIRECTORY) {
                                safDocumentCache.invalidateAfterUncertainMutation(
                                        target.root
                                );
                                throw internal(
                                        "SAF provider did not create the exact requested directory"
                                );
                            }
                            safDocumentCache.invalidateChildAfterMutation(
                                    target.root,
                                    target.parentDocumentId,
                                    target.displayName
                            );
                        }
                );
                return ok();
            } catch (ProviderCatalogException exception) {
                return error(
                        exception.code,
                        ProviderErrorLabels.mutation(exception.code, "SAF")
                );
            }
        }
        return error(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, "directory creation is not supported by this provider");
    }

    FileMutationResponse renamePath(String sourcePath, String destinationPath) {
        if (sourcePath == null || destinationPath == null || sourcePath.equals(destinationPath)) {
            return error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "rename paths must be distinct");
        }
        boolean directory = destinationPath.endsWith("/");
        if (sourcePath.startsWith(DmFileProvider.APP_SANDBOX_PATH)
                && destinationPath.startsWith(DmFileProvider.APP_SANDBOX_PATH)) {
            String source = appRelative(sourcePath, sourcePath.endsWith("/"));
            String destination = appRelative(destinationPath, directory);
            if (source == null || destination == null || source.isEmpty() || destination.isEmpty()) {
                return error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "malformed app sandbox rename path");
            }
            try {
                pathCoordinator.runLeased(
                        Arrays.asList(
                                ProviderPathCoordinator.Claim.appSandbox(source),
                                ProviderPathCoordinator.Claim.appSandbox(destination)
                        ),
                        () -> appSandboxCatalog.renamePath(source, destination, directory)
                );
                return ok();
            } catch (ProviderCatalogException exception) {
                return error(
                        exception.code,
                        ProviderErrorLabels.mutation(exception.code, "app sandbox")
                );
            }
        }

        String normalizedSource = trimTrailingSlash(sourcePath);
        String normalizedDestination = trimTrailingSlash(destinationPath);
        final List<SafRoot> safRoots = ProviderSafCatalog.snapshotRoots(safCatalog);
        SafTarget source = ProviderPathRouter.safDirectory(
                normalizedSource, safRoots, safDocumentCache
        );
        SafUploadTarget destination = ProviderPathRouter.safUpload(
                normalizedDestination, safRoots, safDocumentCache
        );
        if (source != null && destination != null) {
            if (source.error != null) {
                ErrorCode code = source.error.getError().getCode();
                return error(code, ProviderErrorLabels.mutation(code, "SAF"));
            }
            if (destination.error != null) {
                return error(
                        destination.error.code,
                        ProviderErrorLabels.mutation(destination.error.code, "SAF")
                );
            }
            if (!source.root.stableId.equals(destination.root.stableId)) {
                return error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "SAF rename must remain in one root");
            }
            if (source.parentDocumentId == null
                    || destination.parentDocumentId == null
                    || !source.parentDocumentId.equals(destination.parentDocumentId)) {
                return error(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "SAF rename must remain in one directory"
                );
            }
            if (source.kind == FileKind.FILE_KIND_UNSPECIFIED
                    || (source.kind == FileKind.FILE_KIND_DIRECTORY) != directory) {
                return error(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "SAF rename must preserve the listed document kind"
                );
            }
            FileKind expectedKind = source.kind;
            try {
                pathCoordinator.runLeased(
                        Arrays.asList(
                                safDocumentClaim(source),
                                safChildClaim(destination)
                        ),
                        () -> {
                            ProviderSafCatalog.MutationIdentity renamed;
                            try {
                                renamed = safCatalog.renameDocument(
                                        source.root,
                                        source.parentDocumentId,
                                        source.documentId,
                                        source.displayName,
                                        destination.displayName,
                                        expectedKind
                                );
                            } catch (ProviderCatalogException exception) {
                                safDocumentCache.invalidateAfterUncertainMutation(
                                        source.root
                                );
                                throw exception;
                            } catch (RuntimeException exception) {
                                safDocumentCache.invalidateAfterUncertainMutation(
                                        source.root
                                );
                                throw internal("SAF rename failed");
                            }
                            if (renamed == null
                                    || renamed.documentId == null
                                    || renamed.documentId.isEmpty()
                                    || renamed.displayName == null) {
                                safDocumentCache.invalidateAfterUncertainMutation(
                                        source.root
                                );
                                throw internal("SAF rename returned no document identity");
                            }
                            if (!destination.displayName.equals(renamed.displayName)
                                    || renamed.kind != expectedKind) {
                                safDocumentCache.invalidateAfterUncertainMutation(
                                        source.root
                                );
                                throw internal(
                                        "SAF provider did not preserve the requested identity"
                                );
                            }
                            // Android providers may replace the document ID
                            // during rename. Rebind only an exact claimed result.
                            if (safDocumentCache.rebindAfterRename(
                                    source.root,
                                    source.documentId,
                                    source.parentDocumentId,
                                    renamed.documentId,
                                    renamed.displayName,
                                    renamed.kind
                            ) == null) {
                                throw internal(
                                        "SAF rename returned a conflicting document identity"
                                );
                            }
                        }
                );
                return ok();
            } catch (ProviderCatalogException exception) {
                return error(
                        exception.code,
                        ProviderErrorLabels.mutation(exception.code, "SAF")
                );
            }
        }
        return error(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, "rename is not supported by this provider");
    }

    FileMutationResponse deletePath(String path, boolean recursive) {
        if (path == null) {
            return error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "delete path is required");
        }
        boolean directory = path.endsWith("/");
        if (path.startsWith(DmFileProvider.APP_SANDBOX_PATH)) {
            String relative = appRelative(path, directory);
            if (relative == null || relative.isEmpty()) {
                return error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "app sandbox root cannot be deleted");
            }
            try {
                pathCoordinator.runLeased(
                        ProviderPathCoordinator.Claim.appSandbox(relative),
                        () -> appSandboxCatalog.deletePath(relative, directory, recursive)
                );
                return ok();
            } catch (ProviderCatalogException exception) {
                return error(
                        exception.code,
                        ProviderErrorLabels.mutation(exception.code, "app sandbox")
                );
            }
        }

        final List<SafRoot> safRoots = ProviderSafCatalog.snapshotRoots(safCatalog);
        SafTarget target = ProviderPathRouter.safDirectory(
                trimTrailingSlash(path), safRoots, safDocumentCache
        );
        if (target != null) {
            if (target.error != null) {
                ErrorCode code = target.error.getError().getCode();
                return error(code, ProviderErrorLabels.mutation(code, "SAF"));
            }
            if (target.documentId.equals(target.root.documentId)) {
                return error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "SAF root cannot be deleted");
            }
            try {
                pathCoordinator.runLeased(
                        safDocumentClaim(target),
                        () -> {
                            try {
                                safCatalog.deleteDocument(
                                        target.root,
                                        target.documentId,
                                        recursive
                                );
                            } catch (ProviderCatalogException exception) {
                                safDocumentCache.invalidateAfterUncertainMutation(
                                        target.root
                                );
                                throw exception;
                            } catch (RuntimeException exception) {
                                safDocumentCache.invalidateAfterUncertainMutation(
                                        target.root
                                );
                                throw internal("SAF delete failed");
                            }
                            safDocumentCache.invalidateAfterDelete(
                                    target.root,
                                    target.documentId
                            );
                        }
                );
                return ok();
            } catch (ProviderCatalogException exception) {
                return error(
                        exception.code,
                        ProviderErrorLabels.mutation(exception.code, "SAF")
                );
            }
        }
        return error(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY, "delete is not supported by this provider");
    }

    private ProviderPathCoordinator.Claim safChildClaim(SafUploadTarget target) {
        return ProviderPathCoordinator.Claim.safChild(
                target.root,
                target.rootsSnapshot,
                target.parentDocumentId,
                target.displayName,
                safDocumentCache.ancestorDocumentIds(
                        target.root,
                        target.parentDocumentId
                )
        );
    }

    private ProviderPathCoordinator.Claim safDocumentClaim(SafTarget target) {
        return ProviderPathCoordinator.Claim.safDocument(
                target.root,
                target.rootsSnapshot,
                target.documentId,
                target.parentDocumentId,
                target.displayName,
                safDocumentCache.ancestorDocumentIds(
                        target.root,
                        target.parentDocumentId
                )
        );
    }

    private static String appRelative(String path, boolean trailingSlash) {
        if (trailingSlash != path.endsWith("/")) return null;
        String relative = path.substring(DmFileProvider.APP_SANDBOX_PATH.length());
        String trimmed = trailingSlash && !relative.isEmpty()
                ? relative.substring(0, relative.length() - 1)
                : relative;
        if (!relative.isEmpty() && trimmed.isEmpty()) return null;
        return ProviderPathRouter.isCanonicalAppSandboxRelativePath(trimmed) ? trimmed : null;
    }

    private static String trimTrailingSlash(String path) {
        return path != null && path.endsWith("/") ? path.substring(0, path.length() - 1) : path;
    }

    private static FileMutationResponse ok() {
        return FileMutationResponse.newBuilder().setOk(true).build();
    }

    private static ProviderCatalogException internal(String message) {
        return new ProviderCatalogException(ErrorCode.ERROR_CODE_INTERNAL, message);
    }

    private static FileMutationResponse error(ErrorCode code, String message) {
        return FileMutationResponse.newBuilder()
                .setError(DroidMatchError.newBuilder().setCode(code).setMessage(message == null ? "" : message))
                .build();
    }
}
