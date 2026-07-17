package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.AppSandboxPage;
import app.droidmatch.m1.DmFileProvider.DownloadReader;
import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.m1.DmFileProvider.ProviderQuery;
import app.droidmatch.m1.DmFileProvider.UploadWriter;
import app.droidmatch.proto.v1.ErrorCode;

import java.util.ArrayList;

/**
 * App-sandbox storage port. Canonicalization and file-descriptor ownership
 * remain in the concrete catalog; the facade never receives a platform path.
 * 中文：App Sandbox 存储端口；规范化与文件描述符仍由具体 catalog 独占，facade 不接收平台路径。
 */
interface ProviderAppSandboxCatalog {
    AppSandboxPage listDirectory(String relativePath, ProviderQuery query) throws ProviderCatalogException;

    DownloadReader openFile(String relativePath, long offsetBytes, int chunkSizeBytes)
            throws ProviderCatalogException;

    UploadWriter openUploadFile(
            String relativePath,
            String transferId,
            long offsetBytes,
            long expectedSizeBytes,
            ProviderUploadLeases uploadLeases
    )
            throws ProviderCatalogException;

    void discardUploadPartial(
            String relativePath,
            String transferId,
            long expectedSizeBytes,
            ProviderUploadLeases uploadLeases
    ) throws ProviderCatalogException;

    void createDirectory(String relativePath) throws ProviderCatalogException;

    void renamePath(String sourceRelativePath, String destinationRelativePath, boolean directory)
            throws ProviderCatalogException;

    void deletePath(String relativePath, boolean directory, boolean recursive)
            throws ProviderCatalogException;

    static ProviderAppSandboxCatalog empty() {
        return new ProviderAppSandboxCatalog() {
            @Override
            public AppSandboxPage listDirectory(String relativePath, ProviderQuery query) {
                return new AppSandboxPage(new ArrayList<>(), false);
            }

            @Override
            public DownloadReader openFile(String relativePath, long offsetBytes, int chunkSizeBytes)
                    throws ProviderCatalogException {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "app sandbox entry is not available"
                );
            }

            @Override
            public UploadWriter openUploadFile(
                    String relativePath,
                    String transferId,
                    long offsetBytes,
                    long expectedSizeBytes,
                    ProviderUploadLeases uploadLeases
            )
                    throws ProviderCatalogException {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "app sandbox entry is not available"
                );
            }

            @Override
            public void discardUploadPartial(
                    String relativePath,
                    String transferId,
                    long expectedSizeBytes,
                    ProviderUploadLeases uploadLeases
            ) throws ProviderCatalogException {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "app sandbox entry is not available"
                );
            }

            @Override
            public void createDirectory(String relativePath) throws ProviderCatalogException {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                        "app sandbox directory creation is not available"
                );
            }

            @Override
            public void renamePath(String sourceRelativePath, String destinationRelativePath, boolean directory)
                    throws ProviderCatalogException {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                        "app sandbox rename is not available"
                );
            }

            @Override
            public void deletePath(String relativePath, boolean directory, boolean recursive)
                    throws ProviderCatalogException {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                        "app sandbox delete is not available"
                );
            }
        };
    }
}
