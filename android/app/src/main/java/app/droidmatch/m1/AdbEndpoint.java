package app.droidmatch.m1;

import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;

public final class AdbEndpoint {
    private static final String TAG = "DroidMatchAdbEndpoint";
    private static final int LISTEN_BACKLOG = 50;
    static final int HANDSHAKE_TIMEOUT_MILLIS = 5_000;
    static final int IDLE_TIMEOUT_MILLIS = 30_000;
    static final int MAX_ACTIVE_CLIENTS = 4;

    private final Object lifecycleLock = new Object();
    private final ClientSessionHandler clientSessionHandler;
    private final DiagnosticsReporter diagnosticsReporter;
    private final LifecycleListener lifecycleListener;
    private final ListenerFactory listenerFactory;
    private final EndpointLog endpointLog;
    private final ExecutorService acceptExecutor;
    private final ExecutorService clientExecutor;
    private final int maxActiveClients;
    private final Set<Socket> clients = new HashSet<>();

    private State state = State.NEW;
    private Thread terminatingThread;
    private ServerSocket serverSocket;
    private volatile int actualPort;

    public AdbEndpoint(RpcDispatcher dispatcher, DiagnosticsReporter diagnosticsReporter) {
        this(dispatcher, diagnosticsReporter, LifecycleListener.NO_OP);
    }

    public AdbEndpoint(
            RpcDispatcher dispatcher,
            DiagnosticsReporter diagnosticsReporter,
            LifecycleListener lifecycleListener
    ) {
        this(
                dispatcher::handle,
                diagnosticsReporter,
                lifecycleListener,
                ServerSocket::new,
                EndpointLog.ANDROID,
                Executors.newSingleThreadExecutor(),
                Executors.newFixedThreadPool(MAX_ACTIVE_CLIENTS),
                MAX_ACTIVE_CLIENTS
        );
    }

    AdbEndpoint(
            ClientSessionHandler clientSessionHandler,
            DiagnosticsReporter diagnosticsReporter,
            LifecycleListener lifecycleListener,
            ListenerFactory listenerFactory,
            EndpointLog endpointLog,
            ExecutorService acceptExecutor,
            ExecutorService clientExecutor,
            int maxActiveClients
    ) {
        if (maxActiveClients <= 0) {
            throw new IllegalArgumentException("maxActiveClients must be positive");
        }
        this.clientSessionHandler = clientSessionHandler;
        this.diagnosticsReporter = diagnosticsReporter;
        this.lifecycleListener = lifecycleListener;
        this.listenerFactory = listenerFactory;
        this.endpointLog = endpointLog;
        this.acceptExecutor = acceptExecutor;
        this.clientExecutor = clientExecutor;
        this.maxActiveClients = maxActiveClients;
    }

    /**
     * Starts this one-shot endpoint. A stopped endpoint never binds or accepts again.
     *
     * <p>中文：endpoint 为一次性对象；停止后的旧实例不得重新监听或准入连接。</p>
     */
    public void start(int requestedPort) {
        synchronized (lifecycleLock) {
            if (state != State.NEW) {
                return;
            }
            state = State.STARTING;
        }

        try {
            acceptExecutor.execute(() -> runEndpoint(requestedPort));
        } catch (RejectedExecutionException exception) {
            terminate(exception);
        }
    }

    public int actualPort() {
        return actualPort;
    }

    /**
     * Atomically closes admission, the listener, and every admitted client.
     * Worker interruption is only a fallback; socket close owns I/O cancellation.
     */
    public void shutdown() {
        terminate(null);
    }

    private void runEndpoint(int requestedPort) {
        ServerSocket candidate = null;
        try {
            if (!isStarting()) {
                return;
            }
            candidate = listenerFactory.create();
            if (!registerCandidate(candidate)) {
                closeUnowned(candidate);
                return;
            }
            candidate.bind(
                    new InetSocketAddress(InetAddress.getByName("127.0.0.1"), requestedPort),
                    LISTEN_BACKLOG
            );
            if (!publishListening(candidate)) {
                closeUnowned(candidate);
                return;
            }
            acceptClients(candidate);
        } catch (IOException | RuntimeException exception) {
            terminate(exception);
        } finally {
            closeUnowned(candidate);
            terminate(null);
        }
    }

