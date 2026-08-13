package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.util.ArrayList;
import java.util.Arrays;

import org.junit.Test;

public final class ConnectionShutdownCoordinatorTest {
    @Test
    public void replacementOwnerGuardsSharedStateWhileStaleOwnerStillDrainsLocally() {
        ConnectionShutdownCoordinator coordinator = new ConnectionShutdownCoordinator();
        ArrayList<String> events = new ArrayList<>();
        Object first = new Object();
        Object current = new Object();
        Runnable firstLocalDrain = () -> events.add("first-local-drain");
        coordinator.register(first, firstLocalDrain::run);
        coordinator.register(current, () -> events.add("shutdown-complete"));
        coordinator.unregister(first);

        ConnectionStatusController status = new ConnectionStatusController();
        long generation = status.begin(SessionAuthenticationMode.PAIRED_REQUIRED, 39001);
        status.markListening(generation, 39001);
        PairingApprovalController approvals = new PairingApprovalController(() -> 1_000L);
        assertTrue(approvals.openWindow(60_000));

        // A stale timeout and later destroy still execute their idempotent local
        // shutdown/drain, but coordinator ownership rejects both shared mutations.
        firstLocalDrain.run();
        assertFalse(coordinator.runIfRegistered(first, status::stop));
        firstLocalDrain.run();
        assertFalse(coordinator.runIfRegistered(first, () -> {
            status.stop();
            approvals.closeWindow();
        }));
        assertEquals(ConnectionStatusController.State.LISTENING, status.snapshot().state());
        assertTrue(approvals.snapshot().windowOpen());

        coordinator.shutdownAndWait();
        assertTrue(coordinator.runIfRegistered(current, () -> {
            status.stop();
            approvals.closeWindow();
        }));
        assertEquals(ConnectionStatusController.State.STOPPED, status.snapshot().state());
        assertFalse(approvals.snapshot().windowOpen());
        assertEquals(Arrays.asList(
                "first-local-drain",
                "first-local-drain",
                "first-local-drain",
                "shutdown-complete"
        ), events);
        coordinator.unregister(current);
        coordinator.shutdownAndWait();
        assertEquals(4, events.size());
    }

    @Test
    public void shutdownFailurePropagatesBeforeCallerCanDelete() {
        ConnectionShutdownCoordinator coordinator = new ConnectionShutdownCoordinator();
        int[] deletes = {0};
        coordinator.register(new Object(), () -> { throw new IllegalStateException("failed"); });
        try {
            coordinator.shutdownAndWait();
            deletes[0] += 1;
            fail("expected shutdown failure");
        } catch (IllegalStateException expected) {
            assertEquals("failed", expected.getMessage());
        }
        assertEquals(0, deletes[0]);
    }

    @Test
    public void replacementCannotRegisterUntilOldServiceDrains() {
        ConnectionShutdownCoordinator coordinator = new ConnectionShutdownCoordinator();
        ArrayList<String> events = new ArrayList<>();
        Object oldOwner = new Object();
        Object newOwner = new Object();
        boolean[] oldDrained = {false};
        coordinator.register(oldOwner, () -> {
            events.add("old");
            if (!oldDrained[0]) {
                throw new IllegalStateException("old drain pending");
            }
        });

        try {
            coordinator.register(newOwner, () -> events.add("new"));
            fail("expected old service drain failure");
        } catch (IllegalStateException expected) {
            assertEquals("old drain pending", expected.getMessage());
        }
        try {
            coordinator.shutdownAndWait();
        } catch (IllegalStateException expected) {
            assertEquals("old drain pending", expected.getMessage());
        }
        oldDrained[0] = true;
        coordinator.register(newOwner, () -> events.add("new"));
        coordinator.shutdownAndWait();
        assertEquals(Arrays.asList("old", "old", "old", "new"), events);
    }
}
