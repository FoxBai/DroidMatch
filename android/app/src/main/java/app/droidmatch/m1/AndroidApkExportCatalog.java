package app.droidmatch.m1;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Build;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;
import app.droidmatch.proto.v1.ErrorCode;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Only publicly readable, complete installed code; PackageManager paths stay private.
 * 中文：不读取应用数据；公开资源包与代码包不一致时拒绝导出。 */
final class AndroidApkExportCatalog implements ApkExportCatalog {
    // Android's Linux UAPI value (asm-generic/fcntl.h) predates its API 27 SDK
    // constant. Preserve atomic close-on-exec on API 26 without hidden APIs.
    // 中文：使用 Android 内核已有标志，兼容尚未公开该常量的 API 26。
    private static final int API_26_O_CLOEXEC = 0x80000;
    private final PackageManager packages;
    private final ApplicationAccess applications;
    private final ApkExportAccess exports;

    AndroidApkExportCatalog(Context context, ApplicationAccess applications, ApkExportAccess exports) {
        packages = context.getApplicationContext().getPackageManager();
        this.applications = applications; this.exports = exports;
    }

    @Override public long exportGeneration() { return exports.generation(); }
    @Override public long applicationGeneration() { return applications.generation(); }

    @Override public Snapshot capture(String identifier) throws DmFileProvider.ProviderCatalogException {
        Metadata metadata = metadata(identifier);
        List<StructStat> identities = new ArrayList<>();
        List<Component> components = new ArrayList<>();
        for (int i = 0; i < metadata.paths.length; i++) {
            StructStat stat = stat(metadata.paths[i]);
            identities.add(stat);
            components.add(new Component(metadata.names[i], stat.st_size));
        }
        Captured result = new Captured(identifier, metadata, identities, components);
        validate(result, true);
        return result;
    }

    @Override public void validate(Snapshot snapshot, boolean complete)
            throws DmFileProvider.ProviderCatalogException {
        Captured captured = captured(snapshot);
        Metadata current = metadata(snapshot.packageIdentifier);
        if (!captured.metadata.matches(current)) throw failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
        if (complete) {
            for (int i = 0; i < current.paths.length; i++) {
                if (!sameFile(captured.identities.get(i), stat(current.paths[i]))) {
                    throw failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
                }
            }
        }
    }

    @Override public DmFileProvider.DownloadReader open(Snapshot snapshot, int index, int chunkSize)
            throws DmFileProvider.ProviderCatalogException {
        Captured captured = captured(snapshot);
        validate(captured, true);
        String path = captured.metadata.paths[index];
        StructStat expected = captured.identities.get(index);
        FileDescriptor descriptor = null;
        FileInputStream input = null;
        try {
            int closeOnExec = Build.VERSION.SDK_INT >= 27 ? OsConstants.O_CLOEXEC : API_26_O_CLOEXEC;
            int flags = OsConstants.O_RDONLY | OsConstants.O_NOFOLLOW | closeOnExec;
            descriptor = Os.open(path, flags, 0);
            if (!sameFile(expected, Os.fstat(descriptor)) || !sameFile(expected, stat(path))) {
                throw failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
            }
            input = new FileInputStream(descriptor);
            return new Reader(input, descriptor, path, expected, chunkSize);
        } catch (ErrnoException failure) {
            throw failure(mapErrno(failure));
        } catch (SecurityException failure) {
            throw failure(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED);
        } finally {
            // The returned reader owns the stream/descriptor together.
            if (input == null && descriptor != null) {
                try { Os.close(descriptor); } catch (ErrnoException ignored) { }
            }
        }
    }

    @SuppressWarnings("deprecation")
    private Metadata metadata(String identifier) throws DmFileProvider.ProviderCatalogException {
        if (exportGeneration() == 0 || applicationGeneration() == 0) {
            throw failure(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED);
        }
        try {
            Intent query = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    .setPackage(identifier);
            List<ResolveInfo> activities = Build.VERSION.SDK_INT >= 33
                    ? packages.queryIntentActivities(query, PackageManager.ResolveInfoFlags.of(0))
                    : packages.queryIntentActivities(query, 0);
            if (activities.size() > ApplicationListProvider.MAX_APPLICATIONS * 2) {
                throw failure(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY);
            }
            boolean visible = false;
            for (ResolveInfo result : activities) {
                if (result.activityInfo != null && result.activityInfo.enabled && result.activityInfo.exported
                        && identifier.equals(result.activityInfo.packageName)
                        && result.activityInfo.applicationInfo != null
                        && result.activityInfo.applicationInfo.enabled) { visible = true; break; }
            }
            if (!visible) throw failure(ErrorCode.ERROR_CODE_NOT_FOUND);
            PackageInfo info = Build.VERSION.SDK_INT >= 33
                    ? packages.getPackageInfo(identifier, PackageManager.PackageInfoFlags.of(0))
                    : packages.getPackageInfo(identifier, 0);
            ApplicationInfo app = info.applicationInfo;
            if (app == null || !app.enabled || !identifier.equals(app.packageName)
                    || !publicCode(app.sourceDir, app.publicSourceDir)) {
                throw failure(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY);
            }
            int splits = app.splitNames == null ? 0 : app.splitNames.length;
            if (splits >= ApkExportLease.MAX_COMPONENTS
                    || count(app.splitSourceDirs) != splits || count(app.splitPublicSourceDirs) != splits) {
                throw failure(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY);
            }
            String[] paths = new String[splits + 1];
            String[] names = new String[splits + 1];
            paths[0] = app.sourceDir; names[0] = "";
            Set<String> uniquePaths = new HashSet<>(); uniquePaths.add(paths[0]);
            Set<String> uniqueNames = new HashSet<>();
            for (int i = 0; i < splits; i++) {
                String name = app.splitNames[i];
                String path = app.splitSourceDirs[i];
                if (!ApkExportLease.validSplitName(name, false) || !uniqueNames.add(name)
                        || !publicCode(path, app.splitPublicSourceDirs[i]) || !uniquePaths.add(path)) {
                    throw failure(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY);
                }
                paths[i + 1] = path; names[i + 1] = name;
            }
            long version = Build.VERSION.SDK_INT >= 28
                    ? info.getLongVersionCode() : Integer.toUnsignedLong(info.versionCode);
            return new Metadata(paths, names, version, info.lastUpdateTime);
        } catch (PackageManager.NameNotFoundException missing) {
            throw failure(ErrorCode.ERROR_CODE_NOT_FOUND);
        } catch (SecurityException denied) {
            throw failure(ErrorCode.ERROR_CODE_PERMISSION_REQUIRED);
        } catch (RuntimeException unavailable) {
            throw failure(ErrorCode.ERROR_CODE_INTERNAL);
        }
    }

