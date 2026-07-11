package app.droidmatch.m1;

import app.droidmatch.proto.v1.ErrorCode;
import app.droidmatch.proto.v1.FileKind;
import app.droidmatch.proto.v1.SortField;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.channels.FileChannel;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/**
 * App-private filesystem catalog behind DroidMatch logical paths.
 *
 * <p>The facade strips the {@code dm://app-sandbox/} root before entering this
 * class. Every remaining path is canonicalized below the app-owned root; hidden
 * upload partials stay resumable but never appear in listings.</p>
 */
final class AndroidAppSandboxCatalog implements DmFileProvider.AppSandboxCatalog {
    private final File rootDirectory;

    AndroidAppSandboxCatalog(File rootDirectory) {
        this.rootDirectory = rootDirectory;
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

        File[] childFiles = directory.listFiles();
        if (childFiles == null) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "app sandbox listing failed");
        }

        ArrayList<DmFileProvider.AppSandboxItem> items = new ArrayList<>();
        for (File child : childFiles) {
            if (isUploadPartialFileName(child.getName())) {
                continue;
            }
            if (!ProviderNameSearch.matches(child.getName(), query.searchQuery())) {
                continue;
            }
            items.add(appSandboxItem(relativePath, child));
        }
        items.sort(appSandboxComparator(query.sortField(), query.descending()));
        return pageAppSandboxItems(items, query.offset(), query.limit());
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
        if (offsetBytes > file.length()) {
            throw error(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "requested_offset_bytes is beyond end of file"
            );
        }

        try {
            FileInputStream inputStream = new FileInputStream(file);
            FileChannel channel = inputStream.getChannel();
            channel.position(offsetBytes);
            return ProviderDownloadReaders.stream(
                    inputStream,
                    offsetBytes,
                    chunkSizeBytes,
                    file.length(),
                    file.lastModified(),
                    providerEtag(relativePath, file),
                    "app sandbox read failed"
            );
        } catch (FileNotFoundException exception) {
            throw error(ErrorCode.ERROR_CODE_NOT_FOUND, "app sandbox file is not available");
        } catch (IllegalArgumentException exception) {
            throw error(
                    ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                    "requested_offset_bytes must be non-negative"
            );
        } catch (IOException exception) {
            throw error(ErrorCode.ERROR_CODE_INTERNAL, "app sandbox read failed");
        }
    }

    @Override
    public DmFileProvider.UploadWriter openUploadFile(
            String relativePath,
            long offsetBytes,
            long expectedSizeBytes
    ) throws DmFileProvider.ProviderCatalogException {
        File destination = resolve(relativePath);
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
            if (offsetBytes == 0) {
                partialFile.delete();
            } else if (!partialFile.isFile()) {
                throw error(
                        ErrorCode.ERROR_CODE_NOT_FOUND,
                        "app sandbox upload partial is not available"
                );
            } else if (partialFile.length() < offsetBytes) {
                throw error(
                        ErrorCode.ERROR_CODE_INVALID_ARGUMENT,
                        "requested_offset_bytes does not match app sandbox upload partial"
                );
            } else if (partialFile.length() > offsetBytes) {
                try (RandomAccessFile partialAccess = new RandomAccessFile(partialFile, "rw")) {
                    partialAccess.setLength(offsetBytes);
                }
            }
            return new AppSandboxUploadWriter(
                    destination,
                    partialFile,
                    new FileOutputStream(partialFile, offsetBytes > 0),
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
        if (recursive && target.isDirectory()) {
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

    private static DmFileProvider.AppSandboxPage pageAppSandboxItems(
            List<DmFileProvider.AppSandboxItem> items,
            int offset,
            int limit
    ) {
        if (offset >= items.size()) {
            return new DmFileProvider.AppSandboxPage(new ArrayList<>(), false);
        }
        int endExclusive = Math.min(items.size(), offset + limit);
        boolean hasMore = endExclusive < items.size();
        return new DmFileProvider.AppSandboxPage(
                new ArrayList<>(items.subList(offset, endExclusive)),
                hasMore
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

    private static String providerEtag(String relativePath, File file) {
        return "app-sandbox:" + ProviderOpaqueIds.stable(relativePath, 8) + ":"
                + file.lastModified() + ":" + file.length();
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

    private static DmFileProvider.ProviderCatalogException error(
            ErrorCode code,
            String message
    ) {
        return new DmFileProvider.ProviderCatalogException(code, message);
    }
}
