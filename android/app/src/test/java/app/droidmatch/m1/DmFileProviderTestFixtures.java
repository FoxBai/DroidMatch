package app.droidmatch.m1;

import app.droidmatch.proto.v1.ErrorCode;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Collections;

final class DmFileProviderTestFixtures {
    private DmFileProviderTestFixtures() {}

    static void writeFile(File file, String text) throws IOException {
        Files.write(file.toPath(), text.getBytes(StandardCharsets.UTF_8));
    }

    static void deleteRecursively(File file) {
        if (file == null) {
            return;
        }
        Path path = file.toPath();
        if (Files.isSymbolicLink(path)) {
            try {
                Files.deleteIfExists(path);
            } catch (IOException ignored) {
            }
            return;
        }
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return;
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) {
                deleteRecursively(child);
            }
        }
        file.delete();
    }

    static void deleteAppSandboxRoot(File root) {
        if (root == null) return;
        deleteRecursively(AndroidAppSandboxCatalog.stagingDirectoryFor(root));
        deleteRecursively(root);
    }
}
final class FakeMediaCatalog implements ProviderMediaCatalog {
    DmFileProvider.RootKind rootKind;
    DmFileProvider.ProviderQuery query;
    DmFileProvider.ProviderCatalogException exception;
    DmFileProvider.MediaPage page = new DmFileProvider.MediaPage(Collections.emptyList(), false);
    ProviderAlbumPage albumPage = new ProviderAlbumPage(Collections.emptyList(), false);
    String albumToken;
    DmFileProvider.RootKind readRootKind;
    long mediaId;
    long readOffsetBytes;
    int readChunkSizeBytes;
    boolean canUploadMedia;
    boolean canReadImages = true;
    boolean canReadVideos = true;
    DmFileProvider.RootKind uploadRootKind;
    String uploadDisplayName;
    long uploadOffsetBytes;
    long uploadExpectedSizeBytes;
    ByteArrayOutputStream uploadedBytes;
    byte[] streamData;
    int openMediaCount;
    int closeReaderCount;
    int thumbnailDimension;
    DmFileProvider.DownloadChunk downloadChunk = new DmFileProvider.DownloadChunk(
            new byte[0],
            0,
            0,
            "",
            true
    );

    @Override
    public ProviderThumbnail thumbnail(
            DmFileProvider.RootKind rootKind,
            long mediaId,
            int maxDimensionPx
    ) throws DmFileProvider.ProviderCatalogException {
        this.readRootKind = rootKind;
        this.mediaId = mediaId;
        this.thumbnailDimension = maxDimensionPx;
        if (exception != null) throw exception;
        return new ProviderThumbnail(new byte[] {1, 2, 3}, "image/jpeg", 80, 60);
    }

    @Override
    public ProviderThumbnail thumbnailAlbum(String albumToken, int maxDimensionPx)
            throws DmFileProvider.ProviderCatalogException {
        this.albumToken = albumToken;
        this.thumbnailDimension = maxDimensionPx;
        if (exception != null) throw exception;
        return new ProviderThumbnail(new byte[] {1, 2, 3}, "image/jpeg", 80, 60);
    }

    @Override
    public DmFileProvider.MediaPage listMedia(
            DmFileProvider.RootKind rootKind,
            DmFileProvider.ProviderQuery query
    ) throws DmFileProvider.ProviderCatalogException {
        this.rootKind = rootKind;
        this.query = query;
        if (exception != null) {
            throw exception;
        }
        return page;
    }

    @Override
    public ProviderAlbumPage listAlbums(DmFileProvider.ProviderQuery query)
            throws DmFileProvider.ProviderCatalogException {
        this.query = query;
        if (exception != null) throw exception;
        return albumPage;
    }

    @Override
    public DmFileProvider.MediaPage listMediaInAlbum(
            String albumToken,
            DmFileProvider.ProviderQuery query
    ) throws DmFileProvider.ProviderCatalogException {
        this.albumToken = albumToken;
        this.query = query;
        if (exception != null) throw exception;
        return page;
    }

    @Override
    public DmFileProvider.DownloadChunk readMedia(
            DmFileProvider.RootKind rootKind,
            long mediaId,
            long offsetBytes,
            int chunkSizeBytes
    ) throws DmFileProvider.ProviderCatalogException {
        this.readRootKind = rootKind;
        this.mediaId = mediaId;
        this.readOffsetBytes = offsetBytes;
        this.readChunkSizeBytes = chunkSizeBytes;
        if (exception != null) {
            throw exception;
        }
        return downloadChunk;
    }

