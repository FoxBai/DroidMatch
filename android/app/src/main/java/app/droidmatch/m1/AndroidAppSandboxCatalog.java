package app.droidmatch.m1;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.SortField;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.DirectoryIteratorException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.Comparator;

/**
 * App-private filesystem catalog behind DroidMatch logical paths.
 *
 * <p>The facade strips the {@code dm://app-sandbox/} root before entering this
 * class. Every remaining path is canonicalized below the app-owned root; hidden
 * upload partials stay resumable, open without following links, are forced
 * before atomic publication, and never appear in listings.</p>
 */
final class AndroidAppSandboxCatalog implements ProviderAppSandboxCatalog {
    private final File rootDirectory;
    private final AppSandboxOpenedFileMetadataReader openedFileMetadataReader;

    AndroidAppSandboxCatalog(File rootDirectory) {
        this(rootDirectory, new NioAppSandboxOpenedFileMetadataReader());
    }

    AndroidAppSandboxCatalog(
            File rootDirectory,
            AppSandboxOpenedFileMetadataReader openedFileMetadataReader
    ) {
        this.rootDirectory = rootDirectory;
        this.openedFileMetadataReader = openedFileMetadataReader;
    }

    @Override
    public DmFileProvider.AppSandboxPage listDirectory(
            String relativePath,
            DmFileProvider.ProviderQuery query
    ) throws DmFileProvider.ProviderCatalogException {
        File directory = resolve(relativePath);
        if (!directory.exists()) {
            if (relativePath.isEmpty()) {
                return new DmFileProvider.AppSandboxPage(new ArrayList<>(), false);
            }
            throw error(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "app sandbox directory is not available"
            );
        }
        if (!directory.isDirectory()) {
            throw error(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "ListDirRequest.path must identify an app sandbox directory"
            );
        }

        Comparator<DmFileProvider.AppSandboxItem> comparator = appSandboxComparator(
                query.sortField(), query.descending()
        );
        ProviderBoundedPageSelector<DmFileProvider.AppSandboxItem> selector =
                new ProviderBoundedPageSelector<>(
                        comparator, query.offset(), query.limit()
        );
        try (DirectoryStream<Path> children = Files.newDirectoryStream(directory.toPath())) {
            for (Path childPath : children) {
                File child = childPath.toFile();
                if (Files.isSymbolicLink(childPath)
                        || isUploadPartialFileName(child.getName())
                        || !ProviderNameSearch.matches(child.getName(), query.searchQuery())) {
                    continue;
                }
                selector.accept(appSandboxItem(relativePath, child));
            }
        } catch (IOException | DirectoryIteratorException | SecurityException exception) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "app sandbox listing failed");
        }
        ProviderBoundedPageSelector.Page<DmFileProvider.AppSandboxItem> page = selector.page();
        return new DmFileProvider.AppSandboxPage(page.items, page.hasMore);
    }

    @Override
    public DmFileProvider.DownloadReader openFile(
            String relativePath,
            long offsetBytes,
            int chunkSizeBytes
    ) throws DmFileProvider.ProviderCatalogException {
        File file = resolve(relativePath);
        if (!file.exists()) {
            throw error(ErrorCode.ERROR_CODE_NOT_FOUND, "app sandbox file is not available");
        }
        if (!file.isFile()) {
            throw error(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "transfer source_path must identify a file entry"
            );
        }
        FileInputStream inputStream = null;
        boolean handedOff = false;
        try {
            inputStream = new FileInputStream(file);
            AppSandboxOpenedFileMetadata metadata = openedFileMetadataReader.read(
                    file,
                    inputStream
            );
            if (!metadata.regularFile) {
                throw error(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "transfer source_path must identify a file entry"
                );
            }
            if (offsetBytes > metadata.sizeBytes) {
                throw error(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "requested_offset_bytes is beyond end of file"
                );
            }
            FileChannel channel = inputStream.getChannel();
            channel.position(offsetBytes);
            DmFileProvider.DownloadReader reader = ProviderDownloadReaders.stream(
                    inputStream,
                    offsetBytes,
                    chunkSizeBytes,
                    metadata.sizeBytes,
                    metadata.modifiedUnixMillis,
                    providerEtag(relativePath, metadata),
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "app sandbox read failed",
                    "app sandbox read failed"
            );
            handedOff = true;
            return reader;
        } catch (FileNotFoundException exception) {
            throw error(ErrorCode.ERROR_CODE_NOT_FOUND, "app sandbox file is not available");
        } catch (DmFileProvider.ProviderCatalogException exception) {
            throw exception;
        } catch (IllegalArgumentException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "requested_offset_bytes must be non-negative"
            );
        } catch (IOException exception) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "app sandbox read failed");
        } finally {
            if (!handedOff) {
                ProviderIoCleanup.closeQuietly(inputStream);
            }
        }
    }

    @Override
    public DmFileProvider.UploadWriter openUploadFile(
            String relativePath,
            long offsetBytes,
            long expectedSizeBytes,
            ProviderUploadLeases uploadLeases
    ) throws DmFileProvider.ProviderCatalogException {
        File destination = resolve(relativePath);
        return uploadLeases.openLeased(
                ProviderUploadLeases.Destination.appSandbox(destination.getPath()),
                () -> openUploadFile(destination, offsetBytes, expectedSizeBytes)
        );
    }

    private DmFileProvider.UploadWriter openUploadFile(
            File destination,
            long offsetBytes,
            long expectedSizeBytes
    ) throws DmFileProvider.ProviderCatalogException {
        if (destination.exists() && destination.isDirectory()) {
            throw error(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "transfer destination_path must identify a file entry"
            );
        }
        File parent = destination.getParentFile();
        if (parent == null) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "app sandbox upload path has no parent");
        }
        if (!parent.exists() && !parent.mkdirs()) {
            throw error(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "app sandbox upload directory could not be created"
            );
        }
        if (!parent.isDirectory()) {
            throw error(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "transfer destination_path parent must identify a directory"
            );
        }

        try {
            File partialFile = uploadPartialFile(destination);
            return new AppSandboxUploadWriter(
                    destination,
                    partialFile,
                    openUploadPartial(partialFile, offsetBytes),
                    expectedSizeBytes,
                    offsetBytes
            );
        } catch (DmFileProvider.ProviderCatalogException exception) {
            throw exception;
        } catch (IOException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "app sandbox upload could not be opened"
            );
        }
    }

    private static AppSandboxPartialOutput openUploadPartial(File partialFile, long offsetBytes)
            throws IOException, DmFileProvider.ProviderCatalogException {
        Path partialPath = partialFile.toPath();
        if (offsetBytes == 0) {
            Files.deleteIfExists(partialPath);
            return new FileChannelAppSandboxPartialOutput(FileChannel.open(
                    partialPath,
                    StandardOpenOption.CREATE_NEW,
                    StandardOpenOption.WRITE,
                    LinkOption.NOFOLLOW_LINKS
            ));
        }
        if (!Files.isRegularFile(partialPath, LinkOption.NOFOLLOW_LINKS)) {
            throw error(
                    ErrorCode.ERROR_CODE_NOT_FOUND,
                    "app sandbox upload partial is not available"
            );
        }

        // The resume partial has a predictable name. Bind validation, truncate,
        // and append to one no-follow channel so a symlink can never redirect
        // bytes between preflight and open. 中文：恢复写入必须在同一个不跟随
        // 链接的 channel 上完成校验、截断和续写。
        FileChannel channel = FileChannel.open(
                partialPath,
                StandardOpenOption.WRITE,
                LinkOption.NOFOLLOW_LINKS
        );
        boolean handedOff = false;
        try {
            long partialSizeBytes = channel.size();
            if (partialSizeBytes < offsetBytes) {
                throw error(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "requested_offset_bytes does not match app sandbox upload partial"
                );
            }
            if (partialSizeBytes > offsetBytes) {
                channel.truncate(offsetBytes);
            }
            channel.position(offsetBytes);
            AppSandboxPartialOutput output = new FileChannelAppSandboxPartialOutput(channel);
            handedOff = true;
            return output;
        } finally {
            if (!handedOff) {
                channel.close();
            }
        }
    }

    @Override
    public void createDirectory(String relativePath) throws DmFileProvider.ProviderCatalogException {
        File directory = resolve(relativePath);
        if (directory.exists()) {
            throw error(ErrorCode.ERROR_CODE_ALREADY_EXISTS, "app sandbox entry already exists");
        }
        File parent = directory.getParentFile();
        if (parent == null || !parent.isDirectory()) {
            throw error(ErrorCode.ERROR_CODE_NOT_FOUND, "app sandbox parent directory is not available");
        }
        if (!directory.mkdir()) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "app sandbox directory could not be created");
        }
    }

    @Override
    public void renamePath(String sourceRelativePath, String destinationRelativePath, boolean directory)
            throws DmFileProvider.ProviderCatalogException {
        File source = resolve(sourceRelativePath);
        File destination = resolve(destinationRelativePath);
        if (!source.exists()) {
            throw error(ErrorCode.ERROR_CODE_NOT_FOUND, "app sandbox entry is not available");
        }
        if (source.isDirectory() != directory) {
            throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "rename destination kind does not match source");
        }
        File sourceParent = source.getParentFile();
        File destinationParent = destination.getParentFile();
        if (sourceParent == null || destinationParent == null || !sourceParent.equals(destinationParent)) {
            throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "rename must remain in one app sandbox directory");
        }
        if (destination.exists()) {
            throw error(ErrorCode.ERROR_CODE_ALREADY_EXISTS, "app sandbox destination already exists");
        }
        if (!source.renameTo(destination)) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "app sandbox entry could not be renamed");
        }
    }

    @Override
    public void deletePath(String relativePath, boolean directory, boolean recursive)
            throws DmFileProvider.ProviderCatalogException {
        File target = resolve(relativePath);
        if (!target.exists()) {
            throw error(ErrorCode.ERROR_CODE_NOT_FOUND, "app sandbox entry is not available");
        }
        if (target.isDirectory() != directory) {
            throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "delete path kind does not match entry");
        }
        if (directory && !recursive) {
            File[] children = target.listFiles();
            if (children == null) {
                throw error(ErrorCode.ERROR_CODE_INTERNAL, "app sandbox directory could not be inspected");
            }
            if (children.length > 0) {
                throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "non-empty directory requires recursive delete");
            }
        }
        if (!deleteRecursively(target, recursive)) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "app sandbox entry could not be deleted");
        }
    }

    private static boolean deleteRecursively(File target, boolean recursive) {
        // File.isDirectory()/listFiles() follow directory symlinks. Treat a link
        // as one leaf entry so recursive deletion can never escape the app root.
        // 中文：目录符号链接只能作为单个节点删除，递归操作不得进入其目标。
        if (recursive && !Files.isSymbolicLink(target.toPath()) && target.isDirectory()) {
            File[] children = target.listFiles();
            if (children == null) return false;
            for (File child : children) {
                if (!deleteRecursively(child, true)) return false;
            }
        }
        return target.delete();
    }

    private File resolve(String relativePath) throws DmFileProvider.ProviderCatalogException {
        if (relativePath.indexOf('\0') >= 0
                || relativePath.startsWith("/")
                || relativePath.contains("//")) {
            throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "malformed app sandbox path");
        }
        try {
            File canonicalRoot = rootDirectory.getCanonicalFile();
            File candidate = relativePath.isEmpty()
                    ? canonicalRoot
                    : new File(canonicalRoot, relativePath).getCanonicalFile();
            String rootPath = canonicalRoot.getPath();
            String candidatePath = candidate.getPath();
            if (!candidatePath.equals(rootPath)
                    && !candidatePath.startsWith(rootPath + File.separator)) {
                throw error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "malformed app sandbox path");
            }
            return candidate;
        } catch (IOException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "app sandbox path resolution failed"
            );
        }
    }

    private static DmFileProvider.AppSandboxItem appSandboxItem(
            String parentRelativePath,
            File file
    ) {
        String relativePath = parentRelativePath.isEmpty()
                ? file.getName()
                : parentRelativePath + "/" + file.getName();
        boolean directory = file.isDirectory();
        return new DmFileProvider.AppSandboxItem(
                relativePath,
                file.getName(),
                directory ? FileKind.FILE_KIND_DIRECTORY : FileKind.FILE_KIND_FILE,
                directory ? 0 : file.length(),
                file.lastModified(),
                directory ? "inode/directory" : "application/octet-stream",
                file.canWrite()
        );
    }

    private static Comparator<DmFileProvider.AppSandboxItem> appSandboxComparator(
            SortField sortField,
            boolean descending
    ) {
        Comparator<DmFileProvider.AppSandboxItem> comparator;
        switch (sortField) {
            case SORT_FIELD_NAME:
                comparator = Comparator.comparing(
                        item -> item.displayName,
                        String.CASE_INSENSITIVE_ORDER
                );
                break;
            case SORT_FIELD_SIZE:
                comparator = Comparator.comparingLong(item -> item.sizeBytes);
                break;
            case SORT_FIELD_KIND:
                comparator = Comparator.comparingInt(item -> item.kind.getNumber());
                break;
            case SORT_FIELD_MODIFIED_TIME:
            case SORT_FIELD_UNSPECIFIED:
            case UNRECOGNIZED:
            default:
                comparator = Comparator.comparingLong(item -> item.modifiedUnixMillis);
                break;
        }
        if (descending) {
            comparator = comparator.reversed();
        }
        return comparator
                .thenComparing(item -> item.displayName, String.CASE_INSENSITIVE_ORDER)
                .thenComparing(item -> item.relativePath);
    }

    private static String providerEtag(
            String relativePath,
            AppSandboxOpenedFileMetadata metadata
    ) {
        // Device/inode/ctime never cross the wire: they are folded into one
        // non-reversible identity together with the logical path.
        // 中文：描述符身份只进入不可逆哈希，不暴露本地 inode 或设备号。
        String identity = relativePath + '\0' + metadata.opaqueIdentityInput;
        return "app-sandbox:" + ProviderOpaqueIds.stable(identity, 16) + ":"
                + metadata.modifiedUnixMillis + ":" + metadata.sizeBytes;
    }

    private static File uploadPartialFile(File destination) {
        return new File(
                destination.getParentFile(),
                "." + destination.getName() + ".droidmatch-upload-part"
        );
    }

    private static boolean isUploadPartialFileName(String fileName) {
        return fileName.startsWith(".") && fileName.endsWith(".droidmatch-upload-part");
    }

    private static final class FileChannelAppSandboxPartialOutput
            implements AppSandboxPartialOutput {
        private final FileChannel channel;

        private FileChannelAppSandboxPartialOutput(FileChannel channel) {
            this.channel = channel;
        }

        @Override
        public void write(byte[] data) throws IOException {
            ByteBuffer buffer = ByteBuffer.wrap(data);
            while (buffer.hasRemaining()) {
                channel.write(buffer);
            }
        }

        @Override
        public void synchronize() throws IOException {
            // Final success must cover durable payload bytes, not only an atomic
            // directory-entry swap. 中文：最终成功前先同步同一 partial 描述符。
            channel.force(true);
        }

        @Override
        public void close() throws IOException {
            channel.close();
        }
    }

    private static DmFileProvider.ProviderCatalogException error(
            ErrorCode code,
            String message
    ) {
        return new DmFileProvider.ProviderCatalogException(code, message);
    }
}
