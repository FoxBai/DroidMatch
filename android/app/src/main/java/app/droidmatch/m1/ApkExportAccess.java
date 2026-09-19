package app.droidmatch.m1;

/** APK-byte consent is distinct from metadata sharing and never persisted.
 * 中文：APK 字节导出单独授权；停止安全连接后必须重新开启。 */
final class ApkExportAccess {
    static final ApkExportAccess PRODUCT = new ApkExportAccess();
    private boolean enabled;
    private long generation = 1;

    synchronized long generation() { return enabled ? generation : 0; }
    synchronized void setEnabled(boolean value) { enabled = value; generation++; }
}
