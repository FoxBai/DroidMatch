package app.droidmatch.m1;

import app.droidmatch.proto.v1.ErrorCode;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Process-local, non-blocking ownership for provider paths.
 *
 * <p>Uploads, resumable-partial cleanup, and mutations share this coordinator.
 * Acquisition only updates in-memory claims; provider I/O always runs after the
 * monitor is released. A claim conflicts with the same target or with any
 * target/ancestor relationship, preventing a directory mutation from racing a
 * descendant upload.</p>
 */
final class ProviderPathCoordinator {
    private final Map<LeaseToken, List<Claim>> active = new IdentityHashMap<>();

    DmFileProvider.UploadWriter openLeased(Claim claim, Opener opener)
            throws DmFileProvider.ProviderCatalogException {
        LeaseToken token = acquire(Collections.singletonList(claim));
        boolean opened = false;
        try {
            DmFileProvider.UploadWriter writer = opener.open();
            if (writer == null) {
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_INTERNAL,
                        "upload provider returned no writer"
                );
            }
            DmFileProvider.UploadWriter leased = new LeasedUploadWriter(writer, token, this);
            opened = true;
            return leased;
        } finally {
            if (!opened) {
                release(token);
            }
        }
    }

    void runLeased(Claim claim, Operation operation)
            throws DmFileProvider.ProviderCatalogException {
        runLeased(Collections.singletonList(claim), operation);
    }

    void runLeased(List<Claim> claims, Operation operation)
            throws DmFileProvider.ProviderCatalogException {
        LeaseToken token = acquire(claims);
        try {
            operation.run();
        } finally {
            release(token);
        }
    }

    private synchronized LeaseToken acquire(List<Claim> claims)
            throws DmFileProvider.ProviderCatalogException {
        ArrayList<Claim> requested = new ArrayList<>(claims);
        if (requested.isEmpty()) {
            throw new DmFileProvider.ProviderCatalogException(
                    ErrorCode.ERROR_CODE_INTERNAL,
                    "provider operation has no path claim"
            );
        }
        for (Claim claim : requested) {
            Objects.requireNonNull(claim, "claim");
        }
        for (List<Claim> held : active.values()) {
            if (conflicts(requested, held)) {
                throw new DmFileProvider.ProviderCatalogException(
                        ErrorCode.ERROR_CODE_ALREADY_EXISTS,
                        "upload destination is already active"
                );
            }
        }
        LeaseToken token = new LeaseToken();
        active.put(token, Collections.unmodifiableList(requested));
        return token;
    }

    private synchronized void release(LeaseToken token) {
        // Identity-qualified removal prevents a repeated close from releasing a
        // later operation that acquired the same logical path.
        active.remove(token);
    }

    private static boolean conflicts(List<Claim> first, List<Claim> second) {
        for (Claim left : first) {
            for (Claim right : second) {
                if (left.conflicts(right)) {
                    return true;
                }
            }
        }
        return false;
    }

    @FunctionalInterface
    interface Opener {
        DmFileProvider.UploadWriter open() throws DmFileProvider.ProviderCatalogException;
    }

    @FunctionalInterface
    interface Operation {
        void run() throws DmFileProvider.ProviderCatalogException;
    }

    static final class Claim {
        private static final String ROOT_ALIAS = "root";

        private final String namespace;
        private final String safRootStableId;
        private final Set<String> targetAliases;
        private final Set<String> ancestorAliases;

        private Claim(
                String namespace,
                String safRootStableId,
                Set<String> targetAliases,
                Set<String> ancestorAliases
        ) {
            this.namespace = namespace;
            this.safRootStableId = safRootStableId;
            this.targetAliases = Collections.unmodifiableSet(targetAliases);
            this.ancestorAliases = Collections.unmodifiableSet(ancestorAliases);
        }

        static Claim appSandbox(String relativePath) {
            String target = appPathAlias(relativePath);
            HashSet<String> ancestors = new HashSet<>();
            int separator = relativePath.lastIndexOf('/');
            while (separator >= 0) {
                ancestors.add(appPathAlias(relativePath.substring(0, separator)));
                separator = relativePath.lastIndexOf('/', separator - 1);
            }
            ancestors.add(appPathAlias(""));
            return new Claim(
                    "app-sandbox",
                    null,
                    singleton(target),
                    ancestors
            );
        }

        static Claim media(DmFileProvider.RootKind rootKind, String displayName) {
            return new Claim(
                    "media:" + rootKind.name(),
                    null,
                    singleton(childAlias("", displayName)),
                    singleton(ROOT_ALIAS)
            );
        }

        static Claim safChild(
                DmFileProvider.SafRoot root,
                List<DmFileProvider.SafRoot> persistedRoots,
                String parentDocumentId,
                String displayName,
                List<String> ancestorDocumentIds
        ) {
            return saf(
                    root,
                    persistedRoots,
                    singleton(childAlias(parentDocumentId, displayName)),
                    ancestorDocumentIds
            );
        }

        static Claim safDocument(
                DmFileProvider.SafRoot root,
                List<DmFileProvider.SafRoot> persistedRoots,
                String documentId,
                String parentDocumentId,
                String displayName,
                List<String> ancestorDocumentIds
        ) {
            HashSet<String> aliases = new HashSet<>();
            aliases.add(documentAlias(documentId));
            if (parentDocumentId != null && displayName != null) {
                aliases.add(childAlias(parentDocumentId, displayName));
            }
            return saf(root, persistedRoots, aliases, ancestorDocumentIds);
        }

        private static Claim saf(
                DmFileProvider.SafRoot root,
                List<DmFileProvider.SafRoot> persistedRoots,
                Set<String> targetAliases,
                List<String> ancestorDocumentIds
        ) {
            HashSet<String> targets = new HashSet<>(targetAliases);
            HashSet<String> ancestors = new HashSet<>();
            ancestors.add(ROOT_ALIAS);
            if (authorityWideSafClaim(root, persistedRoots)
                    || ancestorDocumentIds == null) {
                // Missing lineage is rare because an opaque child token can be
                // obtained only through a listing. Overlapping persisted roots
                // can also hide ancestors above a narrower root. Fail closed by
                // claiming the whole provider authority instead of guessing.
                targets.add(ROOT_ALIAS);
            } else {
                for (String documentId : ancestorDocumentIds) {
                    ancestors.add(documentAlias(documentId));
                }
            }
            return new Claim(safNamespace(root), root.stableId, targets, ancestors);
        }

        private boolean conflicts(Claim other) {
            if (!namespace.equals(other.namespace)) {
                return false;
            }
            if (safRootStableId != null
                    && other.safRootStableId != null
                    && !safRootStableId.equals(other.safRootStableId)) {
                // Persisted grants can change between operations. Two logical
                // roots for one authority may overlap even when either current
                // snapshot shows only one, so never infer disjoint ownership.
                return true;
            }
            return intersects(targetAliases, other.targetAliases)
                    || intersects(targetAliases, other.ancestorAliases)
                    || intersects(ancestorAliases, other.targetAliases);
        }

        private static String safNamespace(DmFileProvider.SafRoot root) {
            if (root.providerAuthority != null) {
                return "saf:authority:" + root.providerAuthority;
            }
            return "saf:stable:" + root.stableId;
        }

        private static boolean authorityWideSafClaim(
                DmFileProvider.SafRoot root,
                List<DmFileProvider.SafRoot> persistedRoots
        ) {
            if (root.providerAuthority == null || persistedRoots == null) {
                return false;
            }
            HashSet<String> stableIds = new HashSet<>();
            stableIds.add(root.stableId);
            for (DmFileProvider.SafRoot candidate : persistedRoots) {
                if (candidate != null
                        && root.providerAuthority.equals(candidate.providerAuthority)) {
                    stableIds.add(candidate.stableId);
                    if (stableIds.size() > 1) {
                        return true;
                    }
                }
            }
            return false;
        }

        private static String appPathAlias(String relativePath) {
            return "path:" + relativePath;
        }

        private static String documentAlias(String documentId) {
            return "document:" + component(documentId);
        }

        private static String childAlias(String parentDocumentId, String displayName) {
            return "child:" + component(parentDocumentId) + component(displayName);
        }

        private static String component(String value) {
            return value == null ? "-1:" : value.length() + ":" + value;
        }

        private static Set<String> singleton(String value) {
            return new HashSet<>(Arrays.asList(value));
        }

        private static boolean intersects(Set<String> first, Set<String> second) {
            Set<String> smaller = first.size() <= second.size() ? first : second;
            Set<String> larger = first.size() <= second.size() ? second : first;
            for (String value : smaller) {
                if (larger.contains(value)) {
                    return true;
                }
            }
            return false;
        }
    }

    private static final class LeaseToken {
    }

    private static final class LeasedUploadWriter implements DmFileProvider.UploadWriter {
        private final DmFileProvider.UploadWriter writer;
        private final LeaseToken token;
        private final ProviderPathCoordinator owner;
        private final AtomicBoolean closed = new AtomicBoolean(false);

        private LeasedUploadWriter(
                DmFileProvider.UploadWriter writer,
                LeaseToken token,
                ProviderPathCoordinator owner
        ) {
            this.writer = writer;
            this.token = token;
            this.owner = owner;
        }

        @Override
        public long nextOffsetBytes() {
            return writer.nextOffsetBytes();
        }

        @Override
        public void writeChunk(long offsetBytes, byte[] data, boolean finalChunk)
                throws DmFileProvider.ProviderCatalogException {
            boolean succeeded = false;
            try {
                writer.writeChunk(offsetBytes, data, finalChunk);
                succeeded = true;
            } finally {
                if (finalChunk || !succeeded) {
                    close();
                }
            }
        }

        @Override
        public void cancel() throws DmFileProvider.ProviderCatalogException {
            if (closed.get()) {
                return;
            }
            writer.cancel();
            if (closed.compareAndSet(false, true)) {
                owner.release(token);
            }
        }

        @Override
        public void close() {
            if (!closed.compareAndSet(false, true)) {
                return;
            }
            try {
                writer.close();
            } finally {
                owner.release(token);
            }
        }
    }
}
