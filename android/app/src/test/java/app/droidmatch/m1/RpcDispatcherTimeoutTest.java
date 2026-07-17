package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import app.droidmatch.proto.v1.Capability;
import app.droidmatch.proto.v1.ServerHello;

import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import org.junit.Test;

public final class RpcDispatcherTimeoutTest {
    @Test
    public void sessionErrorLogLabelOmitsThrowableDetails() {
        String label = AndroidLogLabel.error(
                "session crashed",
                new IllegalStateException("content://com.example.documents/private.jpg")
        );

        assertEquals("session crashed [IllegalStateException]", label);
        assertFalse(label.contains("content://"));
        assertFalse(label.contains("private.jpg"));
    }

    @Test
    public void firstFrameUsesHandshakeTimeout() {
        assertEquals(
                5_000,
                RpcDispatcher.readTimeoutMillis(
                        RpcSessionState.Phase.AWAITING_HELLO,
                        5_000,
                        30_000
                )
        );
        assertEquals(
                "rpc.session.handshake_timeout",
                RpcDispatcher.timeoutErrorCode(RpcSessionState.Phase.AWAITING_HELLO)
        );
    }

    @Test
    public void pairingApprovalWaitOutlivesOrdinaryIdleTimeout() {
        assertEquals(
                125_000,
                RpcDispatcher.readTimeoutMillis(
                        RpcSessionState.Phase.PAIRING_AWAITING_CONFIRM,
                        5_000,
                        30_000
                )
        );
        assertEquals(
                30_000,
                RpcDispatcher.readTimeoutMillis(
                        RpcSessionState.Phase.READY,
                        5_000,
                        30_000
                )
        );
    }

    @Test
    public void ordinaryPostHelloPhasesUseIdleTimeout() {
        assertEquals(
                30_000,
                RpcDispatcher.readTimeoutMillis(
                        RpcSessionState.Phase.AWAITING_AUTH,
                        5_000,
                        30_000
                )
        );
        assertEquals(
                "rpc.session.idle_timeout",
                RpcDispatcher.timeoutErrorCode(RpcSessionState.Phase.READY)
        );
        assertEquals(
                30_000,
                RpcDispatcher.readTimeoutMillis(
                        RpcSessionState.Phase.PAIRING_AWAITING_FINALIZE,
                        5_000,
                        30_000
                )
        );
        assertEquals(
                30_000,
                RpcDispatcher.readTimeoutMillis(
                        RpcSessionState.Phase.READY,
                        5_000,
                        30_000
                )
        );
    }

    @Test
    public void callerMayProvideLongerPairingTimeout() {
        assertEquals(
                180_000,
                RpcDispatcher.readTimeoutMillis(
                        RpcSessionState.Phase.PAIRING_AWAITING_CONFIRM,
                        5_000,
                        180_000
                )
        );
    }

    @Test
    public void silentFirstFrameTimesOutBeforeBlockingProviderRoots() throws Exception {
        BlockingRootsCatalog roots = new BlockingRootsCatalog(true);
        DiagnosticsReporter reporter = new DiagnosticsReporter(() -> 1L, () -> "test-thread");
        RpcDispatcher dispatcher = dispatcher(reporter, roots);
        ExecutorService executor = Executors.newSingleThreadExecutor();

        try (ServerSocket listener = new ServerSocket(0, 1, InetAddress.getLoopbackAddress());
             Socket client = new Socket(InetAddress.getLoopbackAddress(), listener.getLocalPort());
             Socket accepted = listener.accept()) {
            Future<?> handling = executor.submit(() -> dispatcher.handle(accepted, 100, 30_000));
            try {
                handling.get(5, TimeUnit.SECONDS);
                assertEquals(0, roots.calls.get());
                assertTrue(reporter.recentErrorEvents().stream().anyMatch(
                        event -> event.contains(
                                "rpc.session.handshake_timeout:SocketTimeoutException"
                        )
                ));
            } finally {
                roots.release.countDown();
                client.close();
            }
        } finally {
            roots.release.countDown();
            executor.shutdownNow();
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS));
        }
    }

    @Test
    public void serverHelloCapabilitiesDoNotEnumerateProviderRoots() throws Exception {
        BlockingRootsCatalog roots = new BlockingRootsCatalog(false);
        RpcDispatcher dispatcher = dispatcher(
                new DiagnosticsReporter(() -> 1L, () -> "test-thread"),
                roots
        );

        app.droidmatch.proto.v1.RpcEnvelope[] responses = dispatcher.dispatchForTest(
                RpcDispatcherTestFixtures.clientHelloEnvelope(
                        1,
                        new byte[SessionAuthenticator.NONCE_LENGTH],
                        new byte[0],
                        Capability.CAPABILITY_DIAGNOSTICS
                ).toByteArray(),
                dispatcher.newSessionStateForTest(),
                1
        );
        ServerHello hello = ServerHello.parseFrom(responses[0].getPayload());

        assertEquals(
                Collections.singletonList(Capability.CAPABILITY_DIAGNOSTICS),
                hello.getGrantedCapabilitiesList()
        );
        assertEquals(0, roots.calls.get());
    }

    private static RpcDispatcher dispatcher(
            DiagnosticsReporter reporter,
            ProviderSafCatalog roots
    ) {
        return new RpcDispatcher(
                reporter,
                null,
                new DmFileProvider(
                        ProviderMediaCatalog.empty(),
                        roots,
                        ProviderAppSandboxCatalog.empty()
                ),
                null,
                SessionAuthenticationMode.NONCE_ONLY,
                pairingId -> null,
                null,
                null,
                null,
                new AuthenticationRateLimiter(),
                NoOpSessionLog.INSTANCE
        );
    }

    private enum NoOpSessionLog implements RpcDispatcher.SessionLog {
        INSTANCE;

        @Override
        public void info(String message) {}

        @Override
        public void warning(String message, Throwable error) {}

        @Override
        public void error(String message, Throwable error) {}
    }

    private static final class BlockingRootsCatalog implements ProviderSafCatalog {
        private final boolean block;
        private final AtomicInteger calls = new AtomicInteger();
        private final CountDownLatch release = new CountDownLatch(1);

        private BlockingRootsCatalog(boolean block) {
            this.block = block;
        }

        @Override
        public List<DmFileProvider.SafRoot> roots() {
            calls.incrementAndGet();
            if (block) {
                AdbEndpointTestSupport.awaitUninterruptibly(release);
            }
            return Collections.emptyList();
        }

        @Override
        public DmFileProvider.SafPage listChildren(
                DmFileProvider.SafRoot root,
                String documentId,
                DmFileProvider.ProviderQuery query
        ) {
            return new DmFileProvider.SafPage(Collections.emptyList(), false);
        }

        @Override
        public DmFileProvider.DownloadChunk readDocument(
                DmFileProvider.SafRoot root,
                String documentId,
                long offsetBytes,
                int chunkSizeBytes
        ) throws DmFileProvider.ProviderCatalogException {
            throw new DmFileProvider.ProviderCatalogException(
                    app.droidmatch.proto.v1.ErrorCode.ERROR_CODE_NOT_FOUND,
                    "test SAF document is unavailable"
            );
        }
    }
}
