package app.droidmatch.m1;

import java.io.IOException;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

public final class AdbEndpoint {
    private static final String TAG = "DroidMatchAdbEndpoint";
    private static final int HANDSHAKE_TIMEOUT_MILLIS = 5_000;
    private static final int IDLE_TIMEOUT_MILLIS = 30_000;

    private final RpcDispatcher dispatcher;
    private final DiagnosticsReporter diagnosticsReporter;
    private final LifecycleListener lifecycleListener;
    private final ExecutorService acceptExecutor = Executors.newSingleThreadExecutor();
    private final ExecutorService clientExecutor = Executors.newCachedThreadPool();
    private final Set<Socket> clients = Collections.synchronizedSet(new HashSet<>());
    private final AtomicBoolean running = new AtomicBoolean(false);
    private volatile ServerSocket serverSocket;
    private volatile int actualPort;

    public AdbEndpoint(RpcDispatcher dispatcher, DiagnosticsReporter diagnosticsReporter) {
        this(dispatcher, diagnosticsReporter, LifecycleListener.NO_OP);
    }

    public AdbEndpoint(
            RpcDispatcher dispatcher,
            DiagnosticsReporter diagnosticsReporter,
            LifecycleListener lifecycleListener
    ) {
        this.dispatcher = dispatcher;
        this.diagnosticsReporter = diagnosticsReporter;
        this.lifecycleListener = lifecycleListener;
    }

    public void start(int requestedPort) {
        if (!running.compareAndSet(false, true)) {
            return;
        }

        acceptExecutor.execute(() -> {
            try (ServerSocket socket = new ServerSocket(requestedPort, 50, InetAddress.getByName("127.0.0.1"))) {
                serverSocket = socket;
                actualPort = socket.getLocalPort();
                lifecycleListener.onListening(actualPort);
                diagnosticsReporter.recordState("adb.endpoint.listening:" + actualPort);
                android.util.Log.i(TAG, "listening on 127.0.0.1:" + actualPort);
                while (running.get()) {
                    Socket client = socket.accept();
                    client.setSoTimeout(HANDSHAKE_TIMEOUT_MILLIS);
                    clients.add(client);
                    diagnosticsReporter.recordState("adb.endpoint.accepted");
                    android.util.Log.i(TAG, "accepted client from " + client.getRemoteSocketAddress());
                    clientExecutor.execute(() -> {
                        try {
                            dispatcher.handle(client, IDLE_TIMEOUT_MILLIS);
                        } finally {
                            clients.remove(client);
                        }
                    });
                }
            } catch (IOException exception) {
                if (running.get()) {
                    lifecycleListener.onFailed();
                    diagnosticsReporter.recordError("adb.endpoint.failed", exception);
                    android.util.Log.e(TAG, "endpoint failed", exception);
                }
            } finally {
                running.set(false);
                actualPort = 0;
                lifecycleListener.onStopped();
                diagnosticsReporter.recordState("adb.endpoint.stopped");
                android.util.Log.i(TAG, "stopped");
            }
        });
    }

    public int actualPort() {
        return actualPort;
    }

    public void stop() {
        running.set(false);
        ServerSocket socket = serverSocket;
        serverSocket = null;
        if (socket != null) {
            try {
                socket.close();
            } catch (IOException exception) {
                diagnosticsReporter.recordError("adb.endpoint.close_failed", exception);
            }
        }
        Set<Socket> snapshot;
        synchronized (clients) {
            snapshot = new HashSet<>(clients);
            clients.clear();
        }
        for (Socket client : snapshot) {
            try {
                client.close();
            } catch (IOException exception) {
                diagnosticsReporter.recordError("adb.client.close_failed", exception);
            }
        }
    }

    public void shutdown() {
        stop();
        acceptExecutor.shutdownNow();
        clientExecutor.shutdownNow();
    }

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
