package app.droidmatch.m1;

import app.droidmatch.proto.v1.ApkInstallState;
import app.droidmatch.proto.v1.ErrorCode;

import java.text.Normalizer;
import java.util.Locale;
import java.util.regex.Pattern;

/** Shared bounds and lifecycle classification; no platform state or private paths. */
final class ApkInstallPolicy {
    static final long MAX_BYTES = 1_073_741_824L;
    static final int MAX_RECORDS = 8;
    static final String DESTINATION_PREFIX = "dm://apk-install/";
    private static final Pattern ID = Pattern.compile(
            "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    );

    private ApkInstallPolicy() {}

    static boolean validId(String value) {
        return value != null && value.length() == 36 && ID.matcher(value).matches();
    }

    static String displayName(String input) throws DmFileProvider.ProviderCatalogException {
        if (input == null || input.length() > 640) throw invalid();
        String name = Normalizer.normalize(input, Normalizer.Form.NFC);
        if (name.isEmpty() || name.codePointCount(0, name.length()) > 160
                || !name.toLowerCase(Locale.ROOT).endsWith(".apk")
                || name.contains("/") || name.contains("\\")) throw invalid();
        for (int i = 0; i < name.length();) {
            int codePoint = name.codePointAt(i);
            int type = Character.getType(codePoint);
            if (Character.isISOControl(codePoint) || type == Character.FORMAT
                    || type == Character.SURROGATE || type == Character.LINE_SEPARATOR
                    || type == Character.PARAGRAPH_SEPARATOR) throw invalid();
            i += Character.charCount(codePoint);
        }
        return name;
    }

    static String destination(String operationId) {
        return DESTINATION_PREFIX + operationId + "/base.apk";
    }

    static String destinationId(String path) throws DmFileProvider.ProviderCatalogException {
        if (path == null || !path.startsWith(DESTINATION_PREFIX)
                || path.length() != DESTINATION_PREFIX.length() + 45) throw invalid();
        String id = path.substring(DESTINATION_PREFIX.length(), DESTINATION_PREFIX.length() + 36);
        if (!validId(id) || !path.equals(destination(id))) throw invalid();
        return id;
    }

    static boolean unsubmitted(ApkInstallState state) {
        return state == ApkInstallState.APK_INSTALL_STATE_WAITING_FOR_UPLOAD
                || state == ApkInstallState.APK_INSTALL_STATE_UPLOADING
                || state == ApkInstallState.APK_INSTALL_STATE_WAITING_FOR_ANDROID_APPROVAL
                || state == ApkInstallState.APK_INSTALL_STATE_CLEANUP_REQUIRED;
    }

    static boolean terminal(ApkInstallState state) {
        return state == ApkInstallState.APK_INSTALL_STATE_SUCCEEDED
                || state == ApkInstallState.APK_INSTALL_STATE_FAILED
                || state == ApkInstallState.APK_INSTALL_STATE_CANCELLED;
    }

    static DmFileProvider.ProviderCatalogException invalid() {
        return error(ErrorCode.ERROR_CODE_INVALID_ARGUMENT, "APK installation arguments are invalid");
    }

    static DmFileProvider.ProviderCatalogException error(ErrorCode code, String label) {
        return new DmFileProvider.ProviderCatalogException(code, label);
    }
}
