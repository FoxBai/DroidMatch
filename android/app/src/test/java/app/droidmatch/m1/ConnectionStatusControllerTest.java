package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public final class ConnectionStatusControllerTest {
    @Test
    public void newerGenerationRejectsStaleEndpointCallbacks() {
        ConnectionStatusController controller = new ConnectionStatusController();

        long productGeneration = controller.begin(
                SessionAuthenticationMode.PAIRED_REQUIRED,
                39001
        );
        assertEquals(ConnectionStatusController.State.STARTING, controller.snapshot().state());
        controller.markListening(productGeneration, 39001);
        assertTrue(controller.snapshot().secureEndpointReady());

        long debugGeneration = controller.begin(SessionAuthenticationMode.NONCE_ONLY, 39002);
        controller.markFailed(productGeneration);
        controller.markStopped(productGeneration);
        ConnectionStatusController.Snapshot startingDebug = controller.snapshot();
        assertEquals(ConnectionStatusController.State.STARTING, startingDebug.state());
        assertEquals(SessionAuthenticationMode.NONCE_ONLY, startingDebug.authenticationMode());

        controller.markListening(debugGeneration, 39002);
        ConnectionStatusController.Snapshot listeningDebug = controller.snapshot();
        assertEquals(ConnectionStatusController.State.LISTENING, listeningDebug.state());
        assertFalse(listeningDebug.secureEndpointReady());
    }

    @Test
    public void failureRemainsVisibleUntilRetryOrExplicitStop() {
        ConnectionStatusController controller = new ConnectionStatusController();
        long generation = controller.begin(SessionAuthenticationMode.PAIRED_REQUIRED, 39001);

        controller.markFailed(generation);
        controller.markStopped(generation);
        assertEquals(ConnectionStatusController.State.FAILED, controller.snapshot().state());

        long retryGeneration = controller.begin(SessionAuthenticationMode.PAIRED_REQUIRED, 39001);
        controller.markListening(retryGeneration, 49152);
        assertEquals(ConnectionStatusController.State.LISTENING, controller.snapshot().state());
        assertEquals(49152, controller.snapshot().port());
        assertTrue(controller.snapshot().secureEndpointReady());

        controller.stop();
        controller.markFailed(retryGeneration);
        controller.markStopped(retryGeneration);
        assertEquals(ConnectionStatusController.State.STOPPED, controller.snapshot().state());
        assertEquals(0, controller.snapshot().port());
    }
}
