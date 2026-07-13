package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.io.IOException;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketAddress;
import java.net.SocketTimeoutException;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;

import org.junit.Test;

public final class AdbEndpointTest {
    private static final long TIMEOUT_SECONDS = 5;

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
    public void admitsFourClientsRejectsFifthAndReusesReleasedCapacity() throws Exception {
        TestLifecycleListener lifecycle = new TestLifecycleListener();
        Semaphore releases = new Semaphore(0);
        CountDownLatch firstFourEntered = new CountDownLatch(AdbEndpoint.MAX_ACTIVE_CLIENTS);
        CountDownLatch fifthHandlerEntered = new CountDownLatch(1);
        AtomicInteger handlerCalls = new AtomicInteger();
        AtomicInteger activeHandlers = new AtomicInteger();
        AtomicInteger maximumActiveHandlers = new AtomicInteger();
        ExecutorService acceptExecutor = Executors.newSingleThreadExecutor();
        ExecutorService clientExecutor = Executors.newFixedThreadPool(AdbEndpoint.MAX_ACTIVE_CLIENTS);
        DiagnosticsReporter reporter = reporter();
        AdbEndpoint endpoint = endpoint(
                (socket, timeout) -> {
                    int call = handlerCalls.incrementAndGet();
                    int active = activeHandlers.incrementAndGet();
                    maximumActiveHandlers.accumulateAndGet(active, Math::max);
                    if (call <= AdbEndpoint.MAX_ACTIVE_CLIENTS) {
                        firstFourEntered.countDown();
                    } else {
                        fifthHandlerEntered.countDown();
                    }
                    try {
                        releases.acquire();
                    } catch (InterruptedException exception) {
                        Thread.currentThread().interrupt();
                    } finally {
                        activeHandlers.decrementAndGet();
                    }
                },
                reporter,
                lifecycle,
                ServerSocket::new,
                acceptExecutor,
                clientExecutor,
                AdbEndpoint.MAX_ACTIVE_CLIENTS
        );
        ArrayList<Socket> peers = new ArrayList<>();

        try {
            endpoint.start(0);
            assertTrue(lifecycle.listening.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
            for (int index = 0; index < AdbEndpoint.MAX_ACTIVE_CLIENTS; index++) {
                peers.add(new Socket("127.0.0.1", lifecycle.actualPort.get()));
            }
            assertTrue(firstFourEntered.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));

            Socket rejected = new Socket("127.0.0.1", lifecycle.actualPort.get());
            peers.add(rejected);
            awaitCounter(reporter, "adb.endpoint.clients.rejected_capacity", 1L);
            assertPeerClosed(rejected);
            assertEquals(AdbEndpoint.MAX_ACTIVE_CLIENTS, handlerCalls.get());

            releases.release();
            Future<?> drained = clientExecutor.submit(() -> {});
            drained.get(TIMEOUT_SECONDS, TimeUnit.SECONDS);

            Socket replacement = new Socket("127.0.0.1", lifecycle.actualPort.get());
            peers.add(replacement);
            assertTrue(fifthHandlerEntered.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
            assertEquals(AdbEndpoint.MAX_ACTIVE_CLIENTS + 1, handlerCalls.get());
            assertTrue(maximumActiveHandlers.get() <= AdbEndpoint.MAX_ACTIVE_CLIENTS);
        } finally {
            releases.release(AdbEndpoint.MAX_ACTIVE_CLIENTS + 1);
            endpoint.shutdown();
            closeAll(peers);
        }
    }

    @Test
    public void handlerFailureClosesSocketAndReleasesCapacity() throws Exception {
        TestLifecycleListener lifecycle = new TestLifecycleListener();
        CountDownLatch firstHandlerAttempted = new CountDownLatch(1);
        CountDownLatch secondHandlerEntered = new CountDownLatch(1);
        AtomicInteger handlerCalls = new AtomicInteger();
        ExecutorService clientExecutor = Executors.newFixedThreadPool(1);
        AdbEndpoint endpoint = endpoint(
                (socket, timeout) -> {
                    int call = handlerCalls.incrementAndGet();
                    if (call == 1) {
                        firstHandlerAttempted.countDown();
                        throw new IllegalStateException("expected test failure");
                    }
                    secondHandlerEntered.countDown();
                },
                lifecycle,
                ServerSocket::new,
                Executors.newSingleThreadExecutor(),
                clientExecutor,
                1
        );
        ArrayList<Socket> peers = new ArrayList<>();

        try {
            endpoint.start(0);
            assertTrue(lifecycle.listening.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
            Socket first = new Socket("127.0.0.1", lifecycle.actualPort.get());
            peers.add(first);
            assertTrue(firstHandlerAttempted.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
            Future<?> drained = clientExecutor.submit(() -> {});
            drained.get(TIMEOUT_SECONDS, TimeUnit.SECONDS);
            assertPeerClosed(first);

            Socket second = new Socket("127.0.0.1", lifecycle.actualPort.get());
            peers.add(second);
            assertTrue(secondHandlerEntered.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
            assertEquals(2, handlerCalls.get());
        } finally {
            endpoint.shutdown();
            closeAll(peers);
        }
    }

    @Test
    public void shutdownClosesAdmittedSocketAndUnblocksActiveHandler() throws Exception {
        TestLifecycleListener lifecycle = new TestLifecycleListener();
        CountDownLatch handlerEntered = new CountDownLatch(1);
        CountDownLatch handlerExited = new CountDownLatch(1);
        AdbEndpoint endpoint = endpoint(
                (socket, timeout) -> {
                    handlerEntered.countDown();
                    try {
                        socket.getInputStream().read();
                    } catch (IOException expectedClose) {
                        // Teardown owns cancellation by closing the admitted socket.
                    } finally {
                        handlerExited.countDown();
                    }
                },
                lifecycle,
                ServerSocket::new,
                Executors.newSingleThreadExecutor(),
                Executors.newFixedThreadPool(1),
                1
        );
        Socket peer = null;

        try {
            endpoint.start(0);
            assertTrue(lifecycle.listening.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
            peer = new Socket("127.0.0.1", lifecycle.actualPort.get());
            assertTrue(handlerEntered.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));

            endpoint.shutdown();

            assertTrue(handlerExited.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
            assertPeerClosed(peer);
            assertEquals(0, lifecycle.failedCalls.get());
            assertEquals(1, lifecycle.stoppedCalls.get());
        } finally {
            endpoint.shutdown();
            if (peer != null) {
                peer.close();
            }
        }
    }

    @Test
    public void rejectedExecutorClosesRegisteredClientWithoutDispatch() throws Exception {
        TrackingSocket client = new TrackingSocket();
        ControlledServerSocket listener = new ControlledServerSocket(client);
        listener.releaseAccept.countDown();
        ExecutorService rejectedExecutor = Executors.newSingleThreadExecutor();
        rejectedExecutor.shutdownNow();
        AtomicInteger handlerCalls = new AtomicInteger();
        DiagnosticsReporter reporter = reporter();
        AdbEndpoint endpoint = endpoint(
                (socket, timeout) -> handlerCalls.incrementAndGet(),
                reporter,
                new TestLifecycleListener(),
                () -> listener,
                Executors.newSingleThreadExecutor(),
                rejectedExecutor,
                1
        );

        try {
            endpoint.start(39001);
            awaitCondition(client::wasClosed);
            assertEquals(0, handlerCalls.get());
            assertTrue(reporter.recentErrorEvents().stream()
                    .anyMatch(event -> event.contains("adb.client.dispatch_rejected")));
        } finally {
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

    private static AdbEndpoint endpoint(
            AdbEndpoint.ClientSessionHandler handler,
            TestLifecycleListener lifecycle,
            AdbEndpoint.ListenerFactory listenerFactory,
            ExecutorService acceptExecutor,
            ExecutorService clientExecutor,
            int maximumClients
    ) {
        return endpoint(
                handler,
                reporter(),
                lifecycle,
                listenerFactory,
                acceptExecutor,
                clientExecutor,
                maximumClients
        );
    }

    private static AdbEndpoint endpoint(
            AdbEndpoint.ClientSessionHandler handler,
            DiagnosticsReporter reporter,
            TestLifecycleListener lifecycle,
            AdbEndpoint.ListenerFactory listenerFactory,
            ExecutorService acceptExecutor,
            ExecutorService clientExecutor,
            int maximumClients
    ) {
        return new AdbEndpoint(
                handler,
                reporter,
                lifecycle,
                listenerFactory,
                NoOpLog.INSTANCE,
                acceptExecutor,
                clientExecutor,
                maximumClients
        );
    }

    private static DiagnosticsReporter reporter() {
        return new DiagnosticsReporter(() -> 1L, () -> "adb-endpoint-test");
    }

    private static void awaitCounter(
            DiagnosticsReporter reporter,
            String name,
            long expected
    ) throws Exception {
        awaitCondition(() -> expected == reporter.counters().getOrDefault(name, 0L));
    }

    private static void awaitCondition(BooleanSupplier condition) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(TIMEOUT_SECONDS);
        while (!condition.getAsBoolean()) {
            if (System.nanoTime() >= deadline) {
                throw new AssertionError("timed out waiting for endpoint condition");
            }
            Thread.yield();
        }
    }

    private static void assertPeerClosed(Socket socket) throws Exception {
        socket.setSoTimeout((int) TimeUnit.SECONDS.toMillis(TIMEOUT_SECONDS));
        try {
            assertEquals(-1, socket.getInputStream().read());
        } catch (SocketTimeoutException exception) {
            throw new AssertionError("peer socket was not closed", exception);
        } catch (IOException expectedReset) {
            // A reset and EOF both prove that the pre-handshake peer was closed.
        }
    }

    private static void closeAll(List<Socket> sockets) {
        for (Socket socket : sockets) {
            try {
                socket.close();
            } catch (IOException ignored) {
                // Test cleanup only.
            }
        }
    }

    private static void awaitUninterruptibly(CountDownLatch latch) {
        boolean interrupted = false;
        while (true) {
            try {
                latch.await();
                break;
            } catch (InterruptedException exception) {
                interrupted = true;
            }
        }
        if (interrupted) {
            Thread.currentThread().interrupt();
        }
    }

    private static class TestLifecycleListener implements AdbEndpoint.LifecycleListener {
        final CountDownLatch listening = new CountDownLatch(1);
        final CountDownLatch stopped = new CountDownLatch(1);
        final AtomicInteger actualPort = new AtomicInteger();
        final AtomicInteger listeningCalls = new AtomicInteger();
        final AtomicInteger failedCalls = new AtomicInteger();
        final AtomicInteger stoppedCalls = new AtomicInteger();

        @Override
        public void onListening(int port) {
            actualPort.set(port);
            listeningCalls.incrementAndGet();
            listening.countDown();
        }

        @Override
        public void onFailed() {
            failedCalls.incrementAndGet();
        }

        @Override
        public void onStopped() {
            stoppedCalls.incrementAndGet();
            stopped.countDown();
        }
    }

    private static final class BlockingFailureLifecycle extends TestLifecycleListener {
        private final CountDownLatch failureEntered = new CountDownLatch(1);
        private final CountDownLatch releaseFailure = new CountDownLatch(1);

        @Override
        public void onFailed() {
            super.onFailed();
            failureEntered.countDown();
            awaitUninterruptibly(releaseFailure);
        }
    }

    private enum NoOpLog implements AdbEndpoint.EndpointLog {
        INSTANCE;

        @Override
        public void info(String message) {}

        @Override
        public void error(String message, Throwable error) {}
    }

    private static class TrackingServerSocket extends ServerSocket {
        private final AtomicBoolean closed = new AtomicBoolean();

        TrackingServerSocket() throws IOException {
            super();
        }

        @Override
        public void close() {
            closed.set(true);
        }

        boolean wasClosed() {
            return closed.get();
        }
    }

    private static final class ControlledServerSocket extends TrackingServerSocket {
        private final TrackingSocket acceptedClient;
        private final CountDownLatch acceptEntered = new CountDownLatch(1);
        private final CountDownLatch releaseAccept = new CountDownLatch(1);
        private final CountDownLatch closed = new CountDownLatch(1);
        private final AtomicInteger acceptCalls = new AtomicInteger();

        ControlledServerSocket(TrackingSocket acceptedClient) throws IOException {
            this.acceptedClient = acceptedClient;
        }

        @Override
        public void bind(SocketAddress endpoint, int backlog) {}

        @Override
        public int getLocalPort() {
            return 39001;
        }

        @Override
        public Socket accept() throws IOException {
            if (acceptCalls.getAndIncrement() == 0) {
                acceptEntered.countDown();
                awaitUninterruptibly(releaseAccept);
                return acceptedClient;
            }
            awaitUninterruptibly(closed);
            throw new IOException("listener closed");
        }

        @Override
        public void close() {
            super.close();
            closed.countDown();
        }
    }

    private static final class FailingBindServerSocket extends TrackingServerSocket {
        FailingBindServerSocket() throws IOException {}

        @Override
        public void bind(SocketAddress endpoint, int backlog) throws IOException {
            throw new IOException("expected bind failure");
        }
    }

    private static final class TrackingSocket extends Socket {
        private final AtomicBoolean closed = new AtomicBoolean();

        @Override
        public void setSoTimeout(int timeout) {}

        @Override
        public synchronized void close() {
            closed.set(true);
        }

        boolean wasClosed() {
            return closed.get();
        }
    }
}
