package app.droidmatch.m1;

/** Retains an endpoint until every admitted client worker has actually exited. */
final class EndpointDrain {
    interface Endpoint {
        void shutdown();
        void shutdownAndAwaitClients(long timeoutMillis);
        boolean clientsTerminated();
    }

    private Endpoint pending;
    private boolean retired;

    /** Permanently closes this service instance to later endpoint starts. */
    synchronized void retire() {
        retired = true;
    }

    synchronized void begin(Endpoint endpoint) {
        if (pending != null && pending != endpoint && !pending.clientsTerminated()) {
            throw new IllegalStateException("prior ADB client shutdown is still pending");
        }
        pending = endpoint;
        endpoint.shutdown();
        releaseIfTerminated();
    }

    synchronized void await(long timeoutMillis) {
        if (pending == null) {
            return;
        }
        pending.shutdownAndAwaitClients(timeoutMillis);
        releaseIfTerminated();
        if (pending != null) {
            throw new IllegalStateException("ADB client shutdown did not complete");
        }
    }

    synchronized boolean blocksStart() {
        releaseIfTerminated();
        return retired || pending != null;
    }

    synchronized boolean drainComplete() {
        releaseIfTerminated();
        return pending == null;
    }

    private void releaseIfTerminated() {
        if (pending != null && pending.clientsTerminated()) {
            pending = null;
        }
    }
}
