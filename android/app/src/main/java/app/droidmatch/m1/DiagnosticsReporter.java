package app.droidmatch.m1;

import android.os.SystemClock;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

public final class DiagnosticsReporter {
    private static final int MAX_RECENT_EVENTS = 100;

    private final Object eventLock = new Object();
    private final Clock clock;
    private final ThreadNameProvider threadNameProvider;
    private final ArrayDeque<Event> recentEvents = new ArrayDeque<>();
    private final ConcurrentHashMap<String, AtomicLong> counters = new ConcurrentHashMap<>();
    private String currentState = "unknown";

    public DiagnosticsReporter() {
        this(SystemClock::elapsedRealtimeNanos, () -> Thread.currentThread().getName());
    }

    DiagnosticsReporter(Clock clock, ThreadNameProvider threadNameProvider) {
        this.clock = clock;
        this.threadNameProvider = threadNameProvider;
    }

    public void recordState(String state) {
        synchronized (eventLock) {
            if (isServiceState(state)) {
                currentState = state;
            }
            addEventLocked("state", state, null);
        }
    }

    public void recordError(String code, Throwable throwable) {
        String message = throwable.getMessage() == null ? "" : redact(throwable.getMessage());
        synchronized (eventLock) {
            addEventLocked("error", code + ":" + throwable.getClass().getSimpleName(), message);
        }
    }

    public void recordCounter(String name, long delta) {
        counters.computeIfAbsent(name, ignored -> new AtomicLong()).addAndGet(delta);
    }

    public List<String> recentEvents() {
        synchronized (eventLock) {
            ArrayList<String> formatted = new ArrayList<>();
            for (Event event : recentEvents) {
                formatted.add(event.format());
            }
            return formatted;
        }
    }

    public List<String> recentErrorEvents() {
        synchronized (eventLock) {
            ArrayList<String> formatted = new ArrayList<>();
            for (Event event : recentEvents) {
                if ("error".equals(event.kind)) {
                    formatted.add(event.format());
                }
            }
            return formatted;
        }
    }

    public Map<String, Long> counters() {
        HashMap<String, Long> snapshot = new HashMap<>();
        for (Map.Entry<String, AtomicLong> counter : counters.entrySet()) {
            snapshot.put(counter.getKey(), counter.getValue().get());
        }
        return snapshot;
    }

    public String currentState() {
        synchronized (eventLock) {
            return currentState;
        }
    }

    private void addEventLocked(String kind, String code, String message) {
        Event event = new Event(
                clock.elapsedRealtimeNanos(),
                threadNameProvider.currentThreadName(),
                kind,
                code,
                message
        );
        recentEvents.addLast(event);
        while (recentEvents.size() > MAX_RECENT_EVENTS) {
            recentEvents.removeFirst();
        }
    }

    private static boolean isServiceState(String state) {
        return state.startsWith("service.")
                || state.startsWith("adb.endpoint.")
                || state.startsWith("rpc.session.");
    }

    private static String redact(String value) {
        return value
                .replaceAll("/Users/[^/\\s:]+", "/Users/<redacted>")
                .replaceAll("(?i)(/storage/emulated/0|/sdcard|/mnt/media_rw|/storage/[A-F0-9-]+)(/[^\\s:]*)?", "/storage/<redacted>")
                .replaceAll("(?i)content://[^\\s:]+", "content://<redacted>")
                .replaceAll("(?i)(authorization\\s*[:=]\\s*)(bearer\\s+)?\\S+", "$1<redacted>")
                .replaceAll("(?i)(token|secret|password|android_id|serial|device_serial)=\\S+", "$1=<redacted>");
    }

    interface Clock {
        long elapsedRealtimeNanos();
    }

    interface ThreadNameProvider {
        String currentThreadName();
    }

    private static final class Event {
        private final long elapsedRealtimeNanos;
        private final String threadName;
        private final String kind;
        private final String code;
        private final String message;

        private Event(long elapsedRealtimeNanos, String threadName, String kind, String code, String message) {
            this.elapsedRealtimeNanos = elapsedRealtimeNanos;
            this.threadName = threadName;
            this.kind = kind;
            this.code = code;
            this.message = message;
        }

        private String format() {
            String base = elapsedRealtimeNanos + ":" + threadName + ":" + kind + ":" + code;
            if (message == null || message.isEmpty()) {
                return base;
            }
            return base + ":" + message;
        }
    }
}
