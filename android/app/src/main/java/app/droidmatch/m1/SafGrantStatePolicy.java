package app.droidmatch.m1;

import android.content.ContentResolver;
import android.content.Intent;
import android.content.UriPermission;
import android.net.Uri;
import android.provider.DocumentsContract;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Transaction boundary for one exact persisted SAF tree grant. */
final class SafGrantStatePolicy {
    static final int MODE_READ = 1;
    static final int MODE_WRITE = 1 << 1;
    private static final int MODE_MASK = MODE_READ | MODE_WRITE;

    private SafGrantStatePolicy() {
    }

    interface GrantAccess {
        boolean targetIsTreeUri();

        List<PersistedGrant> persistedGrants();

        void take(int modes);

        void release(int modes);
    }

    interface ProductRoots {
        List<DmFileProvider.SafRoot> refresh();
    }

    static final class PersistedGrant {
        final String exactUri;
        final int modes;

        PersistedGrant(String exactUri, int modes) {
            this.exactUri = exactUri;
            this.modes = modes;
        }
    }

    static GrantAccess forResolver(ContentResolver contentResolver, Uri targetUri) {
        return new AndroidGrantAccess(contentResolver, targetUri);
    }

    static boolean add(
            String exactUri,
            int requestedModes,
            String stableId,
            GrantAccess access,
            ProductRoots productRoots
    ) {
        if (!validTarget(exactUri, requestedModes, stableId, access, productRoots)
                || (requestedModes & MODE_READ) == 0) {
            return false;
        }
        final Snapshot before = snapshot(access, exactUri);
        if (before == null) {
            return false;
        }
        int possibleAddedModes = requestedModes & ~before.targetModes;
        try {
            access.take(requestedModes);
        } catch (RuntimeException ignored) {
            // A mutation exception is reconciled against the raw resolver snapshot below.
        }
        final Snapshot after = snapshot(access, exactUri);
        if (after == null) {
            rollback(access, exactUri, before.targetModes, possibleAddedModes);
            return false;
        }
        int addedModes = after.targetModes & ~before.targetModes;
        boolean exactModesPersisted = (after.targetModes & requestedModes) == requestedModes
                && (addedModes & ~requestedModes) == 0;
        if (exactModesPersisted && productRootConfirmed(stableId, productRoots)) {
            return true;
        }
        rollback(access, exactUri, before.targetModes, addedModes);
        return false;
    }

    static boolean remove(String exactUri, GrantAccess access) {
        if (exactUri == null || exactUri.isEmpty() || access == null) {
            return false;
        }
        try {
            if (!access.targetIsTreeUri()) {
                return false;
            }
        } catch (RuntimeException exception) {
            return false;
        }
        Snapshot before = snapshot(access, exactUri);
        if (before == null) {
            return false;
        }
        if (before.targetModes != 0) {
            try {
                access.release(before.targetModes);
            } catch (RuntimeException ignored) {
                // Absence in the following raw snapshot remains authoritative.
            }
        }
        Snapshot after = snapshot(access, exactUri);
        return after != null && after.targetModes == 0;
    }

    private static boolean validTarget(
            String exactUri,
            int requestedModes,
            String stableId,
            GrantAccess access,
            ProductRoots productRoots
    ) {
        if (exactUri == null || exactUri.isEmpty()
                || stableId == null || stableId.isEmpty()
                || requestedModes == 0 || (requestedModes & ~MODE_MASK) != 0
                || access == null || productRoots == null) {
            return false;
        }
        try {
            return access.targetIsTreeUri();
        } catch (RuntimeException exception) {
            return false;
        }
    }

