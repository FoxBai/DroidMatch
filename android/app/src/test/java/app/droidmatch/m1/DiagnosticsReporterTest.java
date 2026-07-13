package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.ArrayList;

import org.junit.Test;

public final class DiagnosticsReporterTest {
    @Test
    public void countersHandleConcurrentUpdates() throws Exception {
        AtomicLong clock = new AtomicLong(1);
        DiagnosticsReporter reporter = new DiagnosticsReporter(clock::getAndIncrement, () -> "test-thread");
        int threadCount = 8;
        int iterations = 1_000;
        ExecutorService executor = Executors.newFixedThreadPool(threadCount);
        CountDownLatch start = new CountDownLatch(1);
        ArrayList<Future<?>> futures = new ArrayList<>();

        for (int thread = 0; thread < threadCount; thread++) {
            futures.add(executor.submit(() -> {
                start.await();
                for (int index = 0; index < iterations; index++) {
                    reporter.recordCounter("rpc.frames.received", 1);
                }
                return null;
            }));
        }

        start.countDown();
        for (Future<?> future : futures) {
            future.get(5, TimeUnit.SECONDS);
        }
        executor.shutdownNow();

        Map<String, Long> counters = reporter.counters();
        assertEquals(Long.valueOf(threadCount * iterations), counters.get("rpc.frames.received"));
    }

    @Test
    public void errorsAreRedactedBeforeSnapshot() {
        AtomicLong clock = new AtomicLong(1);
        DiagnosticsReporter reporter = new DiagnosticsReporter(clock::getAndIncrement, () -> "test-thread");

        reporter.recordError(
                "diagnostics.raw",
                new IllegalStateException(
                        "/Users/alice/secret.txt /storage/emulated/0/DCIM/photo.jpg "
                                + "content://media/external/images/media/1 Authorization: Bearer abc123 "
                                + "token=topsecret serial=ABC123"
                )
        );

        List<String> errors = reporter.recentErrorEvents();
        assertEquals(1, errors.size());
        String event = errors.get(0);
        assertTrue(event.contains("/Users/<redacted>"));
        assertTrue(event.contains("/storage/<redacted>"));
        assertTrue(event.contains("content://<redacted>"));
        assertTrue(event.contains("Authorization: <redacted>"));
        assertTrue(event.contains("token=<redacted>"));
        assertTrue(event.contains("serial=<redacted>"));
        assertFalse(event.contains("alice"));
        assertFalse(event.contains("photo.jpg"));
        assertFalse(event.contains("abc123"));
        assertFalse(event.contains("ABC123"));
    }

    @Test
    public void recentEventsAreCappedAndStateTracksServiceEvents() {
        AtomicLong clock = new AtomicLong(1);
        DiagnosticsReporter reporter = new DiagnosticsReporter(clock::getAndIncrement, () -> "test-thread");

        for (int index = 0; index < 105; index++) {
            reporter.recordState("service.state." + index);
        }

        List<String> events = reporter.recentEvents();
        assertEquals(100, events.size());
        assertTrue(events.get(0).endsWith(":state:service.state.5"));
        assertTrue(events.get(99).endsWith(":state:service.state.104"));
        assertEquals("service.state.104", reporter.currentState());
    }

    @Test
    public void sessionEventsDoNotOverwriteEndpointCurrentState() {
        AtomicLong clock = new AtomicLong(1);
        DiagnosticsReporter reporter = new DiagnosticsReporter(clock::getAndIncrement, () -> "test-thread");

        reporter.recordState("adb.endpoint.listening:39001");
        reporter.recordState("rpc.session.open");
        reporter.recordState("rpc.session.closed:eof");

        assertEquals("adb.endpoint.listening:39001", reporter.currentState());
        assertTrue(reporter.recentEvents().stream()
                .anyMatch(event -> event.endsWith(":state:rpc.session.open")));
    }
}