    private boolean isStarting() {
        synchronized (lifecycleLock) {
            return state == State.STARTING;
        }
    }

    private boolean registerCandidate(ServerSocket candidate) {
        synchronized (lifecycleLock) {
            if (state != State.STARTING) {
                return false;
            }
            serverSocket = candidate;
            return true;
        }
    }

    private boolean publishListening(ServerSocket candidate) {
        synchronized (lifecycleLock) {
            if (state != State.STARTING || serverSocket != candidate) {
                return false;
            }
            state = State.LISTENING;
            actualPort = candidate.getLocalPort();

            // Keep publication inside the lifecycle boundary so shutdown cannot
            // return before a stale listener announces itself as ready.
            diagnosticsReporter.recordState("adb.endpoint.listening:" + actualPort);
            endpointLog.info("listening on 127.0.0.1:" + actualPort);
            lifecycleListener.onListening(actualPort);
            return state == State.LISTENING && serverSocket == candidate;
        }
    }

    private void acceptClients(ServerSocket listener) throws IOException {
        while (isCurrentListener(listener)) {
            Socket client = listener.accept();
            boolean submitted = false;
            try {
                client.setSoTimeout(HANDSHAKE_TIMEOUT_MILLIS);
                Admission admission = admitAndSubmit(client, listener);
                if (admission == Admission.STOPPED) {
                    return;
                }
                if (admission == Admission.ACCEPTED) {
                    submitted = true;
                }
            } finally {
                if (!submitted) {
                    closeUnowned(client);
                }
            }
        }
    }

    private boolean isCurrentListener(ServerSocket listener) {
        synchronized (lifecycleLock) {
            return state == State.LISTENING && serverSocket == listener;
        }
    }

    private Admission admitAndSubmit(Socket client, ServerSocket listener) {
        synchronized (lifecycleLock) {
            if (state != State.LISTENING || serverSocket != listener) {
                return Admission.STOPPED;
            }
            if (clients.size() >= maxActiveClients) {
                diagnosticsReporter.recordCounter("adb.endpoint.clients.rejected_capacity", 1);
                endpointLog.info("rejected client before handshake: endpoint capacity reached");
                return Admission.CAPACITY;
            }
            clients.add(client);
            try {
                clientExecutor.execute(() -> handleClient(client));
            } catch (RejectedExecutionException exception) {
                clients.remove(client);
                diagnosticsReporter.recordError("adb.client.dispatch_rejected", exception);
                endpointLog.error("client dispatch rejected", exception);
                return Admission.REJECTED;
            }
            diagnosticsReporter.recordState("adb.endpoint.accepted");
            endpointLog.info("accepted loopback client");
            return Admission.ACCEPTED;
        }
    }

    private void handleClient(Socket client) {
        try {
            if (!isAdmitted(client)) {
                return;
            }
            clientSessionHandler.handle(
                    client,
                    HANDSHAKE_TIMEOUT_MILLIS,
                    IDLE_TIMEOUT_MILLIS
            );
        } catch (RuntimeException exception) {
            diagnosticsReporter.recordError("adb.client.failed", exception);
            endpointLog.error("client session failed", exception);
        } finally {
            releaseClient(client);
            closeUnowned(client);
        }
    }

    private boolean isAdmitted(Socket client) {
        synchronized (lifecycleLock) {
            return state == State.LISTENING && clients.contains(client);
        }
    }

    private void releaseClient(Socket client) {
        synchronized (lifecycleLock) {
            clients.remove(client);
        }
    }

