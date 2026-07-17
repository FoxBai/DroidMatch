package app.droidmatch.m1;

import app.droidmatch.proto.v1.ErrorCode;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Resolves one lexical app-sandbox path without allowing root aliases or
 * traversal through an existing symbolic-link component.
 *
 * <p>This boundary is intentionally shared by listing, mutation, and transfer
 * opens. It does not authorize an operation or retain an open descriptor.</p>
 *
 * <p>中文：该边界统一负责 App Sandbox 词法路径与文件系统规范化；
 * 列表、修改与传输打开不得各自实现一套路径准入。</p>
 */
final class AppSandboxPathResolver {
    private final File rootDirectory;

    AppSandboxPathResolver(File rootDirectory) {
        this.rootDirectory = rootDirectory;
    }

    File resolve(String relativePath) throws DmFileProvider.ProviderCatalogException {
        if (!ProviderPathRouter.isCanonicalAppSandboxRelativePath(relativePath)) {
            throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "malformed app sandbox path");
        }
        try {
            File canonicalRoot = rootDirectory.getCanonicalFile();
            Path candidatePath = canonicalRoot.toPath();
            if (!relativePath.isEmpty()) {
                for (String segment : relativePath.split("/", -1)) {
                    candidatePath = candidatePath.resolve(segment);
                    if (Files.isSymbolicLink(candidatePath)) {
                        throw error(
                                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                                "app sandbox path cannot traverse a symbolic link"
                        );
                    }
                }
            }
            File candidate = candidatePath.toFile().getCanonicalFile();
            String rootPath = canonicalRoot.getPath();
            String resolvedPath = candidate.getPath();
            if ((!relativePath.isEmpty() && resolvedPath.equals(rootPath))
                    || (!resolvedPath.equals(rootPath)
                    && !resolvedPath.startsWith(rootPath + File.separator))) {
                throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "malformed app sandbox path");
            }
            return candidate;
        } catch (IOException exception) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "app sandbox path resolution failed");
        }
    }

    private static DmFileProvider.ProviderCatalogException error(
            ErrorCode code,
            String message
    ) {
        return new DmFileProvider.ProviderCatalogException(code, message);
    }
}
