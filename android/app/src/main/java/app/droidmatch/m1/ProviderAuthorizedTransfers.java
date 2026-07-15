package app.droidmatch.m1;

import app.droidmatch.proto.v1.ErrorCode;

/**
 * Revalidates live provider authorization immediately before transfer I/O.
 *
 * <p>An already-open Android descriptor can remain usable after its runtime or
 * persisted grant is revoked. Catalogs therefore wrap provider-backed readers
 * and writers with a live check rather than treating open-time admission as a
 * session-long capability. Authorization failure closes the delegate before it
 * escapes so dispatcher route and upload-lease teardown stay deterministic.</p>
 *
 * <p>中文：已打开的 Android 描述符可能在授权撤销后仍可读写；因此每个传输块
 * 都必须重新验证实时授权，失败时先关闭底层句柄，再由 dispatcher 释放 route
 * 和上传目标租约。</p>
 */
final class ProviderAuthorizedTransfers {
    private ProviderAuthorizedTransfers() {
    }

    static DmFileProvider.DownloadReader download(
            DmFileProvider.DownloadReader delegate,
            ProviderLiveAuthorization authorization
    ) {
        return new AuthorizedDownloadReader(delegate, authorization);
    }

    static DmFileProvider.UploadWriter upload(
            DmFileProvider.UploadWriter delegate,
            ProviderLiveAuthorization authorization
    ) {
        return new AuthorizedUploadWriter(delegate, authorization);
    }

    private static DmFileProvider.ProviderCatalogException closed(String kind) {
        return new DmFileProvider.ProviderCatalogException(
                ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                kind + " is closed"
        );
    }

    private static final class AuthorizedDownloadReader
            implements DmFileProvider.DownloadReader {
        private final DmFileProvider.DownloadReader delegate;
        private final ProviderLiveAuthorization authorization;
        private boolean closed;

        private AuthorizedDownloadReader(
                DmFileProvider.DownloadReader delegate,
                ProviderLiveAuthorization authorization
        ) {
            this.delegate = delegate;
            this.authorization = authorization;
        }

        @Override
        public DmFileProvider.DownloadChunk readNextChunk()
                throws DmFileProvider.ProviderCatalogException {
            if (closed) {
                throw closed("download reader");
            }
            try {
                authorization.requireAuthorized();
                return delegate.readNextChunk();
            } catch (DmFileProvider.ProviderCatalogException | RuntimeException exception) {
                close();
                throw exception;
            }
        }

        @Override
        public void close() {
            if (closed) {
                return;
            }
            closed = true;
            closeQuietly(delegate);
        }
    }

    private static final class AuthorizedUploadWriter
            implements DmFileProvider.UploadWriter {
        private final DmFileProvider.UploadWriter delegate;
        private final ProviderLiveAuthorization authorization;
        private boolean closed;

        private AuthorizedUploadWriter(
                DmFileProvider.UploadWriter delegate,
                ProviderLiveAuthorization authorization
        ) {
            this.delegate = delegate;
            this.authorization = authorization;
        }

        @Override
        public long nextOffsetBytes() {
            return delegate.nextOffsetBytes();
        }

        @Override
        public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
                throws DmFileProvider.ProviderCatalogException {
            if (closed) {
                throw closed("upload writer");
            }
            try {
                // The check deliberately precedes the delegate call so final
                // publication/rename cannot begin under a known-stale grant.
                authorization.requireAuthorized();
                delegate.writeChunk(offsetBytes, data, finalChunk);
                if (finalChunk) {
                    close();
                }
            } catch (DmFileProvider.ProviderCatalogException | RuntimeException exception) {
                close();
                throw exception;
            }
        }

        @Override
        public void close() {
            if (closed) {
                return;
            }
            closed = true;
            closeQuietly(delegate);
        }
    }

    private static void closeQuietly(DmFileProvider.DownloadReader reader) {
        try {
            reader.close();
        } catch (RuntimeException ignored) {
        }
    }

    private static void closeQuietly(DmFileProvider.UploadWriter writer) {
        try {
            writer.close();
        } catch (RuntimeException ignored) {
        }
    }
}

@FunctionalInterface
interface ProviderLiveAuthorization {
    void requireAuthorized() throws DmFileProvider.ProviderCatalogException;
}

/** Resolves Android 14 selected-media access against the exact active item. */
final class ProviderMediaReadAuthorization implements ProviderLiveAuthorization {
    private final MediaAccessSource accessSource;
    private final ItemVisibility itemVisibility;
    private final String failureMessage;

    ProviderMediaReadAuthorization(
            MediaAccessSource accessSource,
            ItemVisibility itemVisibility,
            String failureMessage
    ) {
        this.accessSource = accessSource;
        this.itemVisibility = itemVisibility;
        this.failureMessage = failureMessage;
    }

    @Override
    public void requireAuthorized() throws DmFileProvider.ProviderCatalogException {
        PermissionStateProvider.MediaReadAccess access = accessSource.currentAccess();
        if (access == PermissionStateProvider.MediaReadAccess.FULL) {
            return;
        }
        if (access == PermissionStateProvider.MediaReadAccess.SELECTED
                && itemVisibility.currentItemVisible()) {
            return;
        }
        throw new DmFileProvider.ProviderCatalogException(
                ErrorCode.ERROR_CODE_PERMISSION_REQUIRED,
                failureMessage
        );
    }

    @FunctionalInterface
    interface MediaAccessSource {
        PermissionStateProvider.MediaReadAccess currentAccess();
    }

    @FunctionalInterface
    interface ItemVisibility {
        boolean currentItemVisible() throws DmFileProvider.ProviderCatalogException;
    }
}
