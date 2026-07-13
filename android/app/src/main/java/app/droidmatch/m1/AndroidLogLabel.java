package app.droidmatch.m1;

/**
 * Builds bounded Logcat labels without carrying exception text or stack traces.
 * 中文：构造有界 Logcat 标签，不把异常原文或堆栈带入系统日志。
 */
final class AndroidLogLabel {
    private AndroidLogLabel() {}

    static String error(String message, Throwable error) {
        String type = error == null ? "UnknownError" : error.getClass().getSimpleName();
        if (type == null || type.isEmpty()) {
            type = "UnknownError";
        }
        return message + " [" + type + "]";
    }
}
