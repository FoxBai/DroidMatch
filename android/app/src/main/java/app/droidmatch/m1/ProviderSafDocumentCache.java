package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.SafRoot;
import app.droidmatch.m1.DmFileProvider.SafItem;
import app.droidmatch.proto.v1.FileKind;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

/**
 * Process-local SAF capability cache. Raw document IDs remain behind this
 * Android-only boundary and are resolved only from opaque tokens scoped to the
 * persisted root and the parent that listed each document.
 */
final class ProviderSafDocumentCache {
    private final Map<String, DocumentTarget> targetsByLogicalId;
    // Identity tokens avoid generation wrap. Bounded epoch eviction can only
    // reject an otherwise valid in-flight listing; it cannot accept a stale one.
    private final Map<String, Object> epochsByProvider;

    ProviderSafDocumentCache(int maximumEntries) {
        final int boundedMaximum = Math.max(1, maximumEntries);
        targetsByLogicalId = Collections.synchronizedMap(
                new LinkedHashMap<String, DocumentTarget>(boundedMaximum, 0.75f, true) {
                    @Override
                    protected boolean removeEldestEntry(Map.Entry<String, DocumentTarget> eldest) {
                        return size() > boundedMaximum;
                    }
                }
        );
        epochsByProvider = new LinkedHashMap<String, Object>(
                boundedMaximum,
                0.75f,
                true
        ) {
            @Override
            protected boolean removeEldestEntry(Map.Entry<String, Object> eldest) {
                return size() > boundedMaximum;
            }
        };
    }

    String remember(SafRoot root, String parentDocumentId, String documentId) {
        return remember(
                root,
                parentDocumentId,
                documentId,
                null,
                FileKind.FILE_KIND_UNSPECIFIED
        );
    }

    String remember(
            SafRoot root,
            String parentDocumentId,
            String documentId,
            String displayName
    ) {
        return remember(
                root,
                parentDocumentId,
                documentId,
                displayName,
                FileKind.FILE_KIND_FILE
        );
    }

    String remember(
            SafRoot root,
            String parentDocumentId,
            String documentId,
            String displayName,
            FileKind kind
    ) {
        synchronized (targetsByLogicalId) {
            return rememberLocked(
                    root,
                    parentDocumentId,
                    documentId,
                    displayName,
                    kind
            );
        }
    }

    ListingResolution resolveForListing(final SafRoot root, final String logicalId) {
        synchronized (targetsByLogicalId) {
            DocumentTarget target = logicalId == null
                    ? new DocumentTarget(
                            root.stableId,
                            root.providerAuthority,
                            root.documentId,
                            null,
                            root.displayName,
                            FileKind.FILE_KIND_DIRECTORY
                    )
                    : targetsByLogicalId.get(key(root, logicalId));
            return target == null
                    ? null
                    : new ListingResolution(target, epochLocked(root));
        }
    }

    List<String> rememberListingIfCurrent(
            SafRoot root,
            String parentDocumentId,
            List<SafItem> items,
            final Object expectedEpoch
    ) {
        synchronized (targetsByLogicalId) {
            if (expectedEpoch != epochLocked(root)) {
                return null;
            }
            ArrayList<String> logicalIds = new ArrayList<>(items.size());
            for (SafItem item : items) {
                logicalIds.add(rememberLocked(
                        root,
                        parentDocumentId,
                        item.documentId,
                        item.displayName,
                        item.kind
                ));
            }
            return logicalIds;
        }
    }

    String rebindAfterRename(
            SafRoot root,
            String oldDocumentId,
            String parentDocumentId,
            String renamedDocumentId,
            String displayName,
            FileKind kind
    ) {
        String renamedLogicalId = logicalId(root, parentDocumentId, renamedDocumentId);
        synchronized (targetsByLogicalId) {
            if (!oldDocumentId.equals(renamedDocumentId)) {
                for (DocumentTarget target : targetsByLogicalId.values()) {
                    if (sameProvider(root, target)
                            && renamedDocumentId.equals(target.documentId)) {
                        advanceEpochLocked(root);
                        targetsByLogicalId.entrySet().removeIf(entry ->
                                sameProvider(root, entry.getValue())
                        );
                        return null;
                    }
                }
            }
            advanceEpochLocked(root);
            targetsByLogicalId.entrySet().removeIf(entry -> {
                DocumentTarget target = entry.getValue();
                return sameProvider(root, target)
                        && (oldDocumentId.equals(target.documentId)
                        || (Objects.equals(parentDocumentId, target.parentDocumentId)
                        && Objects.equals(displayName, target.displayName)));
            });
            targetsByLogicalId.put(
                    key(root, renamedLogicalId),
                    new DocumentTarget(
                            root.stableId,
                            root.providerAuthority,
                            renamedDocumentId,
                            parentDocumentId,
                            displayName,
                            kind
                    )
            );
        }
        return renamedLogicalId;
    }

    void invalidateAfterDelete(SafRoot root, String deletedDocumentId) {
        synchronized (targetsByLogicalId) {
            advanceEpochLocked(root);
            targetsByLogicalId.entrySet().removeIf(entry ->
                    sameProvider(root, entry.getValue())
                            && deletedDocumentId.equals(entry.getValue().documentId)
            );
        }
    }