    @Override
    public boolean canReadMedia(DmFileProvider.RootKind rootKind) {
        return rootKind == DmFileProvider.RootKind.MEDIA_VIDEOS
                ? canReadVideos
                : canReadImages;
    }

    @Override
    public boolean canUploadMedia(DmFileProvider.RootKind rootKind) {
        return canUploadMedia;
    }

    @Override
    public DmFileProvider.DownloadReader openMedia(
            DmFileProvider.RootKind rootKind,
            long mediaId,
            long offsetBytes,
            int chunkSizeBytes
    ) throws DmFileProvider.ProviderCatalogException {
        if (streamData == null) {
            return ProviderMediaCatalog.super.openMedia(rootKind, mediaId, offsetBytes, chunkSizeBytes);
        }
        this.readRootKind = rootKind;
        this.mediaId = mediaId;
        this.readOffsetBytes = offsetBytes;
        this.readChunkSizeBytes = chunkSizeBytes;
        openMediaCount++;
        return new DmFileProvider.DownloadReader() {
            private int offset = (int) offsetBytes;
            private boolean closed;

            @Override
            public DmFileProvider.DownloadChunk readNextChunk() throws DmFileProvider.ProviderCatalogException {
                if (offset > streamData.length) {
                    throw new DmFileProvider.ProviderCatalogException(
                            ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                            "requested_offset_bytes is beyond end of file"
                    );
                }
                int nextOffset = Math.min(offset + chunkSizeBytes, streamData.length);
                byte[] data = Arrays.copyOfRange(streamData, offset, nextOffset);
                offset = nextOffset;
                boolean finalChunk = offset >= streamData.length;
                if (finalChunk) {
                    close();
                }
                return new DmFileProvider.DownloadChunk(
                        data,
                        streamData.length,
                        1_700_000_000_000L,
                        "media-etag",
                        finalChunk
                );
            }

            @Override
            public void close() {
                if (closed) {
                    return;
                }
                closed = true;
                closeReaderCount++;
            }
        };
    }

    @Override
    public DmFileProvider.UploadWriter openUploadMedia(
            DmFileProvider.RootKind rootKind,
            String displayName,
            long offsetBytes,
            long expectedSizeBytes
    ) {
        this.uploadRootKind = rootKind;
        this.uploadDisplayName = displayName;
        this.uploadOffsetBytes = offsetBytes;
        this.uploadExpectedSizeBytes = expectedSizeBytes;
        this.uploadedBytes = new ByteArrayOutputStream();
        return new DmFileProvider.UploadWriter() {
            private long nextOffsetBytes = offsetBytes;
            private boolean closed;

            @Override
            public long nextOffsetBytes() {
                return nextOffsetBytes;
            }

            @Override
            public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
                    throws DmFileProvider.ProviderCatalogException {
                if (closed) {
                    throw new DmFileProvider.ProviderCatalogException(
                            ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                            "upload writer is closed"
                    );
                }
                if (offsetBytes != nextOffsetBytes) {
                    throw new DmFileProvider.ProviderCatalogException(
                            ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                            "transfer chunk offset does not match the expected write boundary"
                    );
                }
                uploadedBytes.write(data, 0, data.length);
                nextOffsetBytes += data.length;
                if (finalChunk) {
                    close();
                }
            }

            @Override
            public void close() {
                closed = true;
            }
        };
    }

    String uploadedText() {
        return new String(uploadedBytes.toByteArray(), StandardCharsets.UTF_8);
    }
}



final class FakeSafCatalog implements ProviderSafCatalog {
    final DmFileProvider.SafRoot root;
    private java.util.List<DmFileProvider.SafRoot> liveRoots;
    String documentId;
    String readDocumentId;
    String uploadParentDocumentId;
    String uploadDisplayName;
    String uploadTransferId;
    String discardedParentDocumentId;
    String discardedDisplayName;
    String discardedTransferId;
    String renamedDocumentId;
    String renamedDisplayName;
    int renameCount;
    long uploadOffsetBytes;
    long uploadExpectedSizeBytes;
    long discardedExpectedSizeBytes;
    int discardCount;
    ByteArrayOutputStream uploadedBytes;
    DmFileProvider.ProviderQuery query;
    DmFileProvider.ProviderCatalogException exception;
    DmFileProvider.ProviderCatalogException mutationException;
    DmFileProvider.SafPage page = new DmFileProvider.SafPage(Collections.emptyList(), false);
    DmFileProvider.DownloadChunk downloadChunk = new DmFileProvider.DownloadChunk(
            new byte[0],
            0,
            0,
            "",
            true
    );

