package app.droidmatch.m1;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public final class PairingAccessibilityPolicyTest {
    @Test
    public void pairingStateSeparatesVisualCountdownFromMeaningfulLiveRegionUpdates() {
        assertEquals(
                PairingAccessibilityPolicy.State.CLOSED,
                PairingAccessibilityPolicy.state(false, false, null)
        );
        assertEquals(
                PairingAccessibilityPolicy.State.WAITING,
                PairingAccessibilityPolicy.state(true, false, null)
        );
        assertEquals(
                PairingAccessibilityPolicy.State.APPROVAL_REQUIRED,
                PairingAccessibilityPolicy.state(
                        true,
                        true,
                        PairingApprovalController.Decision.PENDING
                )
        );
        assertEquals(
                PairingAccessibilityPolicy.State.APPROVED,
                PairingAccessibilityPolicy.state(
                        true,
                        true,
                        PairingApprovalController.Decision.APPROVED
                )
        );
        assertEquals(
                PairingAccessibilityPolicy.State.REJECTED,
                PairingAccessibilityPolicy.state(
                        true,
                        true,
                        PairingApprovalController.Decision.REJECTED
                )
        );
        assertEquals(
                PairingAccessibilityPolicy.State.CLOSED,
                PairingAccessibilityPolicy.state(
                        false,
                        true,
                        PairingApprovalController.Decision.REJECTED
                )
        );
        assertEquals(
                PairingAccessibilityPolicy.State.CLOSED,
                PairingAccessibilityPolicy.state(
                        true,
                        true,
                        PairingApprovalController.Decision.EXPIRED
                )
        );

        expectInvalidState(true, false, PairingApprovalController.Decision.PENDING);
        expectInvalidState(true, true, null);
    }

    @Test
    public void pairingCodeIsSpokenAsSixSeparateAsciiDigits() {
        assertEquals("0 1 2 3 4 5", PairingAccessibilityPolicy.spokenDigits("012345"));
        expectInvalidCode(null);
        expectInvalidCode("12345");
        expectInvalidCode("12A456");
        expectInvalidCode("１２３４５６");
    }

    private static void expectInvalidState(
            boolean windowOpen,
            boolean hasAttempt,
            PairingApprovalController.Decision decision
    ) {
        try {
            PairingAccessibilityPolicy.state(windowOpen, hasAttempt, decision);
            throw new AssertionError("expected inconsistent pairing state rejection");
        } catch (IllegalArgumentException expected) {
            // Expected: the UI must not announce a state the controller cannot publish.
        }
    }

    private static void expectInvalidCode(String code) {
        try {
            PairingAccessibilityPolicy.spokenDigits(code);
            throw new AssertionError("expected malformed pairing code rejection");
        } catch (IllegalArgumentException expected) {
            // Expected: accessibility text must preserve the exact six-digit SAS boundary.
        }
    }
}
