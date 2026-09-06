package app.droidmatch.m1;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Build;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

final class AndroidApplicationCatalog implements ApplicationCatalog {
    private final PackageManager packages;
    private final ApplicationAccess access;

    AndroidApplicationCatalog(Context context, ApplicationAccess access) {
        this.packages = context.getApplicationContext().getPackageManager();
        this.access = access;
    }

    @Override public long accessGeneration() { return access.generation(); }

    @Override
    @SuppressWarnings("deprecation")
    public List<Entry> queryLaunchableApplications() {
        long generation = access.generation();
        if (generation == 0) throw new SecurityException("application sharing disabled");
        Intent launcher = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        List<ResolveInfo> activities = Build.VERSION.SDK_INT >= 33
                ? packages.queryIntentActivities(launcher, PackageManager.ResolveInfoFlags.of(0))
                : packages.queryIntentActivities(launcher, 0);
        // The SDK materializes its result; bound all application-owned projection
        // and subsequent per-package work before processing it. 中文：不宣称限制框架内部堆。
        if (activities.size() > ApplicationListProvider.MAX_APPLICATIONS * 2) {
            throw new IllegalStateException("application activity limit exceeded");
        }
        Set<String> seen = new HashSet<>();
        List<Entry> entries = new ArrayList<>();
        for (ResolveInfo activity : activities) {
            if (access.generation() != generation) {
                throw new SecurityException("application sharing changed");
            }
            if (activity.activityInfo == null || !activity.activityInfo.enabled
                    || !activity.activityInfo.exported
                    || activity.activityInfo.applicationInfo == null
                    || !activity.activityInfo.applicationInfo.enabled) continue;
            String identifier = activity.activityInfo.packageName;
            if (!ApplicationListProvider.validIdentifier(identifier)) {
                throw new IllegalStateException("application identifier is invalid");
            }
            if (!seen.add(identifier)) continue;
            if (seen.size() > ApplicationListProvider.MAX_APPLICATIONS) {
                throw new IllegalStateException("application package limit exceeded");
            }
            try {
                PackageInfo info = Build.VERSION.SDK_INT >= 33
                        ? packages.getPackageInfo(identifier, PackageManager.PackageInfoFlags.of(0))
                        : packages.getPackageInfo(identifier, 0);
                ApplicationInfo app = info.applicationInfo;
                if (app == null || !app.enabled) continue;
                CharSequence label = app.loadLabel(packages);
                long versionCode = Build.VERSION.SDK_INT >= 28
                        ? info.getLongVersionCode() : Integer.toUnsignedLong(info.versionCode);
                entries.add(new Entry(identifier, boundedText(label == null ? identifier : label),
                        boundedText(info.versionName), versionCode, info.lastUpdateTime,
                        (app.flags & ApplicationInfo.FLAG_SYSTEM) != 0));
            } catch (PackageManager.NameNotFoundException ignored) {
                // An uninstall between launcher enumeration and metadata read is
                // normal; the next page's snapshot will reject stale cursors.
            }
        }
        return entries;
    }

    private static String boundedText(CharSequence value) {
        // Bound retained platform text before collecting the complete catalog.
        // 中文：不能等到整份清单收集后才限制应用名称与版本字符串。
        return value == null ? "" : value.subSequence(0,
                Math.min(value.length(), ApplicationListProvider.MAX_SOURCE_TEXT_LENGTH)).toString();
    }
}
