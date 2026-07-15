package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;

import java.io.IOException;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketAddress;
import java.net.SocketTimeoutException;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;

/** Shared deterministic socket/latch seam for the endpoint behavior suites. */
final class AdbEndpointTestSupport {
    static final long TIMEOUT_SECONDS = 5;

    private AdbEndpointTestSupport() {}

    static AdbEndpoint endpoint(
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

    static AdbEndpoint endpoint(
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

    static DiagnosticsReporter reporter() {
        return new DiagnosticsReporter(() -> 1L, () -> "adb-endpoint-test");
    }

    static void awaitCounter(
            DiagnosticsReporter reporter,
            String name,
            long expected
    ) throws Exception {
        awaitCondition(() -> expected == reporter.counters().getOrDefault(name, 0L));
    }

    static void awaitCondition(BooleanSupplier condition) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(TIMEOUT_SECONDS);
        while (!condition.getAsBoolean()) {
            if (System.nanoTime() >= deadline) {
                throw new AssertionError("timed out waiting for endpoint condition");
            }
            Thread.yield();
        }
    }

    static void assertPeerClosed(Socket socket) throws Exception {
        socket.setSoTimeout((int) TimeUnit.SECONDS.toMillis(TIMEOUT_SECONDS));
        try {
            assertEquals(-1, socket.getInputStream().read());
        } catch (SocketTimeoutException exception) {
            throw new AssertionError("peer socket was not closed", exception);
        } catch (IOException expectedReset) {
            // A reset and EOF both prove that the pre-handshake peer was closed.
        }
    }

    static void closeAll(List<Socket> sockets) {
        for (Socket socket : sockets) {
            try {
                socket.close();
            } catch (IOException ignored) {
                // Test cleanup only.
            }
        }
    }

    static void awaitUninterruptibly(CountDownLatch latch) {
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

    static class TestLifecycleListener implements AdbEndpoint.LifecycleListener {
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

    static final class BlockingFailureLifecycle extends TestLifecycleListener {
        final CountDownLatch failureEntered = new CountDownLatch(1);
        final CountDownLatch releaseFailure = new CountDownLatch(1);

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

    static class TrackingServerSocket extends ServerSocket {
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

    static final class ControlledServerSocket extends TrackingServerSocket {
        private final TrackingSocket acceptedClient;
        final CountDownLatch acceptEntered = new CountDownLatch(1);
        final CountDownLatch releaseAccept = new CountDownLatch(1);
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

    static final class FailingBindServerSocket extends TrackingServerSocket {
        FailingBindServerSocket() throws IOException {}

        @Override
        public void bind(SocketAddress endpoint, int backlog) throws IOException {
            throw new IOException("expected bind failure");
        }
    }

    static final class TrackingSocket extends Socket {
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