    private static int count(String[] values) { return values == null ? 0 : values.length; }
    private static boolean publicCode(String code, String readable) {
        return code != null && code.length() <= 4096 && code.equals(readable)
                && new File(code).isAbsolute() && code.indexOf('\0') < 0;
    }

    private static StructStat stat(String path) throws DmFileProvider.ProviderCatalogException {
        try {
            StructStat stat = Os.lstat(path);
            if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_size <= 0
                    || stat.st_size > ApkExportLease.MAX_COMPONENT_BYTES) {
                throw failure(ErrorCode.ERROR_CODE_UNSUPPORTED_CAPABILITY);
            }
            return stat;
        } catch (ErrnoException error) { throw failure(mapErrno(error)); }
    }

    private static boolean sameFile(StructStat a, StructStat b) {
        if (a.st_dev != b.st_dev || a.st_ino != b.st_ino || a.st_mode != b.st_mode
                || a.st_uid != b.st_uid || a.st_gid != b.st_gid
                || a.st_size != b.st_size || a.st_nlink != b.st_nlink
                || a.st_mtime != b.st_mtime || a.st_ctime != b.st_ctime) return false;
        // Nanosecond stat fields were added in API 27. API 26 also binds the
        // package's version/update time and complete immutable installed path set.
        return Build.VERSION.SDK_INT < 27 || (a.st_mtim.tv_nsec == b.st_mtim.tv_nsec
                && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec);
    }

    private static ErrorCode mapErrno(ErrnoException error) {
        if (error.errno == OsConstants.EACCES || error.errno == OsConstants.EPERM) {
            return ErrorCode.ERROR_CODE_PERMISSION_REQUIRED;
        }
        return error.errno == OsConstants.ENOENT ? ErrorCode.ERROR_CODE_NOT_FOUND
                : ErrorCode.ERROR_CODE_INVALID_ARGUMENT;
    }

    private static Captured captured(Snapshot value) throws DmFileProvider.ProviderCatalogException {
        if (!(value instanceof Captured)) throw failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
        return (Captured) value;
    }
    private static DmFileProvider.ProviderCatalogException failure(ErrorCode code) {
        return ApkExportLease.failure(code);
    }

    private static final class Metadata {
        final String[] paths;
        final String[] names;
        final long version;
        final long updated;
        Metadata(String[] paths, String[] names, long version, long updated) {
            this.paths = paths; this.names = names; this.version = version; this.updated = updated;
        }
        boolean matches(Metadata other) {
            return version == other.version && updated == other.updated
                    && Arrays.equals(paths, other.paths) && Arrays.equals(names, other.names);
        }
    }
    private static final class Captured extends Snapshot {
        final Metadata metadata;
        final List<StructStat> identities;
        Captured(String identifier, Metadata metadata, List<StructStat> identities, List<Component> parts) {
            super(identifier, metadata.version, metadata.updated, parts);
            this.metadata = metadata; this.identities = identities;
        }
    }

    private static final class Reader implements DmFileProvider.DownloadReader {
        private final FileInputStream input;
        private final FileDescriptor descriptor;
        private final String path;
        private final StructStat identity;
        private final int chunkSize;
        private long offset;
        private boolean closed;
        Reader(FileInputStream input, FileDescriptor descriptor, String path, StructStat identity, int size) {
            this.input = input; this.descriptor = descriptor; this.path = path;
            this.identity = identity; chunkSize = size;
        }
        @Override public DmFileProvider.DownloadChunk readNextChunk()
                throws DmFileProvider.ProviderCatalogException {
            if (closed) throw failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
            try {
                check();
                byte[] data = ProviderDownloadReaders.readAtMost(input,
                        (int) Math.min(chunkSize, identity.st_size - offset));
                check();
                if (data.length == 0) throw failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
                offset += data.length;
                boolean last = offset == identity.st_size;
                if (last) close();
                return new DmFileProvider.DownloadChunk(data, identity.st_size, 0, "", last);
            } catch (IOException | ErrnoException error) {
                close(); throw failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
            } catch (DmFileProvider.ProviderCatalogException | RuntimeException error) {
                close(); throw error;
            }
        }
        private void check() throws ErrnoException, DmFileProvider.ProviderCatalogException {
            if (!sameFile(identity, Os.fstat(descriptor)) || !sameFile(identity, stat(path))) {
                throw failure(ErrorCode.ERROR_CODE_INVALID_ARGUMENT);
            }
        }
        @Override public void close() {
            if (!closed) { closed = true; try { input.close(); } catch (IOException ignored) { } }
        }
    }
}
