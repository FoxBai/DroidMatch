"""Large race-shape fixtures for the Android provider contract self-test."""

from pathlib import Path


ANDROID_PROVIDER_RACE_REPLACEMENT_CASES = (
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderSafDocumentCache.java"),
        """    ListingResolution resolveForListing(final SafRoot root, final String logicalId) {
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
    }""",
        """    ListingResolution resolveForListing(final SafRoot root, final String logicalId) {
        DocumentTarget target;
        synchronized (targetsByLogicalId) {
            target = logicalId == null
                    ? new DocumentTarget(
                            root.stableId,
                            root.providerAuthority,
                            root.documentId,
                            null,
                            root.displayName,
                            FileKind.FILE_KIND_DIRECTORY
                    )
                    : targetsByLogicalId.get(key(root, logicalId));
        }
        return target == null
                ? null
                : new ListingResolution(target, epochLocked(root));
    }""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderSafDocumentCache.java"),
        """            if (expectedEpoch != epochLocked(root)) {
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
            return logicalIds;""",
        """            ArrayList<String> logicalIds = new ArrayList<>(items.size());
            for (SafItem item : items) {
                logicalIds.add(rememberLocked(
                        root,
                        parentDocumentId,
                        item.documentId,
                        item.displayName,
                        item.kind
                ));
            }
            if (expectedEpoch != epochLocked(root)) {
                return null;
            }
            return logicalIds;""",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderSafDocumentCache.java"),
        """|| (Objects.equals(parentDocumentId, target.parentDocumentId)
                        && Objects.equals(displayName, target.displayName))""",
        "|| false",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidSafCatalog.java"),
        "AndroidSafMutationIdentityReader.uniqueExactChild(",
        "bypassExactChild(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderUploadWriters.java"),
        "published.sizeBytes != nextOffsetBytes",
        "published.sizeBytes != nextOffsetBytes\n                && false",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderUploadWriters.java"),
        "staged.sizeBytes != nextOffsetBytes",
        "staged.sizeBytes != nextOffsetBytes\n                && false",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderUploadWriters.java"),
        "published.kind != FileKind.FILE_KIND_FILE",
        "published.kind != FileKind.FILE_KIND_FILE\n                && false",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderUploadWriters.java"),
        "staged.kind != FileKind.FILE_KIND_FILE",
        "staged.kind != FileKind.FILE_KIND_FILE\n                && false",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/AndroidSafCatalog.java"),
        "sourceIdentity.kind != expectedKind",
        "sourceIdentity.kind != expectedKind\n                && false",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderMutations.java"),
        "FileKind expectedKind = source.kind;",
        "FileKind expectedKind = directory\n"
        "                    ? FileKind.FILE_KIND_DIRECTORY\n"
        "                    : FileKind.FILE_KIND_FILE;",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderTransfers.java"),
        "if (delegate == null)",
        "if (delegate == null && false)",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderMutations.java"),
        "!destination.displayName.equals(renamed.displayName)",
        "false",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderMutations.java"),
        "renamed.kind != expectedKind",
        "false",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderMutations.java"),
        "safDocumentCache.invalidateAfterUncertainMutation(",
        "safDocumentCache.remember(",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderTransfers.java"),
        "safDocumentCache.invalidateChildAfterMutation(",
        "safDocumentCache.target(root, null);",
    ),
    (
        Path("android/app/src/main/java/app/droidmatch/m1/ProviderTransfers.java"),
        "safDocumentCache.invalidateChildAfterMutation(",
        "safDocumentCache.target(saf.root, null);",
    ),
)
