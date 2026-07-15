package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.DownloadChunk;
import app.droidmatch.m1.DmFileProvider.DownloadReader;
import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.m1.DmFileProvider.ProviderQuery;
import app.droidmatch.m1.DmFileProvider.SafPage;
import app.droidmatch.m1.DmFileProvider.SafRoot;
import app.droidmatch.m1.DmFileProvider.UploadWriter;
import app.droidmatch.proto.v1.ErrorCode;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * SAF-facing storage port. Permission checks and resolver I/O remain live
 * Android catalog responsibilities rather than facade state.
 * 中文：面向 SAF 的存储端口；实时权限检查与 resolver I/O 仍由 Android catalog 负责。
 */
interface ProviderSafCatalog {
    List<SafRoot> roots();

    SafPage listChildren(SafRoot root, String documentId, ProviderQuery query) throws ProviderCatalogException;

    DownloadChunk readDocument(SafRoot root, String documentId, long offsetBytes, int chunkSizeBytes)
            throws ProviderCatalogException;

    default DownloadReader openDocument(SafRoot root, String documentId, long offsetBytes, int chunkSizeBytes)
            throws ProviderCatalogException {
        return ProviderDownloadReaders.oneShot(
                readDocument(root, documentId, offsetBytes, chunkSizeBytes)
        );
    }

    default UploadWriter openUploadDocument(
            SafRoot root,
            String parentDocumentId,
            String displayName,
            String transferId,
            long offsetBytes,
            long expectedSizeBytes
    ) throws ProviderCatalogException {
        throw new ProviderCatalogException(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "SAF upload is not available"
        );
    }

    default void createDirectory(SafRoot root, String parentDocumentId, String displayName)
            throws ProviderCatalogException {
        throw new ProviderCatalogException(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "SAF directory creation is not available"
        );
    }

    default void renameDocument(SafRoot root, String documentId, String displayName)
            throws ProviderCatalogException {
        throw new ProviderCatalogException(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "SAF rename is not available"
        );
    }

    default void deleteDocument(SafRoot root, String documentId, boolean recursive)
            throws ProviderCatalogException {
        throw new ProviderCatalogException(
                ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                "SAF delete is not available"
        );
    }

    static ProviderSafCatalog empty() {
        return new ProviderSafCatalog() {
            @Override
            public List<SafRoot> roots() {
                return Collections.emptyList();
            }

            @Override
            public SafPage listChildren(
                    SafRoot root,
                    String documentId,
                    ProviderQuery query
            ) {
                return new SafPage(new ArrayList<>(), false);
            }

            @Override
            public DownloadChunk readDocument(
                    SafRoot root,
                    String documentId,
                    long offsetBytes,
                    int chunkSizeBytes
            ) throws ProviderCatalogException {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "SAF document is not available"
                );
            }
        };
    }
}
