"""Focused Android provider integrity checks for the maintainer contract."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Callable
from maintainer_android_provider_operations import check_provider_operation_ownership

def _java_code_only(source: str) -> str:
    """Blank comments and literals while preserving source positions."""
    cleaned = list(source)
    index = 0
    while index < len(source):
        if source.startswith("//", index):
            end = source.find("\n", index + 2)
            end = len(source) if end < 0 else end
            for offset in range(index, end):
                cleaned[offset] = " "
            index = end
            continue
        if source.startswith("/*", index):
            end = source.find("*/", index + 2)
            end = len(source) if end < 0 else end + 2
            for offset in range(index, end):
                if cleaned[offset] != "\n":
                    cleaned[offset] = " "
            index = end
            continue
        if source[index] in {'"', "'"}:
            quote = source[index]
            cleaned[index] = " "
            index += 1
            while index < len(source):
                current = source[index]
                if current != "\n":
                    cleaned[index] = " "
                index += 1
                if current == "\\" and index < len(source):
                    if source[index] != "\n":
                        cleaned[index] = " "
                    index += 1
                elif current == quote:
                    break
            continue
        index += 1
    return "".join(cleaned)


def _java_call_bodies(source: str, marker: str) -> list[str]:
    bodies = []
    search_from = 0
    while True:
        start = source.find(marker, search_from)
        if start < 0:
            return bodies
        opening = start + len(marker) - 1
        depth = 0
        for index in range(opening, len(source)):
            if source[index] == "(":
                depth += 1
            elif source[index] == ")":
                depth -= 1
                if depth == 0:
                    bodies.append(source[start:index + 1])
                    search_from = index + 1
                    break
        else:
            return []


def _java_call_arguments(call: str) -> list[str]:
    opening = call.find("(")
    if opening < 0 or not call.endswith(")"):
        return []
    arguments = []
    start = opening + 1
    depth = 0
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    for index in range(start, len(call) - 1):
        character = call[index]
        if character in "([{":
            stack.append(character)
            depth += 1
        elif character in pairs:
            if not stack or stack.pop() != pairs[character]:
                return []
            depth -= 1
        elif character == "," and depth == 0:
            arguments.append(call[start:index])
            start = index + 1
    if stack:
        return []
    arguments.append(call[start:-1])
    return arguments


def _check_lease_bound_calls(
    source: str,
    name: str,
    marker: str,
    calls: tuple[str, ...],
    fail: Callable[[str], None],
) -> None:
    code = _java_code_only(source)
    bodies = _java_call_bodies(code, marker)
    for call in calls:
        total = code.count(call)
        nested = sum(body.count(call) for body in bodies)
        if total != 1 or nested != 1:
            fail(
                "Android provider integrity contract has an unleased or duplicate "
                f"provider call: {name} / {call}: total {total}, leased {nested}"
            )


def _check_call_argument(
    source: str,
    name: str,
    marker: str,
    expected_count: int,
    argument_index: int,
    expected_value: str,
    fail: Callable[[str], None],
) -> None:
    calls = _java_call_bodies(_java_code_only(source), marker)
    if len(calls) != expected_count:
        fail(
            "Android provider integrity contract SAF claim count changed: "
            f"{name} / {marker}: {len(calls)}, expected {expected_count}"
        )
    for call in calls:
        arguments = _java_call_arguments(call)
        actual = (
            ""
            if len(arguments) <= argument_index
            else re.sub(r"\s+", "", arguments[argument_index])
        )
        if actual != expected_value:
            fail(
                "Android provider integrity contract call argument changed: "
                f"{name} / {marker} / {argument_index}: {actual}"
            )


def _check_call_shapes(
    source: str,
    name: str,
    marker: str,
    expected: tuple[tuple[str, ...], ...],
    fail: Callable[[str], None],
) -> None:
    calls = _java_call_bodies(_java_code_only(source), marker)
    actual = tuple(
        tuple(re.sub(r"\s+", "", argument) for argument in _java_call_arguments(call))
        for call in calls
    )
    if actual != expected:
        fail(
            "Android provider integrity contract constructor arguments changed: "
            f"{name} / {marker}: {actual}"
        )


def _balanced_java_block(code: str, opening: int) -> tuple[str, int] | None:
    depth = 0
    for index in range(opening, len(code)):
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                return code[opening + 1:index], index + 1
    return None


def _check_single_synchronized_method(
    source: str,
    name: str,
    marker: str,
    ordered: tuple[str, ...],
    counts: dict[str, int],
    fail: Callable[[str], None],
) -> None:
    code = _java_code_only(source)
    if code.count(marker) != 1:
        fail(
            "Android provider integrity contract synchronized method count "
            f"changed: {name} / {marker}"
        )
    start = code.find(marker)
    opening = code.find("{", start + len(marker))
    method = None if opening < 0 else _balanced_java_block(code, opening)
    if method is None:
        fail(
            "Android provider integrity contract has an unparseable method: "
            f"{name} / {marker}"
        )
    method_body = method[0]
    synchronized_marker = "synchronized (targetsByLogicalId)"
    if method_body.count(synchronized_marker) != 1:
        fail(
            "Android provider integrity contract lost its single cache lock: "
            f"{name} / {marker}"
        )
    synchronized_start = method_body.find(synchronized_marker)
    synchronized_opening = method_body.find(
        "{",
        synchronized_start + len(synchronized_marker),
    )
    synchronized = _balanced_java_block(method_body, synchronized_opening)
    if (
        synchronized is None
        or method_body[:synchronized_start].strip()
        or method_body[synchronized[1]:].strip()
    ):
        fail(
            "Android provider integrity contract moved cache work outside its lock: "
            f"{name} / {marker}"
        )
    locked_body = synchronized[0]
    cursor = 0
    for fragment in ordered:
        position = locked_body.find(fragment, cursor)
        if position < 0:
            fail(
                "Android provider integrity contract reordered cache work: "
                f"{name} / {marker} / {fragment}"
            )
        cursor = position + len(fragment)
    for fragment, expected in counts.items():
        actual = locked_body.count(fragment)
        if actual != expected:
            fail(
                "Android provider integrity contract cache operation count changed: "
                f"{name} / {marker} / {fragment}: {actual}, expected {expected}"
            )


def _check_nested_lease_groups(
    source: str,
    name: str,
    marker: str,
    groups: tuple[tuple[str, ...], ...],
    fail: Callable[[str], None],
) -> None:
    bodies = _java_call_bodies(_java_code_only(source), marker)
    if len(bodies) != len(groups):
        fail(
            "Android provider integrity contract lease-call shape changed: "
            f"{name} / {marker}: {len(bodies)}, expected {len(groups)}"
        )
    matched_bodies = set()
    for group in groups:
        matches = [
            index
            for index, body in enumerate(bodies)
            if all(fragment in body for fragment in group)
        ]
        if len(matches) != 1 or matches[0] in matched_bodies:
            fail(
                "Android provider integrity contract lost a nested operation marker: "
                f"{name} / {' + '.join(group)}"
            )
        matched_bodies.add(matches[0])
    if len(matched_bodies) != len(bodies):
        fail(
            "Android provider integrity contract contains an unbound lease call: "
            f"{name} / {marker}"
        )


def check_android_provider_integrity(
    root: Path,
    fail: Callable[[str], None],
) -> None:
    """Bind provider coordination and SAF reconciliation claims to their seams."""
    source_sets_root = (
        root
        / "android"
        / "app"
        / "src"
    )
    java_root = (
        source_sets_root
        / "main"
        / "java"
    )
    provider_root = (
        java_root
        / "app"
        / "droidmatch"
        / "m1"
    )
    provider_relative = provider_root.relative_to(source_sets_root).as_posix()

    def provider_source(name: str) -> str:
        return f"{provider_relative}/{name}"

    required = {
        "AndroidSafUploadOpener.java": (
            "private final SafUploadDocumentStore documentStore;",
            "this(new AndroidSafUploadDocumentStore(contentResolver));",
            "documentStore.exactChildren(",
            "documentStore.create(",
            "documentStore.openOutput(",
            "SafDocumentPolicy.uploadPartialDisplayName(",
            "finalDisplayName = displayName;",
            "validatePartialForCleanup(existing, expectedSizeBytes);",
            "validatePartialForCleanup(child, expectedSizeBytes);",
            "document.sizeBytes < 0",
            "exception.code != ErrorCode.ERROR_CODE_NOT_FOUND",
            "exact.kind != FileKind.FILE_KIND_FILE",
            "!created.documentId.equals(exact.documentId)",
            "ProviderLiveAuthorization commitAuthorization",
        ),
        "SafUploadDocumentStore.java": (
            "interface SafUploadDocumentStore",
            "final class AndroidSafUploadDocumentStore implements SafUploadDocumentStore",
            "if (cursor == null)",
            "childrenByDisplayName(cursor, displayName, 2)",
            "DocumentsContract.deleteDocument(contentResolver, uri(document))",
            "AndroidSafMutationIdentityReader.uniqueExactChild(",
            "contentResolver.openOutputStream(",
            "contentResolver.openFileDescriptor(uri(document), \"rw\")",
        ),
        "AndroidSafMutationIdentityReader.java": (
            "static Result read(",
            "static Uri canonicalUri(",
            "!Objects.equals(treeAuthority, returnedUri.getAuthority())",
            "SafDocumentCursorReader.singleMutationIdentity(cursor)",
            "!returnedDocumentId.equals(identity.documentId)",
            "static ProviderSafCatalog.MutationIdentity uniqueExactChild(",
            "static boolean sameIdentity(",
        ),
        "ProviderUploadWriters.java": (
            "ProviderSafCatalog.MutationIdentity rename(String displayName)",
            "ProviderSafCatalog.MutationIdentity verifyPublished()",
            "private final Uri treeUri;",
            "private final String parentDocumentId;",
            "staged.kind != FileKind.FILE_KIND_FILE", "staged.sizeBytes != nextOffsetBytes",
            "documentOperations.rename(finalDisplayName)", "!finalDisplayName.equals(published.displayName)",
            "published.kind != FileKind.FILE_KIND_FILE", "published.sizeBytes != nextOffsetBytes",
            "deleteDocumentQuietly(documentOperations);",
        ),
        "ProviderPathCoordinator.java": (
            "private synchronized LeaseToken acquire(",
            "private synchronized void release(",
            "authorityWideSafClaim(root, persistedRoots)",
            "!safRootStableId.equals(other.safRootStableId)",
            "targets.add(ROOT_ALIAS);",
            "owner.release(token);",
        ),
        "ProviderSafCatalog.java": (
            "final class MutationIdentity",
            "final String documentId;",
            "final String displayName;",
            "final long sizeBytes;",
            "default MutationIdentity createDirectory(",
            "default MutationIdentity renameDocument(",
            "static List<SafRoot> snapshotRoots(final ProviderSafCatalog catalog)",
            "return Collections.unmodifiableList(new ArrayList<>(catalog.roots()));",
        ),
        "AndroidSafCatalog.java": (
            "Uri renamed = DocumentsContract.renameDocument(",
            "AndroidSafMutationIdentityReader.read(",
            "AndroidSafMutationIdentityReader.uniqueExactChild(",
            "AndroidSafMutationIdentityReader.sameIdentity(", "sourceIdentity.kind != expectedKind",
            "!documentId.equals(metadata.documentId)",
        ),
        "ProviderSafDocumentCache.java": (
            "String rebindAfterRename(",
            "void invalidateAfterDelete(", "void invalidateChildAfterMutation(",
            "void invalidateAfterUncertainMutation(",
            "ListingResolution resolveForListing(",
            "List<String> rememberListingIfCurrent(",
            "epochsByProvider.put(providerScope(root), new Object());",
            "return root.providerAuthority.equals(target.providerAuthority);",
            "oldDocumentId.equals(target.documentId)",
            "deletedDocumentId.equals(entry.getValue().documentId)", "return sameProvider(root, target)",
        ),
        "ProviderDirectoryListings.java": (
            "target.cacheEpoch",
            "safDocumentCache.rememberListingIfCurrent(",
            "\"SAF directory changed during listing\"",
        ),
        "ProviderPathRouter.java": (
            "safDocumentCache.resolveForListing(root, logicalDocumentId)",
            "final List<SafRoot> rootsSnapshot;",
            "final Object cacheEpoch;",
            "this.cacheEpoch = cacheEpoch;",
            "private static SafTarget directory(",
            "private static SafUploadTarget file(",
            "SafDocumentPolicy.isUploadPartialDisplayName(displayName)",
        ),
        "DmFileProvider.java": (
            "private static final ProviderPathCoordinator PROCESS_PROVIDER_PATHS =",
            "private static final ProviderSafDocumentCache PROCESS_SAF_DOCUMENTS =",
            "this.safDocumentCache = PROCESS_SAF_DOCUMENTS;",
            "final String providerAuthority;",
        ),
        "ProviderMutations.java": (
            "private final ProviderPathCoordinator pathCoordinator;",
            "pathCoordinator.runLeased(",
            "ProviderSafCatalog.MutationIdentity renamed;",
            "safDocumentCache.rebindAfterRename(", "safDocumentCache.invalidateAfterDelete(",
            "safDocumentCache.invalidateAfterUncertainMutation(", "safDocumentCache.invalidateChildAfterMutation(",
            "!destination.displayName.equals(renamed.displayName)",
            "renamed.kind != expectedKind", "FileKind expectedKind = source.kind;",
            "final List<SafRoot> safRoots = ProviderSafCatalog.snapshotRoots(safCatalog);",
            "safChildClaim(target)",
            "safDocumentClaim(target)",
        ),
        "ProviderTransfers.java": (
            "pathCoordinator.openLeased(",
            "pathCoordinator.runLeased(",
            "mutationAwareSafUpload(", "if (delegate == null)",
            "safDocumentCache.invalidateChildAfterMutation(",
            "final List<SafRoot> safRoots = ProviderSafCatalog.snapshotRoots(safCatalog);",
        ),
    }
    forbidden = {
        "AndroidSafUploadOpener.java": (
            "private final ContentResolver",
            "contentResolver.",
            "DocumentsContract.",
            "ProviderIoCleanup.deleteDocumentQuietly(",
        ),
        "ProviderMutations.java": (
            "Collections.singletonList(",
            "Collections.unmodifiableList(",
            "new ArrayList<",
            "List.of(",
            ".subList(",
        ),
        "ProviderTransfers.java": (
            "Collections.singletonList(",
            "Collections.unmodifiableList(",
            "new ArrayList<",
            "List.of(",
            ".subList(",
        ),
        "AndroidSafMutationIdentityReader.java": ("!returnedDocumentId.equals(identity.documentId) && false",),
        "AndroidSafCatalog.java": ("sourceIdentity.kind != expectedKind && false",),
        "ProviderUploadWriters.java": ("staged.kind != FileKind.FILE_KIND_FILE && false", "staged.sizeBytes != nextOffsetBytes && false", "published.kind != FileKind.FILE_KIND_FILE && false", "published.sizeBytes != nextOffsetBytes && false"),
        "ProviderPathRouter.java": (
            "Collections.singletonList(",
            "Collections.unmodifiableList(",
            "List.of(",
            ".subList(",
        ),
    }
    exact_counts = {
        "AndroidSafUploadOpener.java": {
            "documentStore.exactChildren(": 1,
            "documentStore.delete(": 3,
            "documentStore.create(": 1,
            "documentStore.openOutput(": 1,
        },
        "DmFileProvider.java": {
            "PROCESS_PROVIDER_PATHS": 5,
            "PROCESS_SAF_DOCUMENTS": 2,
        },
        "ProviderSafDocumentCache.java": {
            "advanceEpochLocked(root);": 5, "Objects.equals(parentDocumentId, target.parentDocumentId)": 2,
            "ListingResolution resolveForListing(": 1, "Objects.equals(displayName, target.displayName)": 2,
            "snapshotEpoch(": 0,
            "ListingResolution resolveForListing(final SafRoot root, final String logicalId)": 1,
            "final Object expectedEpoch": 1,
            "private ListingResolution(final DocumentTarget target, final Object epoch)": 1,
        },
        "ProviderDirectoryListings.java": {
            "target.cacheEpoch": 1,
            "snapshotEpoch(": 0,
        },
        "ProviderPathRouter.java": {
            "safDocumentCache.resolveForListing(": 1,
            "final List<SafRoot> rootsSnapshot;": 2,
            "this.rootsSnapshot = rootsSnapshot;": 2,
            "final List<SafRoot> roots,": 4,
            "final List<SafRoot> rootsSnapshot,": 4,
            "final Object cacheEpoch": 3,
        },
        "ProviderSafCatalog.java": {
            "static List<SafRoot> snapshotRoots(final ProviderSafCatalog catalog)": 1,
            "new ArrayList<>(catalog.roots())": 1,
            "catalog.roots()": 1,
        },
        "AndroidSafCatalog.java": {
            "AndroidSafMutationIdentityReader.read(": 2,
            "AndroidSafMutationIdentityReader.uniqueExactChild(": 6,
        },
        "ProviderUploadWriters.java": {
            "documentOperations.rename(finalDisplayName)": 1,
            "staged.kind != FileKind.FILE_KIND_FILE": 1, "published.kind != FileKind.FILE_KIND_FILE": 1,
            "staged.sizeBytes != nextOffsetBytes": 1, "published.sizeBytes != nextOffsetBytes": 1,
            "AndroidSafMutationIdentityReader.read(": 1,
        },
        "ProviderMutations.java": {
            "pathCoordinator.runLeased(": 6,
            "safDocumentCache.invalidateAfterUncertainMutation(": 9,
            "safDocumentCache.invalidateChildAfterMutation(": 1,
            "!destination.displayName.equals(renamed.displayName)": 1,
            "safCatalog.roots()": 0,
            "new ArrayList<>(safCatalog.roots())": 0,
            "final List<SafRoot> safRoots = ProviderSafCatalog.snapshotRoots(safCatalog);": 3,
        },
        "ProviderTransfers.java": {
            "pathCoordinator.openLeased(": 3,
            "pathCoordinator.runLeased(": 2,
            "safDocumentCache.invalidateChildAfterMutation(": 4,
            "safCatalog.roots()": 0,
            "new ArrayList<>(safCatalog.roots())": 0,
            "final List<SafRoot> safRoots = ProviderSafCatalog.snapshotRoots(safCatalog);": 3,
        },
    }
    nested_lease_groups = {
        "ProviderMutations.java": (
            (
                "pathCoordinator.runLeased(",
                (
                    ("appSandboxCatalog.createDirectory(",),
                    ("safCatalog.createDirectory(", "safDocumentCache.invalidateChildAfterMutation("),
                    ("appSandboxCatalog.renamePath(",),
                    (
                        "safCatalog.renameDocument(",
                        "safDocumentCache.rebindAfterRename(",
                    ),
                    ("appSandboxCatalog.deletePath(",),
                    (
                        "safCatalog.deleteDocument(",
                        "safDocumentCache.invalidateAfterDelete(",
                    ),
                ),
            ),
        ),
        "ProviderTransfers.java": (
            (
                "pathCoordinator.openLeased(",
                (
                    ("appSandboxCatalog.openUploadFile(",),
                    ("mediaCatalog.openUploadMedia(",),
                    ("safCatalog.openUploadDocument(",),
                ),
            ),
            (
                "pathCoordinator.runLeased(",
                (
                    ("appSandboxCatalog.discardUploadPartial(",),
                    ("safCatalog.discardUploadPartial(",),
                ),
            ),
        ),
    }
    lease_bound_calls = {
        "ProviderMutations.java": (
            (
                "pathCoordinator.runLeased(",
                (
                    "appSandboxCatalog.createDirectory(",
                    "safCatalog.createDirectory(",
                    "safDocumentCache.invalidateChildAfterMutation(",
                    "appSandboxCatalog.renamePath(",
                    "safCatalog.renameDocument(",
                    "safDocumentCache.rebindAfterRename(",
                    "appSandboxCatalog.deletePath(",
                    "safCatalog.deleteDocument(",
                    "safDocumentCache.invalidateAfterDelete(",
                ),
            ),
        ),
        "ProviderTransfers.java": (
            (
                "pathCoordinator.openLeased(",
                (
                    "appSandboxCatalog.openUploadFile(",
                    "mediaCatalog.openUploadMedia(",
                    "safCatalog.openUploadDocument(",
                ),
            ),
            (
                "pathCoordinator.runLeased(",
                (
                    "appSandboxCatalog.discardUploadPartial(",
                    "safCatalog.discardUploadPartial(",
                ),
            ),
        ),
    }
    call_argument_checks = {
        "ProviderMutations.java": (
            ("ProviderPathCoordinator.Claim.safChild(", 1, 1, "target.rootsSnapshot"),
            ("ProviderPathCoordinator.Claim.safDocument(", 1, 1, "target.rootsSnapshot"),
            ("ProviderSafCatalog.snapshotRoots(", 3, 0, "safCatalog"),
            ("ProviderPathRouter.safCreateDirectory(", 1, 1, "safRoots"),
            ("ProviderPathRouter.safDirectory(", 2, 1, "safRoots"),
            ("ProviderPathRouter.safUpload(", 1, 1, "safRoots"),
            ("safCatalog.renameDocument(", 1, 5, "expectedKind"),
        ),
        "ProviderTransfers.java": (
            ("ProviderPathCoordinator.Claim.safChild(", 2, 1, "saf.rootsSnapshot"),
            ("ProviderSafCatalog.snapshotRoots(", 3, 0, "safCatalog"),
            ("ProviderPathRouter.safDirectory(", 1, 1, "safRoots"),
            ("ProviderPathRouter.safUpload(", 2, 1, "safRoots"),
        ),
        "ProviderPathRouter.java": (
            ("SafTarget.directory(", 1, 1, "roots"),
            ("SafTarget.directory(", 1, 6, "resolution.epoch"),
            ("SafUploadTarget.file(", 1, 1, "roots"),
        ),
    }
    constructor_shape_checks = {
        "ProviderPathRouter.java": (
            (
                "new SafTarget(",
                (
                    (
                        "root",
                        "rootsSnapshot",
                        "documentId",
                        "parentDocumentId",
                        "displayName",
                        "kind",
                        "cacheEpoch",
                        "null",
                    ),
                    ("null", "null", "null", "null", "null", "null", "null", "error"),
                ),
            ),
            (
                "new SafUploadTarget(",
                (
                    (
                        "root",
                        "rootsSnapshot",
                        "parentDocumentId",
                        "displayName",
                        "null",
                    ),
                    ("null", "null", "null", "null", "error"),
                ),
            ),
        ),
        "ProviderSafDocumentCache.java": (
            (
                "new ListingResolution(",
                (("target", "epochLocked(root)"),),
            ),
        ),
    }
    synchronized_method_checks = {
        "ProviderSafDocumentCache.java": (
            (
                "ListingResolution resolveForListing(",
                (
                    "DocumentTarget target = logicalId == null",
                    ": targetsByLogicalId.get(key(root, logicalId));",
                    "return target == null",
                    "new ListingResolution(target, epochLocked(root))",
                ),
                {
                    "targetsByLogicalId.get(key(root, logicalId))": 1,
                    "new ListingResolution(target, epochLocked(root))": 1,
                },
            ),
            (
                "List<String> rememberListingIfCurrent(",
                (
                    "if (expectedEpoch != epochLocked(root))",
                    "return null;",
                    "ArrayList<String> logicalIds = new ArrayList<>(items.size());",
                    "for (SafItem item : items)",
                    "rememberLocked(",
                    "return logicalIds;",
                ),
                {
                    "if (expectedEpoch != epochLocked(root))": 1,
                    "rememberLocked(": 1,
                    "return logicalIds;": 1,
                },
            ),
        ),
    }
    for name, fragments in required.items():
        source_path = provider_root / name
        if not source_path.is_file():
            fail(f"Android provider integrity contract source is missing: {name}")
        source = source_path.read_text(encoding="utf-8")
        for fragment in fragments:
            if fragment not in source:
                fail(
                    "Android provider integrity contract is missing wiring: "
                    f"{name} / {fragment}"
                )

    for name, fragments in forbidden.items():
        source = re.sub(r"\s+", "", _java_code_only((provider_root / name).read_text(encoding="utf-8")))
        for fragment in fragments:
            if re.sub(r"\s+", "", fragment) in source:
                fail(
                    "Android provider integrity contract has forbidden wiring: "
                    f"{name} / {fragment}"
                )
    for name, counts in exact_counts.items():
        source = _java_code_only(
            (provider_root / name).read_text(encoding="utf-8")
        )
        for fragment, expected in counts.items():
            actual = source.count(fragment)
            if actual != expected:
                fail(
                    "Android provider integrity contract wiring count changed: "
                    f"{name} / {fragment}: {actual}, expected {expected}"
                )

    for name, checks in nested_lease_groups.items():
        source = (provider_root / name).read_text(encoding="utf-8")
        for marker, groups in checks:
            _check_nested_lease_groups(source, name, marker, groups, fail)

    for name, checks in lease_bound_calls.items():
        source = (provider_root / name).read_text(encoding="utf-8")
        for marker, calls in checks:
            _check_lease_bound_calls(source, name, marker, calls, fail)

    for name, checks in call_argument_checks.items():
        source = (provider_root / name).read_text(encoding="utf-8")
        for marker, expected_count, argument_index, expected_value in checks:
            _check_call_argument(
                source,
                name,
                marker,
                expected_count,
                argument_index,
                expected_value,
                fail,
            )

    for name, checks in constructor_shape_checks.items():
        source = (provider_root / name).read_text(encoding="utf-8")
        for marker, expected in checks:
            _check_call_shapes(source, name, marker, expected, fail)

    for name, checks in synchronized_method_checks.items():
        source = (provider_root / name).read_text(encoding="utf-8")
        for marker, ordered, counts in checks:
            _check_single_synchronized_method(
                source,
                name,
                marker,
                ordered,
                counts,
                fail,
            )

    production_sources = {
        source_path.relative_to(source_sets_root).as_posix(): _java_code_only(
            source_path.read_text(encoding="utf-8")
        )
        for source_set in source_sets_root.iterdir()
        if source_set.is_dir()
        and not source_set.name.startswith(("test", "androidTest"))
        and source_set.name != "testFixtures"
        for source_path in (source_set / "java").rglob("*.java")
        if (source_set / "java").is_dir()
    }
    check_provider_operation_ownership(
        production_sources,
        provider_source,
        fail,
    )

    coordinator_construction = re.compile(r"\bnew\s+ProviderPathCoordinator\s*\(")
    coordinator_owner = provider_source("DmFileProvider.java")
    for name, source in production_sources.items():
        count = len(coordinator_construction.findall(source))
        expected = 1 if name == coordinator_owner else 0
        if count != expected:
            fail(
                "Android provider integrity contract has split coordinator construction: "
                f"{name}: {count}, expected {expected}"
            )

    cache_construction = re.compile(r"\bnew\s+ProviderSafDocumentCache\s*\(")
    for name, source in production_sources.items():
        count = len(cache_construction.findall(source))
        expected = 2 if name == coordinator_owner else 0
        if count != expected:
            fail(
                "Android provider integrity contract has split SAF cache construction: "
                f"{name}: {count}, expected {expected}"
            )

    for name, source in production_sources.items():
        if "ProviderUploadLeases" in source:
            fail(
                "Android provider integrity contract forbids the old upload lease: "
                f"{name}"
            )
