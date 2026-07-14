package app.droidmatch.m1;

import app.droidmatch.m1.DmFileProvider.SafRoot;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Process-local SAF capability cache. Raw document IDs remain behind this
 * Android-only boundary and are resolved only from opaque, root-scoped tokens.
 */
final class ProviderSafDocumentCache {
    private final Map<String, String> documentIdsByLogicalId;

    ProviderSafDocumentCache(int maximumEntries) {
        final int boundedMaximum = Math.max(1, maximumEntries);
        documentIdsByLogicalId = Collections.synchronizedMap(
                new LinkedHashMap<String, String>(boundedMaximum, 0.75f, true) {
                    @Override
                    protected boolean removeEldestEntry(Map.Entry<String, String> eldest) {
                        return size() > boundedMaximum;
                    }
                }
        );
    }

    String remember(SafRoot root, String documentId) {
        String logicalId = ProviderOpaqueIds.stable(root.stableId + "\n" + documentId, 8);
        documentIdsByLogicalId.put(key(root, logicalId), documentId);
        return logicalId;
    }

    String documentId(SafRoot root, String logicalId) {
        return documentIdsByLogicalId.get(key(root, logicalId));
    }

    private static String key(SafRoot root, String logicalId) {
        return root.stableId + "/" + logicalId;
    }
}
