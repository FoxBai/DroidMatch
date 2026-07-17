package app.droidmatch.m1;

import java.util.List;

/** Fail-closed confirmation over one authoritative persisted-SAF snapshot. */
final class SafGrantStatePolicy {
    private SafGrantStatePolicy() {
    }

    static boolean grantConfirmed(String stableId, List<DmFileProvider.SafRoot> roots) {
        if (stableId == null || stableId.isEmpty() || roots == null) {
            return false;
        }
        boolean found = false;
        for (DmFileProvider.SafRoot root : roots) {
            if (root == null || root.stableId == null || root.stableId.isEmpty()) {
                return false;
            }
            found |= stableId.equals(root.stableId);
        }
        return found;
    }

    static boolean removalConfirmed(String stableId, List<DmFileProvider.SafRoot> roots) {
        if (stableId == null || stableId.isEmpty() || roots == null) {
            return false;
        }
        for (DmFileProvider.SafRoot root : roots) {
            if (root == null || root.stableId == null || root.stableId.isEmpty()) {
                return false;
            }
            if (stableId.equals(root.stableId)) {
                return false;
            }
        }
        return true;
    }
}
