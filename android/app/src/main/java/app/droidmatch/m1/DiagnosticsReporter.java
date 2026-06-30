package app.droidmatch.m1;

import android.os.SystemClock;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public final class DiagnosticsReporter {
    private static final int MAX_RECENT_EVENTS = 100;

    private final ArrayDeque<Event> recentEvents = new ArrayDeque<>();
    private final Map<String, Long> counters = new HashMap<>();
    private String currentState = "unknown";

    public synchronized void recordState(String state) {
        if (isServiceState(state)) {
            currentState = state;
        }
        addEvent("state", state, null);
    }

    public synchronized void recordError(String code, Throwable throwable) {
        String message = throwable.getMessage() == null ? "" : redact(throwable.getMessage());
        addEvent("error", code + ":" + throwable.getClass().getSimpleName(), message);
    }

    public synchronized void recordCounter(String name, long delta) {
        counters.put(name, counters.getOrDefault(name, 0L) + delta);
    }

    public synchronized List<String> recentEvents() {
        ArrayList<String> formatted = new ArrayList<>();
        for (Event event : recentEvents) {
            formatted.add(event.format());
        }
        return formatted;
    }

    public synchronized List<String> recentErrorEvents() {
        ArrayList<String> formatted = new ArrayList<>();
        for (Event event : recentEvents) {
            if ("error".equals(event.kind)) {
                formatted.add(event.format());
            }
        }
        return formatted;
    }

    public synchronized Map<String, Long> counters() {
        return new HashMap<>(counters);
    }

    public synchronized String currentState() {
        return currentState;
    }

    private void addEvent(String kind, String code, String message) {
        Event event = new Event(
                SystemClock.elapsedRealtimeNanos(),
                Thread.currentThread().getName(),
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
                .replaceAll("/Users/[^/\\s]+", "/Users/<redacted>")
                .replaceAll("(?i)(token|secret|password)=\\S+", "$1=<redacted>");
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