    private void terminate(Throwable failure) {
        boolean notifyFailed;
        boolean notifyStopped;
        boolean interrupted = false;
        ServerSocket ownedServer;
        ArrayList<Socket> ownedClients;
        synchronized (lifecycleLock) {
            while (state == State.TERMINATING && terminatingThread != Thread.currentThread()) {
                try {
                    lifecycleLock.wait();
                } catch (InterruptedException exception) {
                    interrupted = true;
                }
            }
            if (state == State.TERMINATED) {
                if (interrupted) {
                    Thread.currentThread().interrupt();
                }
                return;
            }
            if (state == State.TERMINATING) {
                return;
            }
            notifyFailed = failure != null && (state == State.STARTING || state == State.LISTENING);
            notifyStopped = state != State.NEW || failure != null;
            state = State.TERMINATING;
            terminatingThread = Thread.currentThread();
            actualPort = 0;
            ownedServer = serverSocket;
            serverSocket = null;
            ownedClients = new ArrayList<>(clients);
            clients.clear();
        }

        try {
            closeOwnedServer(ownedServer);
            for (Socket client : ownedClients) {
                closeOwnedClient(client);
            }
            acceptExecutor.shutdownNow();
            clientExecutor.shutdownNow();
            if (notifyFailed) {
                notifyFailed(failure);
            }
            if (notifyStopped) {
                notifyStopped();
            }
        } finally {
            synchronized (lifecycleLock) {
                state = State.TERMINATED;
                terminatingThread = null;
                lifecycleLock.notifyAll();
            }
            if (interrupted) {
                Thread.currentThread().interrupt();
            }
        }
    }

    private void notifyFailed(Throwable failure) {
        try {
            lifecycleListener.onFailed();
        } catch (RuntimeException callbackFailure) {
            diagnosticsReporter.recordError("adb.endpoint.failure_callback_failed", callbackFailure);
        }
        diagnosticsReporter.recordError("adb.endpoint.failed", failure);
        endpointLog.error("endpoint failed", failure);
    }

    private void notifyStopped() {
        try {
            lifecycleListener.onStopped();
        } catch (RuntimeException callbackFailure) {
            diagnosticsReporter.recordError("adb.endpoint.stopped_callback_failed", callbackFailure);
        }
        diagnosticsReporter.recordState("adb.endpoint.stopped");
        endpointLog.info("stopped");
    }

    private void closeOwnedServer(ServerSocket socket) {
        if (socket == null) {
            return;
        }
        try {
            socket.close();
        } catch (IOException exception) {
            diagnosticsReporter.recordError("adb.endpoint.close_failed", exception);
        }
    }

    private void closeOwnedClient(Socket client) {
        try {
            client.close();
        } catch (IOException exception) {
            diagnosticsReporter.recordError("adb.client.close_failed", exception);
        }
    }

    private static void closeUnowned(ServerSocket socket) {
        if (socket == null) {
            return;
        }
        try {
            socket.close();
        } catch (IOException ignored) {
            // Owned close failures are recorded by terminate(); late candidates
            // carry no session state and have no safe retry path.
        }
    }

    private static void closeUnowned(Socket socket) {
        if (socket == null) {
            return;
        }
        try {
            socket.close();
        } catch (IOException ignored) {
            // Best-effort close for sockets that never crossed admission.
        }
    }

    private enum State {
        NEW,
        STARTING,
        LISTENING,
        TERMINATING,
        TERMINATED
    }

    private enum Admission {
        ACCEPTED,
        CAPACITY,
        REJECTED,
        STOPPED
    }

    interface ClientSessionHandler {
        void handle(Socket socket, int handshakeTimeoutMillis, int idleTimeoutMillis);
    }

    interface ListenerFactory {
        ServerSocket create() throws IOException;
    }

    interface EndpointLog {
        EndpointLog ANDROID = new EndpointLog() {
            @Override
            public void info(String message) {
                android.util.Log.i(TAG, message);
            }

            @Override
            public void error(String message, Throwable error) {
                // Logcat is not the privacy-bounded diagnostics channel. Do not
                // pass Throwable to Log.e: provider exceptions can carry paths,
                // content URIs, document IDs, or user file names in their
                // message and stack trace. 中文：系统日志不得带出异常原文。
                android.util.Log.e(TAG, safeErrorLabel(message, error));
            }
        };

        static String safeErrorLabel(String message, Throwable error) {
            return AndroidLogLabel.error(message, error);
        }

        void info(String message);

        void error(String message, Throwable error);
    }

    /**
     * Synchronous endpoint state callbacks. Implementations must stay bounded
     * and should not re-enter endpoint lifecycle methods.
     */
    public interface LifecycleListener {
        LifecycleListener NO_OP = new LifecycleListener() {
            @Override
            public void onListening(int actualPort) {}

            @Override
            public void onFailed() {}

            @Override
            public void onStopped() {}
        };

        void onListening(int actualPort);

        void onFailed();

        void onStopped();
    }
}
