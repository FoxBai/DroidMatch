package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.SafRoot;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Process-local SAF capability cache. Raw document IDs remain behind this
 * Android-only boundary and are resolved only from opaque tokens scoped to the
 * persisted root and the parent that listed each document.
 */
final class ProviderSafDocumentCache {
    private final Map<String, DocumentTarget> targetsByLogicalId;

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
    }

    String remember(SafRoot root, String parentDocumentId, String documentId) {
        String logicalId = ProviderOpaqueIds.stable(
                component(root.stableId) + component(parentDocumentId) + component(documentId),
                8
        );
        targetsByLogicalId.put(
                key(root, logicalId),
                new DocumentTarget(documentId, parentDocumentId)
        );
        return logicalId;
    }

    String documentId(SafRoot root, String logicalId) {
        DocumentTarget target = target(root, logicalId);
        return target == null ? null : target.documentId;
    }

    DocumentTarget target(SafRoot root, String logicalId) {
        return targetsByLogicalId.get(key(root, logicalId));
    }

    private static String key(SafRoot root, String logicalId) {
        return root.stableId + "/" + logicalId;
    }

    /** Length prefixes keep adversarial provider IDs from aliasing tuple boundaries. */
    private static String component(String value) {
        return value == null ? "-1:" : value.length() + ":" + value;
    }

    static final class DocumentTarget {
        final String documentId;
        final String parentDocumentId;

        private DocumentTarget(String documentId, String parentDocumentId) {
            this.documentId = documentId;
            this.parentDocumentId = parentDocumentId;
        }
    }
}
