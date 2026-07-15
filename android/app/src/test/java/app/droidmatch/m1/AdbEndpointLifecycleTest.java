package app.droidmatch.m1;

import static app.droidmatch.m1.AdbEndpointTestSupport.*;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import org.junit.Test;

public final class AdbEndpointLifecycleTest {
    @Test
    public void stopBeforeFactoryReturnsClosesCandidateWithoutPublishing() throws Exception {
        CountDownLatch factoryEntered = new CountDownLatch(1);
        CountDownLatch releaseFactory = new CountDownLatch(1);
        TrackingServerSocket candidate = new TrackingServerSocket();
        TestLifecycleListener lifecycle = new TestLifecycleListener();
        ExecutorService acceptExecutor = Executors.newSingleThreadExecutor();
        ExecutorService clientExecutor = Executors.newFixedThreadPool(1);
        AdbEndpoint endpoint = endpoint(
                (socket, timeout) -> {},
                lifecycle,
                () -> {
                    factoryEntered.countDown();
                    awaitUninterruptibly(releaseFactory);
                    return candidate;
                },
                acceptExecutor,
                clientExecutor,
                1
        );

        try {
            endpoint.start(0);
            assertTrue(factoryEntered.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
            endpoint.shutdown();
            releaseFactory.countDown();

            awaitCondition(candidate::wasClosed);
            assertEquals(0, lifecycle.listeningCalls.get());
            assertEquals(0, endpoint.actualPort());
        } finally {
            releaseFactory.countDown();
            endpoint.shutdown();
        }
    }

    @Test
    public void acceptedAfterShutdownIsClosedWithoutDispatch() throws Exception {
        TrackingSocket lateClient = new TrackingSocket();
        ControlledServerSocket listener = new ControlledServerSocket(lateClient);
        TestLifecycleListener lifecycle = new TestLifecycleListener();
        AtomicInteger handlerCalls = new AtomicInteger();
        DiagnosticsReporter reporter = reporter();
        AdbEndpoint endpoint = endpoint(
                (socket, timeout) -> handlerCalls.incrementAndGet(),
                reporter,
                lifecycle,
                () -> listener,
                Executors.newSingleThreadExecutor(),
                Executors.newFixedThreadPool(1),
                1
        );

        try {
            endpoint.start(39001);
            assertTrue(lifecycle.listening.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
            assertTrue(listener.acceptEntered.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));

            endpoint.shutdown();
            listener.releaseAccept.countDown();

            awaitCondition(lateClient::wasClosed);
            assertEquals(0, handlerCalls.get());
            assertEquals(0, endpoint.actualPort());
            assertEquals(1, lifecycle.stoppedCalls.get());
            assertEquals("adb.endpoint.stopped", reporter.currentState());
        } finally {
            listener.releaseAccept.countDown();
            endpoint.shutdown();
        }
    }

    @Test
    public void shutdownIsIdempotentAndStartCannotReviveEndpoint() throws Exception {
        TrackingSocket client = new TrackingSocket();
        ControlledServerSocket listener = new ControlledServerSocket(client);
        TestLifecycleListener lifecycle = new TestLifecycleListener();
        AtomicInteger factoryCalls = new AtomicInteger();
        AdbEndpoint endpoint = endpoint(
                (socket, timeout) -> {},
                lifecycle,
                () -> {
                    factoryCalls.incrementAndGet();
                    return listener;
                },
                Executors.newSingleThreadExecutor(),
                Executors.newFixedThreadPool(1),
                1
        );

        try {
            endpoint.start(39001);
            assertTrue(lifecycle.listening.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
            endpoint.shutdown();
            endpoint.shutdown();
            endpoint.start(39002);

            assertEquals(1, factoryCalls.get());
            assertEquals(1, lifecycle.listeningCalls.get());
            assertEquals(1, lifecycle.stoppedCalls.get());
            assertEquals(0, endpoint.actualPort());
        } finally {
            listener.releaseAccept.countDown();
            endpoint.shutdown();
        }
    }

    @Test
    public void concurrentShutdownWaitsForFailureTerminationCallbacks() throws Exception {
        BlockingFailureLifecycle lifecycle = new BlockingFailureLifecycle();
        DiagnosticsReporter reporter = reporter();
        AdbEndpoint endpoint = endpoint(
                (socket, timeout) -> {},
                reporter,
                lifecycle,
                FailingBindServerSocket::new,
                Executors.newSingleThreadExecutor(),
                Executors.newFixedThreadPool(1),
                1
        );
        ExecutorService shutdownCaller = Executors.newSingleThreadExecutor();
        CountDownLatch shutdownStarted = new CountDownLatch(1);
        CountDownLatch shutdownReturned = new CountDownLatch(1);

        try {
            endpoint.start(39001);
            assertTrue(lifecycle.failureEntered.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
            shutdownCaller.execute(() -> {
                shutdownStarted.countDown();
                endpoint.shutdown();
                shutdownReturned.countDown();
            });

            assertTrue(shutdownStarted.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
            assertFalse(shutdownReturned.await(100, TimeUnit.MILLISECONDS));
            lifecycle.releaseFailure.countDown();
            assertTrue(shutdownReturned.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
            assertTrue(lifecycle.stopped.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
            assertEquals(1, lifecycle.failedCalls.get());
            assertEquals(1, lifecycle.stoppedCalls.get());
            assertEquals("adb.endpoint.stopped", reporter.currentState());
        } finally {
            lifecycle.releaseFailure.countDown();
            endpoint.shutdown();
            shutdownCaller.shutdownNow();
        }
    }
}
