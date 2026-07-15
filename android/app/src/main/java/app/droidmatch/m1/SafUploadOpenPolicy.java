package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.ProviderCatalogException;
import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;

/**
 * Pure SAF upload-open decisions. Resolver calls and partial cleanup remain in
 * {@link AndroidSafUploadOpener}; this policy only classifies caller intent and
 * validates already-decoded partial metadata.
 *
 * <p>中文：纯 SAF 上传打开决策；这里只分类 fresh/restart/resume 并校验已解码
 * partial 元数据，不持有 resolver、URI、描述符或清理状态。</p>
 */
final class SafUploadOpenPolicy {
    enum Mode {
        FRESH,
        RESTART_RESUMABLE,
        RESUME
    }

    private SafUploadOpenPolicy() {}

    static Mode mode(String transferId, long offsetBytes) throws ProviderCatalogException {
        if (transferId.isEmpty()) {
            if (offsetBytes != 0) {
                throw new ProviderCatalogException(
                        ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY,
                        "SAF upload resume requires a transfer_id"
                );
            }
            return Mode.FRESH;
        }
        return offsetBytes == 0 ? Mode.RESTART_RESUMABLE : Mode.RESUME;
    }

    static boolean requiresTruncation(
            SafDocumentCursorReader.ChildDocument partialDocument,
            long offsetBytes
    ) throws ProviderCatalogException {
        if (partialDocument == null) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "SAF upload partial is not available"
            );
        }
        if (partialDocument.kind != FileKind.FILE_KIND_FILE) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "SAF upload partial must identify a file entry"
            );
        }
        if (partialDocument.sizeBytes < offsetBytes) {
            throw new ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "requested_offset_bytes does not match SAF upload partial"
            );
        }
        return partialDocument.sizeBytes > offsetBytes;
    }
}
