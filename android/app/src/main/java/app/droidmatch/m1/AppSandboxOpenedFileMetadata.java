package app.droidmatch.m1;

import android.os.Build;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.attribute.BasicFileAttributes;

/** Metadata bound to the App Sandbox file selected for one download. */
final class AppSandboxOpenedFileMetadata {
    final boolean regularFile;
    final long sizeBytes;
    final long modifiedUnixMillis;
    final String opaqueIdentityInput;

    AppSandboxOpenedFileMetadata(
            boolean regularFile,
            long sizeBytes,
            long modifiedUnixMillis,
            String opaqueIdentityInput
    ) {
        this.regularFile = regularFile;
        this.sizeBytes = sizeBytes;
        this.modifiedUnixMillis = modifiedUnixMillis;
        this.opaqueIdentityInput = opaqueIdentityInput;
    }
}

interface AppSandboxOpenedFileMetadataReader {
    AppSandboxOpenedFileMetadata read(File file, FileInputStream inputStream) throws IOException;
}

/** Product reader: every identity field comes from the already-open descriptor. */
final class AndroidAppSandboxOpenedFileMetadataReader
        implements AppSandboxOpenedFileMetadataReader {
    @Override
    public AppSandboxOpenedFileMetadata read(File file, FileInputStream inputStream)
            throws IOException {
        try {
            StructStat stat = Os.fstat(inputStream.getFD());
            long modifiedNanos = 0;
            long changedNanos = 0;
            if (Build.VERSION.SDK_INT >= 27) {
                modifiedNanos = stat.st_mtim.tv_nsec;
                changedNanos = stat.st_ctim.tv_nsec;
            }
            return new AppSandboxOpenedFileMetadata(
                    OsConstants.S_ISREG(stat.st_mode),
                    stat.st_size,
                    unixMillis(stat.st_mtime, modifiedNanos),
                    stat.st_dev + ":" + stat.st_ino + ":" + stat.st_ctime + ":" + changedNanos
            );
        } catch (ErrnoException exception) {
            throw new IOException("app sandbox descriptor metadata failed", exception);
        }
    }

    private static long unixMillis(long seconds, long nanoseconds) {
        return seconds * 1_000L + nanoseconds / 1_000_000L;
    }
}

/**
 * Host-JVM fixture adapter. Product construction always injects the Android
 * descriptor reader above; tests use NIO because android.system stubs do not run
 * on the host JVM. 中文：该适配器仅服务本机 JVM 测试，产品不得静默降级。
 */
final class NioAppSandboxOpenedFileMetadataReader
        implements AppSandboxOpenedFileMetadataReader {
    @Override
    public AppSandboxOpenedFileMetadata read(File file, FileInputStream inputStream)
            throws IOException {
        BasicFileAttributes attributes = Files.readAttributes(
                file.toPath(),
                BasicFileAttributes.class,
                LinkOption.NOFOLLOW_LINKS
        );
        Object fileKey = attributes.fileKey();
        String identity = fileKey == null
                ? "created:" + attributes.creationTime().toMillis()
                : fileKey.toString();
        return new AppSandboxOpenedFileMetadata(
                attributes.isRegularFile(),
                attributes.size(),
                attributes.lastModifiedTime().toMillis(),
                identity
        );
    }
}