    FakeSafCatalog(DmFileProvider.SafRoot... roots) {
        if (roots.length == 0) throw new IllegalArgumentException("at least one SAF root is required");
        this.root = roots[0];
        liveRoots = new java.util.ArrayList<>(Arrays.asList(roots));
    }

    void replaceRoots(DmFileProvider.SafRoot... roots) {
        liveRoots = new java.util.ArrayList<>(Arrays.asList(roots));
    }

    @Override
    public java.util.List<DmFileProvider.SafRoot> roots() {
        return new java.util.ArrayList<>(liveRoots);
    }

    @Override
    public DmFileProvider.SafPage listChildren(
            DmFileProvider.SafRoot root,
            String documentId,
            DmFileProvider.ProviderQuery query
    ) throws DmFileProvider.ProviderCatalogException {
        this.documentId = documentId;
        this.query = query;
        if (exception != null) throw exception;
        return page;
    }

    @Override
    public void createDirectory(
            DmFileProvider.SafRoot root,
            String parentDocumentId,
            String displayName
    ) throws DmFileProvider.ProviderCatalogException {
        if (mutationException != null) throw mutationException;
        ProviderSafCatalog.super.createDirectory(root, parentDocumentId, displayName);
    }

    @Override
    public void renameDocument(
            DmFileProvider.SafRoot root,
            String documentId,
            String displayName
    ) throws DmFileProvider.ProviderCatalogException {
        if (mutationException != null) throw mutationException;
        renamedDocumentId = documentId;
        renamedDisplayName = displayName;
        renameCount++;
    }

    @Override
    public void deleteDocument(
            DmFileProvider.SafRoot root,
            String documentId,
            boolean recursive
    ) throws DmFileProvider.ProviderCatalogException {
        if (mutationException != null) throw mutationException;
        ProviderSafCatalog.super.deleteDocument(root, documentId, recursive);
    }

    @Override
    public DmFileProvider.DownloadChunk readDocument(
            DmFileProvider.SafRoot root,
            String documentId,
            long offsetBytes,
            int chunkSizeBytes
    ) {
        this.readDocumentId = documentId;
        return downloadChunk;
    }

    @Override
    public DmFileProvider.UploadWriter openUploadDocument(
            DmFileProvider.SafRoot root,
            String parentDocumentId,
            String displayName,
            String transferId,
            long offsetBytes,
            long expectedSizeBytes
    ) {
        this.uploadParentDocumentId = parentDocumentId;
        this.uploadDisplayName = displayName;
        this.uploadTransferId = transferId;
        this.uploadOffsetBytes = offsetBytes;
        this.uploadExpectedSizeBytes = expectedSizeBytes;
        this.uploadedBytes = new ByteArrayOutputStream();
        return new DmFileProvider.UploadWriter() {
            private long nextOffsetBytes = offsetBytes;
            private boolean closed;

            @Override
            public long nextOffsetBytes() {
                return nextOffsetBytes;
            }

            @Override
            public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
                    throws DmFileProvider.ProviderCatalogException {
                if (closed) {
                    throw new DmFileProvider.ProviderCatalogException(
                            ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                            "upload writer is closed"
                    );
                }
                if (offsetBytes != nextOffsetBytes) {
                    throw new DmFileProvider.ProviderCatalogException(
                            ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                            "transfer chunk offset does not match the expected write boundary"
                    );
                }
                uploadedBytes.write(data, 0, data.length);
                nextOffsetBytes += data.length;
                if (finalChunk) {
                    close();
                }
            }

            @Override
            public void close() {
                closed = true;
            }
        };
    }

    @Override
    public void discardUploadPartial(
            DmFileProvider.SafRoot root,
            String parentDocumentId,
            String displayName,
            String transferId,
            long expectedSizeBytes
    ) throws DmFileProvider.ProviderCatalogException {
        if (mutationException != null) throw mutationException;
        discardedParentDocumentId = parentDocumentId;
        discardedDisplayName = displayName;
        discardedTransferId = transferId;
        discardedExpectedSizeBytes = expectedSizeBytes;
        discardCount++;
    }

    String uploadedText() {
        return new String(uploadedBytes.toByteArray(), StandardCharsets.UTF_8);
    }
}
