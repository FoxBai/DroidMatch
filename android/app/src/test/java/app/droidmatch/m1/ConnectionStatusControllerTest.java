package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
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
        assertEquals(0, controller.snapshot().port());

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

    @Test
    public void foregroundLifecyclePublishesStartingThenReadyAndStopsAfterExit() {
        ConnectionStatusController controller = new ConnectionStatusController();
        RecordingActions actions = new RecordingActions();
        ForegroundEndpointLifecycle lifecycle = new ForegroundEndpointLifecycle(
                controller,
                actions
        );

        long generation = lifecycle.begin(SessionAuthenticationMode.PAIRED_REQUIRED, 39001);
        lifecycle.onListening(generation, 49152);

        assertEquals(
                Arrays.asList(
                        ForegroundEndpointLifecycle.NotificationState.STARTING,
                        ForegroundEndpointLifecycle.NotificationState.READY
                ),
                actions.notifications
        );
        assertEquals(ConnectionStatusController.State.LISTENING, controller.snapshot().state());

        lifecycle.onStopped(generation);
        assertEquals(ConnectionStatusController.State.STOPPED, controller.snapshot().state());
        assertEquals(1, actions.stopCount);
    }

    @Test
    public void foregroundLifecycleStopsOnceAndKeepsCurrentFailureVisible() {
        ConnectionStatusController controller = new ConnectionStatusController();
        RecordingActions actions = new RecordingActions();
        ForegroundEndpointLifecycle lifecycle = new ForegroundEndpointLifecycle(
                controller,
                actions
        );
        long generation = lifecycle.begin(SessionAuthenticationMode.PAIRED_REQUIRED, 39001);

        lifecycle.onFailed(generation);
        lifecycle.onFailed(generation);
        lifecycle.onStopped(generation);

        assertEquals(ConnectionStatusController.State.FAILED, controller.snapshot().state());
        assertEquals(1, actions.stopCount);
        assertEquals(
                Arrays.asList(ForegroundEndpointLifecycle.NotificationState.STARTING),
                actions.notifications
        );
    }

    @Test
    public void foregroundLifecycleRejectsLateFailureFromReplacedEndpoint() {
        ConnectionStatusController controller = new ConnectionStatusController();
        RecordingActions actions = new RecordingActions();
        ForegroundEndpointLifecycle lifecycle = new ForegroundEndpointLifecycle(
                controller,
                actions
        );
        long oldGeneration = lifecycle.begin(SessionAuthenticationMode.PAIRED_REQUIRED, 39001);
        long newGeneration = lifecycle.begin(SessionAuthenticationMode.PAIRED_REQUIRED, 39002);

        lifecycle.onFailed(oldGeneration);
        lifecycle.onStopped(oldGeneration);

        assertEquals(ConnectionStatusController.State.STARTING, controller.snapshot().state());
        assertEquals(39002, controller.snapshot().port());
        assertEquals(0, actions.stopCount);
        assertEquals(
                Arrays.asList(
                        ForegroundEndpointLifecycle.NotificationState.STARTING,
                        ForegroundEndpointLifecycle.NotificationState.STARTING
                ),
                actions.notifications
        );

        lifecycle.onListening(newGeneration, 49002);
        assertEquals(ConnectionStatusController.State.LISTENING, controller.snapshot().state());
        assertEquals(
                ForegroundEndpointLifecycle.NotificationState.READY,
                actions.notifications.get(actions.notifications.size() - 1)
        );
    }

    private static final class RecordingActions implements ForegroundEndpointLifecycle.Actions {
        private final List<ForegroundEndpointLifecycle.NotificationState> notifications =
                new ArrayList<>();
        private int stopCount;

        @Override
        public void showNotification(ForegroundEndpointLifecycle.NotificationState state) {
            notifications.add(state);
        }

        @Override
        public void stopAfterEndpointExit() {
            stopCount += 1;
        }
    }
}
