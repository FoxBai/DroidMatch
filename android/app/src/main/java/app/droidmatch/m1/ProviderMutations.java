package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.AppSandboxCatalog;
import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.m1.DmFileProvider.SafCatalog;
import app.droidmatch.m1.ProviderPathRouter.SafTarget;
import app.droidmatch.m1.ProviderPathRouter.SafUploadTarget;
import app.droidmatch.proto.v1.DroidMatchError;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileMutationResponse;

import java.util.Map;

/** Owns provider-aware create/rename policy outside the listing facade. */
final class ProviderMutations {
    private final SafCatalog safCatalog;
    private final AppSandboxCatalog appSandboxCatalog;
    private final Map<String, String> safDocumentIdsByLogicalId;

    ProviderMutations(
            SafCatalog safCatalog,
            AppSandboxCatalog appSandboxCatalog,
            Map<String, String> safDocumentIdsByLogicalId
    ) {
        this.safCatalog = safCatalog;
        this.appSandboxCatalog = appSandboxCatalog;
        this.safDocumentIdsByLogicalId = safDocumentIdsByLogicalId;
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
                appSandboxCatalog.createDirectory(relative);
                return ok();
            } catch (ProviderCatalogException exception) {
                return error(
                        exception.code,
                        ProviderErrorLabels.mutation(exception.code, "app sandbox")
                );
            }
        }

        SafUploadTarget target = ProviderPathRouter.safCreateDirectory(
                path, safCatalog.roots(), safDocumentIdsByLogicalId
        );
        if (target != null) {
            if (target.error != null) {
                return error(
                        target.error.code,
                        ProviderErrorLabels.mutation(target.error.code, "SAF")
                );
            }
            try {
                safCatalog.createDirectory(target.root, target.parentDocumentId, target.displayName);
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
                appSandboxCatalog.renamePath(source, destination, directory);
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
        SafTarget source = ProviderPathRouter.safDirectory(
                normalizedSource, safCatalog.roots(), safDocumentIdsByLogicalId
        );
        SafUploadTarget destination = ProviderPathRouter.safUpload(
                normalizedDestination, safCatalog.roots(), safDocumentIdsByLogicalId
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
            try {
                safCatalog.renameDocument(source.root, source.documentId, destination.displayName);
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
                appSandboxCatalog.deletePath(relative, directory, recursive);
                return ok();
            } catch (ProviderCatalogException exception) {
                return error(
                        exception.code,
                        ProviderErrorLabels.mutation(exception.code, "app sandbox")
                );
            }
        }

        SafTarget target = ProviderPathRouter.safDirectory(
                trimTrailingSlash(path), safCatalog.roots(), safDocumentIdsByLogicalId
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
                safCatalog.deleteDocument(target.root, target.documentId, recursive);
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

    private static String appRelative(String path, boolean trailingSlash) {
        if (trailingSlash != path.endsWith("/")) return null;
        String relative = path.substring(DmFileProvider.APP_SANDBOX_PATH.length());
        return trailingSlash && !relative.isEmpty()
                ? relative.substring(0, relative.length() - 1)
                : relative;
    }

    private static String trimTrailingSlash(String path) {
        return path != null && path.endsWith("/") ? path.substring(0, path.length() - 1) : path;
    }

    private static FileMutationResponse ok() {
        return FileMutationResponse.newBuilder().setOk(true).build();
    }

    private static FileMutationResponse error(ErrorCode code, String message) {
        return FileMutationResponse.newBuilder()
                .setError(DroidMatchError.newBuilder().setCode(code).setMessage(message == null ? "" : message))
                .build();
    }
}
