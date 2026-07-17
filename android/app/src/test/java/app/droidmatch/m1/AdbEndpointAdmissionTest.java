package app.droidmatch.m1;

import static app.droidmatch.m1.AdbEndpointTestSupport.*;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import java.io.IOException;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.ArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import org.junit.Test;

public final class AdbEndpointAdmissionTest {
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
                (socket, handshakeTimeout, idleTimeout) -> {
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
                (socket, handshakeTimeout, idleTimeout) -> {
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
                (socket, handshakeTimeout, idleTimeout) -> {
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
                (socket, handshakeTimeout, idleTimeout) -> handlerCalls.incrementAndGet(),
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
}
