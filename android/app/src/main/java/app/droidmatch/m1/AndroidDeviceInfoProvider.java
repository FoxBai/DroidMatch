package app.droidmatch.m1;

import android.content.Context;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Environment;
import android.os.StatFs;

import app.droidmatch.proto.v1.DeviceInfoResponse;

import java.util.Locale;

public final class AndroidDeviceInfoProvider {
    private final Context context;
    private final PermissionStateProvider permissionStateProvider;

    public AndroidDeviceInfoProvider(Context context, PermissionStateProvider permissionStateProvider) {
        this.context = context.getApplicationContext();
        this.permissionStateProvider = permissionStateProvider;
    }

    public DeviceInfoResponse snapshot() {
        StatFs dataStats = new StatFs(Environment.getDataDirectory().getAbsolutePath());
        int safRootCount = permissionStateProvider.persistedSafRootCount();

        return DeviceInfoResponse.newBuilder()
                .setDeviceId(deviceId())
                .setManufacturer(safe(Build.MANUFACTURER))
                .setModel(safe(Build.MODEL))
                .setAndroidVersion(safe(Build.VERSION.RELEASE))
                .setSdkInt(Build.VERSION.SDK_INT)
                .setTotalStorageBytes(dataStats.getTotalBytes())
                .setFreeStorageBytes(dataStats.getAvailableBytes())
                .setBatteryPercent(batteryPercent())
                .putPermissions("media_read", toProto(permissionStateProvider.publicMediaReadState()))
                .putPermissions("notifications", toProto(permissionStateProvider.notificationPostState()))
                .putPermissions(
                        "saf_roots",
                        safRootCount > 0
                                ? app.droidmatch.proto.v1.PermissionState.PERMISSION_STATE_GRANTED
                                : app.droidmatch.proto.v1.PermissionState.PERMISSION_STATE_NEEDS_USER_ACTION
                )
                .build();
    }

    private int batteryPercent() {
        BatteryManager batteryManager = context.getSystemService(BatteryManager.class);
        if (batteryManager == null) {
            return -1;
        }
        int percent = batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY);
        return percent >= 0 && percent <= 100 ? percent : -1;
    }

    private static String deviceId() {
        return (safe(Build.MANUFACTURER) + "-" + safe(Build.DEVICE) + "-" + safe(Build.ID))
                .toLowerCase(Locale.ROOT)
                .replaceAll("[^a-z0-9_.-]+", "-");
    }

    private static String safe(String value) {
        return value == null || value.isEmpty() ? "unknown" : value;
    }

    private static app.droidmatch.proto.v1.PermissionState toProto(
            PermissionStateProvider.PermissionState state
    ) {
        switch (state) {
            case GRANTED:
                return app.droidmatch.proto.v1.PermissionState.PERMISSION_STATE_GRANTED;
            case DENIED:
                return app.droidmatch.proto.v1.PermissionState.PERMISSION_STATE_DENIED;
            case NEEDS_USER_ACTION:
                return app.droidmatch.proto.v1.PermissionState.PERMISSION_STATE_NEEDS_USER_ACTION;
            case NOT_APPLICABLE:
                return app.droidmatch.proto.v1.PermissionState.PERMISSION_STATE_NOT_APPLICABLE;
            default:
                return app.droidmatch.proto.v1.PermissionState.PERMISSION_STATE_UNSPECIFIED;
        }
    }
}
