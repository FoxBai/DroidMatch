package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Test;

public final class EndpointDrainTest {
    @Test
    public void timeoutRetainsEndpointAndRetirementPermanentlyBlocksRestart() {
        EndpointProbe endpoint = new EndpointProbe();
        EndpointDrain drain = new EndpointDrain();
        drain.begin(endpoint);
        assertTrue(drain.blocksStart());
        try {
            drain.await(50);
            fail("expected drain timeout");
        } catch (IllegalStateException expected) {
            assertEquals("held", expected.getMessage());
        }
        assertTrue(drain.blocksStart());
        assertEquals(1, endpoint.shutdownCalls);

        endpoint.terminated = true;
        drain.await(50);
        assertFalse(drain.blocksStart());
        assertEquals(2, endpoint.awaitCalls);
        drain.retire();
        assertTrue(drain.blocksStart());
    }

    private static final class EndpointProbe implements EndpointDrain.Endpoint {
        int shutdownCalls;
        int awaitCalls;
        boolean terminated;

        @Override
        public void shutdown() {
            shutdownCalls += 1;
        }

        @Override
        public void shutdownAndAwaitClients(long timeoutMillis) {
            awaitCalls += 1;
            if (!terminated) {
                throw new IllegalStateException("held");
            }
        }

        @Override
        public boolean clientsTerminated() {
            return terminated && awaitCalls > 0;
        }
    }
}
