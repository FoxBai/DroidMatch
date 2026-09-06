package app.droidmatch.m1;

/** Explicit process-lifetime consent, separate from Android package visibility.
 * 中文：默认关闭；停止安全 USB 或进程退出后必须重新主动开启。 */
final class ApplicationAccess {
    static final ApplicationAccess PRODUCT = new ApplicationAccess();
    private boolean enabled;
    private long generation = 1;

    synchronized long generation() {
        return enabled ? generation : 0;
    }

    synchronized void setEnabled(boolean enabled) {
        this.enabled = enabled;
        generation++;
    }
}
