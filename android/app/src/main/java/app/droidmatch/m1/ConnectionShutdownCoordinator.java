package app.droidmatch.m1;

import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.Map;

/** Process-local, synchronous endpoint shutdown boundary for destructive trust cleanup. */
final class ConnectionShutdownCoordinator {
    interface ShutdownAction {
        void shutdown();
    }

    private final Map<Object, ShutdownAction> actions = new IdentityHashMap<>();

    synchronized void register(Object owner, ShutdownAction action) {
        if (owner == null || action == null) {
            throw new IllegalArgumentException("shutdown owner and action are required");
        }
        for (Map.Entry<Object, ShutdownAction> entry : new ArrayList<>(actions.entrySet())) {
            if (entry.getKey() != owner) {
                entry.getValue().shutdown();
            }
        }
        actions.clear();
        actions.put(owner, action);
    }

    synchronized void unregister(Object owner) {
        actions.remove(owner);
    }

    synchronized void shutdownAndWait() {
        for (ShutdownAction action : new ArrayList<>(actions.values())) {
            action.shutdown();
        }
    }

    synchronized boolean isRegistered(Object owner) {
        return actions.containsKey(owner);
    }

    synchronized boolean runIfRegistered(Object owner, Runnable action) {
        if (!actions.containsKey(owner)) {
            return false;
        }
        action.run();
        return true;
    }
}
