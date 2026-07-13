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
        String exceptionType = throwable == null
                ? "UnknownError"
                : throwable.getClass().getSimpleName();
        if (exceptionType == null || exceptionType.isEmpty()) {
            exceptionType = "UnknownError";
        }
        synchronized (eventLock) {
            // Exception text is not an evidence field: unknown providers can
            // include personal names, document IDs, or local paths. Keep the
            // stable operation code and exception class, matching Logcat's
            // bounded label policy without relying on an incomplete redactor.
            addEventLocked("error", code + ":" + exceptionType, null);
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
                || state.startsWith("adb.endpoint.");
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
