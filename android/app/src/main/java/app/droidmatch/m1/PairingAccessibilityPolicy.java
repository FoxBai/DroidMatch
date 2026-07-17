package app.droidmatch.m1;

/** Pure accessibility projection for the polled product pairing surface. */
final class PairingAccessibilityPolicy {
    enum State {
        CLOSED,
        WAITING,
        APPROVAL_REQUIRED,
        APPROVED,
        REJECTED
    }

    private PairingAccessibilityPolicy() {
    }

    static State state(
            boolean windowOpen,
            boolean hasAttempt,
            PairingApprovalController.Decision decision
    ) {
        if (hasAttempt != (decision != null)) {
            throw new IllegalArgumentException("pairing accessibility state is inconsistent");
        }
        if (!windowOpen || decision == PairingApprovalController.Decision.EXPIRED) {
            return State.CLOSED;
        }
        if (!hasAttempt) {
            return State.WAITING;
        }
        switch (decision) {
            case PENDING:
                return State.APPROVAL_REQUIRED;
            case APPROVED:
                return State.APPROVED;
            case REJECTED:
                return State.REJECTED;
            case EXPIRED:
            default:
                return State.CLOSED;
        }
    }

    static String spokenDigits(String shortAuthenticationString) {
        if (shortAuthenticationString == null || shortAuthenticationString.length() != 6) {
            throw new IllegalArgumentException("pairing SAS must contain six digits");
        }
        StringBuilder result = new StringBuilder(11);
        for (int index = 0; index < shortAuthenticationString.length(); index += 1) {
            char digit = shortAuthenticationString.charAt(index);
            if (digit < '0' || digit > '9') {
                throw new IllegalArgumentException("pairing SAS must contain six digits");
            }
            if (index > 0) {
                result.append(' ');
            }
            result.append(digit);
        }
        return result.toString();
    }
}