    void invalidateChildAfterMutation(
            SafRoot root,
            String parentDocumentId,
            String displayName
    ) {
        synchronized (targetsByLogicalId) {
            advanceEpochLocked(root);
            targetsByLogicalId.entrySet().removeIf(entry -> {
                DocumentTarget target = entry.getValue();
                return sameProvider(root, target)
                        && Objects.equals(parentDocumentId, target.parentDocumentId)
                        && Objects.equals(displayName, target.displayName);
            });
        }
    }

    void invalidateAfterUncertainMutation(SafRoot root) {
        synchronized (targetsByLogicalId) {
            advanceEpochLocked(root);
            targetsByLogicalId.entrySet().removeIf(entry ->
                    sameProvider(root, entry.getValue())
            );
        }
    }

    private String rememberLocked(
            SafRoot root,
            String parentDocumentId,
            String documentId,
            String displayName,
            FileKind kind
    ) {
        String logicalId = logicalId(root, parentDocumentId, documentId);
        targetsByLogicalId.put(
                key(root, logicalId),
                new DocumentTarget(
                    root.stableId,
                    root.providerAuthority,
                    documentId,
                    parentDocumentId,
                    displayName,
                    kind
                )
        );
        return logicalId;
    }

    DocumentTarget uniqueTargetForDocument(SafRoot root, String documentId) {
        DocumentTarget found = null;
        synchronized (targetsByLogicalId) {
            for (DocumentTarget target : targetsByLogicalId.values()) {
                if (!root.stableId.equals(target.rootStableId)
                        || !documentId.equals(target.documentId)) {
                    continue;
                }
                if (found != null) {
                    return null;
                }
                found = target;
            }
        }
        return found;
    }

    String documentId(SafRoot root, String logicalId) {
        DocumentTarget target = target(root, logicalId);
        return target == null ? null : target.documentId;
    }

    DocumentTarget target(SafRoot root, String logicalId) {
        return targetsByLogicalId.get(key(root, logicalId));
    }

    /**
     * Returns the supplied directory and every known parent through the root.
     *
     * <p>A missing, ambiguous, or cyclic link returns {@code null}; callers
     * then claim the whole SAF namespace rather than guessing at ancestry.</p>
     */
    List<String> ancestorDocumentIds(SafRoot root, String documentId) {
        if (documentId == null) {
            return null;
        }
        ArrayList<String> ancestors = new ArrayList<>();
        HashSet<String> visited = new HashSet<>();
        String current = documentId;
        synchronized (targetsByLogicalId) {
            while (true) {
                if (!visited.add(current)) {
                    return null;
                }
                ancestors.add(current);
                if (current.equals(root.documentId)) {
                    return ancestors;
                }
                Set<String> parents = parentsForDocumentLocked(root.stableId, current);
                if (parents.size() != 1) {
                    return null;
                }
                current = parents.iterator().next();
                if (current == null) {
                    return null;
                }
            }
        }
    }

    private Set<String> parentsForDocumentLocked(String rootStableId, String documentId) {
        HashSet<String> parents = new HashSet<>();
        for (DocumentTarget target : targetsByLogicalId.values()) {
            if (rootStableId.equals(target.rootStableId)
                    && documentId.equals(target.documentId)) {
                parents.add(target.parentDocumentId);
            }
        }
        return parents;
    }

    private static String key(SafRoot root, String logicalId) {
        return root.stableId + "/" + logicalId;
    }

    private static boolean sameProvider(SafRoot root, DocumentTarget target) {
        if (root.providerAuthority != null) {
            return root.providerAuthority.equals(target.providerAuthority);
        }
        return root.stableId.equals(target.rootStableId);
    }

    private Object epochLocked(SafRoot root) {
        String providerScope = providerScope(root);
        Object epoch = epochsByProvider.get(providerScope);
        if (epoch == null) {
            epoch = new Object();
            epochsByProvider.put(providerScope, epoch);
        }
        return epoch;
    }

    private void advanceEpochLocked(SafRoot root) {
        epochsByProvider.put(providerScope(root), new Object());
    }

    private static String providerScope(SafRoot root) {
        return root.providerAuthority == null
                ? "stable:" + root.stableId
                : "authority:" + root.providerAuthority;
    }

    private static String logicalId(
            SafRoot root,
            String parentDocumentId,
            String documentId
    ) {
        return ProviderOpaqueIds.stable(
                component(root.stableId) + component(parentDocumentId) + component(documentId),
                8
        );
    }

    /** Length prefixes keep adversarial provider IDs from aliasing tuple boundaries. */
    private static String component(String value) {
        return value == null ? "-1:" : value.length() + ":" + value;
    }

    static final class ListingResolution {
        final DocumentTarget target;
        final Object epoch;

        private ListingResolution(final DocumentTarget target, final Object epoch) {
            this.target = target;
            this.epoch = epoch;
        }
    }

    static final class DocumentTarget {
        final String rootStableId;
        final String providerAuthority;
        final String documentId;
        final String parentDocumentId;
        final String displayName;
        final FileKind kind;

        private DocumentTarget(
                String rootStableId,
                String providerAuthority,
                String documentId,
                String parentDocumentId,
                String displayName,
                FileKind kind
        ) {
            this.rootStableId = rootStableId;
            this.providerAuthority = providerAuthority;
            this.documentId = documentId;
            this.parentDocumentId = parentDocumentId;
            this.displayName = displayName;
            this.kind = kind;
        }
    }
}