    private static Snapshot snapshot(GrantAccess access, String exactUri) {
        final List<PersistedGrant> grants;
        try {
            grants = access.persistedGrants();
        } catch (RuntimeException exception) {
            return null;
        }
        if (grants == null) {
            return null;
        }
        Set<String> seenUris = new HashSet<>();
        int targetModes = 0;
        for (PersistedGrant grant : grants) {
            if (grant == null || grant.exactUri == null || grant.exactUri.isEmpty()
                    || grant.modes == 0 || (grant.modes & ~MODE_MASK) != 0
                    || !seenUris.add(grant.exactUri)) {
                return null;
            }
            if (exactUri.equals(grant.exactUri)) {
                targetModes = grant.modes;
            }
        }
        return new Snapshot(targetModes);
    }

    private static boolean productRootConfirmed(String stableId, ProductRoots productRoots) {
        final List<DmFileProvider.SafRoot> roots;
        try {
            roots = productRoots.refresh();
        } catch (RuntimeException exception) {
            return false;
        }
        if (roots == null) {
            return false;
        }
        Set<String> seenIds = new HashSet<>();
        boolean found = false;
        for (DmFileProvider.SafRoot root : roots) {
            if (root == null || root.stableId == null || root.stableId.isEmpty()
                    || !seenIds.add(root.stableId)) {
                return false;
            }
            found |= stableId.equals(root.stableId);
        }
        return found;
    }

    private static boolean rollback(
            GrantAccess access,
            String exactUri,
            int beforeModes,
            int addedModes
    ) {
        if (addedModes != 0) {
            try {
                access.release(addedModes);
            } catch (RuntimeException ignored) {
                // The final exact-mode snapshot decides whether rollback was complete.
            }
        }
        Snapshot rolledBack = snapshot(access, exactUri);
        return rolledBack != null && rolledBack.targetModes == beforeModes;
    }

    private static final class Snapshot {
        final int targetModes;

        Snapshot(int targetModes) {
            this.targetModes = targetModes;
        }
    }

    private static final class AndroidGrantAccess implements GrantAccess {
        private final ContentResolver contentResolver;
        private final Uri targetUri;

        AndroidGrantAccess(ContentResolver contentResolver, Uri targetUri) {
            this.contentResolver = contentResolver;
            this.targetUri = targetUri;
        }

        @Override
        public boolean targetIsTreeUri() {
            if (targetUri == null || !"content".equals(targetUri.getScheme())
                    || targetUri.getAuthority() == null || targetUri.getAuthority().isEmpty()
                    || !DocumentsContract.isTreeUri(targetUri)) {
                return false;
            }
            String documentId = DocumentsContract.getTreeDocumentId(targetUri);
            return documentId != null && !documentId.isEmpty();
        }

        @Override
        public List<PersistedGrant> persistedGrants() {
            List<UriPermission> permissions = contentResolver.getPersistedUriPermissions();
            if (permissions == null) {
                return null;
            }
            ArrayList<PersistedGrant> grants = new ArrayList<>(permissions.size());
            for (UriPermission permission : permissions) {
                if (permission == null) {
                    grants.add(null);
                    continue;
                }
                Uri uri = permission.getUri();
                int modes = 0;
                if (permission.isReadPermission()) {
                    modes |= MODE_READ;
                }
                if (permission.isWritePermission()) {
                    modes |= MODE_WRITE;
                }
                grants.add(new PersistedGrant(uri == null ? null : uri.toString(), modes));
            }
            return grants;
        }

        @Override
        @android.annotation.SuppressLint("WrongConstant")
        public void take(int modes) {
            contentResolver.takePersistableUriPermission(targetUri, androidModes(modes));
        }

        @Override
        @android.annotation.SuppressLint("WrongConstant")
        public void release(int modes) {
            contentResolver.releasePersistableUriPermission(targetUri, androidModes(modes));
        }

        private static int androidModes(int modes) {
            int flags = 0;
            if ((modes & MODE_READ) != 0) {
                flags |= Intent.FLAG_GRANT_READ_URI_PERMISSION;
            }
            if ((modes & MODE_WRITE) != 0) {
                flags |= Intent.FLAG_GRANT_WRITE_URI_PERMISSION;
            }
            return flags;
        }
    }
}
