"""Fail-closed ownership checks for protected Android provider operations."""

import re
from typing import Callable


def check_provider_operation_ownership(
    production_sources: dict[str, str],
    provider_source: Callable[[str], str],
    fail: Callable[[str], None],
) -> None:
    """Reject unexpected owners, aliases, and invocation forms."""
    protected_catalog_calls = {
        "appSandboxCatalog.createDirectory(": (provider_source("ProviderMutations.java"), 1),
        "safCatalog.createDirectory(": (provider_source("ProviderMutations.java"), 1),
        "appSandboxCatalog.renamePath(": (provider_source("ProviderMutations.java"), 1),
        "safCatalog.renameDocument(": (provider_source("ProviderMutations.java"), 1),
        "appSandboxCatalog.deletePath(": (provider_source("ProviderMutations.java"), 1),
        "safCatalog.deleteDocument(": (provider_source("ProviderMutations.java"), 1),
        "appSandboxCatalog.openUploadFile(": (provider_source("ProviderTransfers.java"), 1),
        "mediaCatalog.openUploadMedia(": (provider_source("ProviderTransfers.java"), 1),
        "safCatalog.openUploadDocument(": (provider_source("ProviderTransfers.java"), 1),
        "appSandboxCatalog.discardUploadPartial(": (provider_source("ProviderTransfers.java"), 1),
        "safCatalog.discardUploadPartial(": (provider_source("ProviderTransfers.java"), 1),
    }
    provider_operation_calls = {
        ("AndroidAppSandboxCatalog.java", "Files", "createDirectory"): 1,
        ("AndroidSafCatalog.java", "DocumentsContract", "deleteDocument"): 1,
        ("AndroidSafCatalog.java", "DocumentsContract", "renameDocument"): 1,
        ("DmFileProvider.java", "mutations", "createDirectory"): 1,
        ("DmFileProvider.java", "mutations", "deletePath"): 1,
        ("DmFileProvider.java", "mutations", "renamePath"): 1,
        ("DmFileProvider.java", "ProviderTransfers", "discardUploadPartial"): 1,
        ("ProviderIoCleanup.java", "DocumentsContract", "deleteDocument"): 1,
        ("ProviderMutations.java", "appSandboxCatalog", "createDirectory"): 1,
        ("ProviderMutations.java", "appSandboxCatalog", "deletePath"): 1,
        ("ProviderMutations.java", "appSandboxCatalog", "renamePath"): 1,
        ("ProviderMutations.java", "safCatalog", "createDirectory"): 1,
        ("ProviderMutations.java", "safCatalog", "deleteDocument"): 1,
        ("ProviderMutations.java", "safCatalog", "renameDocument"): 1,
        ("ProviderTransfers.java", "appSandboxCatalog", "discardUploadPartial"): 1,
        ("ProviderTransfers.java", "appSandboxCatalog", "openUploadFile"): 1,
        ("ProviderTransfers.java", "mediaCatalog", "openUploadMedia"): 1,
        ("ProviderTransfers.java", "safCatalog", "discardUploadPartial"): 1,
        ("ProviderTransfers.java", "safCatalog", "openUploadDocument"): 1,
        ("ProviderUploadWriters.java", "DocumentsContract", "deleteDocument"): 1,
        ("ProviderUploadWriters.java", "DocumentsContract", "renameDocument"): 1,
        ("RpcControlHandler.java", "fileProvider", "createDirectory"): 1,
        ("RpcControlHandler.java", "fileProvider", "deletePath"): 1,
        ("RpcControlHandler.java", "fileProvider", "renamePath"): 1,
        ("RpcDispatcher.java", "controlHandler", "createDirectory"): 1,
        ("RpcDispatcher.java", "controlHandler", "deletePath"): 1,
        ("RpcDispatcher.java", "controlHandler", "renamePath"): 1,
        ("RpcDispatcher.java", "transferHandler", "discardUploadPartial"): 1,
        ("RpcTransferHandler.java", "fileProvider", "discardUploadPartial"): 1,
        ("SafUploadDocumentStore.java", "DocumentsContract", "deleteDocument"): 1,
    }
    expected_calls = {
        (provider_source(name), receiver, method): count
        for (name, receiver, method), count in provider_operation_calls.items()
    }
    provider_method_counts = {
        ("AndroidAppSandboxCatalog.java", "createDirectory"): 2,
        ("AndroidAppSandboxCatalog.java", "deletePath"): 1,
        ("AndroidAppSandboxCatalog.java", "discardUploadPartial"): 3,
        ("AndroidAppSandboxCatalog.java", "openUploadFile"): 3,
        ("AndroidAppSandboxCatalog.java", "renamePath"): 1,
        ("AndroidMediaCatalog.java", "openUploadMedia"): 1,
        ("AndroidSafCatalog.java", "createDirectory"): 1,
        ("AndroidSafCatalog.java", "deleteDocument"): 2,
        ("AndroidSafCatalog.java", "discardUploadPartial"): 1,
        ("AndroidSafCatalog.java", "openUploadDocument"): 1,
        ("AndroidSafCatalog.java", "renameDocument"): 2,
        ("DmFileProvider.java", "createDirectory"): 2,
        ("DmFileProvider.java", "deletePath"): 2,
        ("DmFileProvider.java", "discardUploadPartial"): 2,
        ("DmFileProvider.java", "renamePath"): 2,
        ("ProviderAppSandboxCatalog.java", "createDirectory"): 2,
        ("ProviderAppSandboxCatalog.java", "deletePath"): 2,
        ("ProviderAppSandboxCatalog.java", "discardUploadPartial"): 2,
        ("ProviderAppSandboxCatalog.java", "openUploadFile"): 2,
        ("ProviderAppSandboxCatalog.java", "renamePath"): 2,
        ("ProviderIoCleanup.java", "deleteDocument"): 1,
        ("ProviderMediaCatalog.java", "openUploadMedia"): 1,
        ("ProviderMutations.java", "createDirectory"): 3,
        ("ProviderMutations.java", "deleteDocument"): 1,
        ("ProviderMutations.java", "deletePath"): 2,
        ("ProviderMutations.java", "renameDocument"): 1,
        ("ProviderMutations.java", "renamePath"): 2,
        ("ProviderSafCatalog.java", "createDirectory"): 1,
        ("ProviderSafCatalog.java", "deleteDocument"): 1,
        ("ProviderSafCatalog.java", "discardUploadPartial"): 1,
        ("ProviderSafCatalog.java", "openUploadDocument"): 1,
        ("ProviderSafCatalog.java", "renameDocument"): 1,
        ("ProviderTransfers.java", "discardUploadPartial"): 3,
        ("ProviderTransfers.java", "openUploadDocument"): 1,
        ("ProviderTransfers.java", "openUploadFile"): 1,
        ("ProviderTransfers.java", "openUploadMedia"): 1,
        ("ProviderUploadWriters.java", "deleteDocument"): 1,
        ("ProviderUploadWriters.java", "renameDocument"): 1,
        ("RpcControlHandler.java", "createDirectory"): 2,
        ("RpcControlHandler.java", "deletePath"): 2,
        ("RpcControlHandler.java", "renamePath"): 2,
        ("RpcDispatcher.java", "createDirectory"): 1,
        ("RpcDispatcher.java", "deletePath"): 1,
        ("RpcDispatcher.java", "discardUploadPartial"): 1,
        ("RpcDispatcher.java", "renamePath"): 1,
        ("RpcTransferHandler.java", "discardUploadPartial"): 2,
        ("SafUploadDocumentStore.java", "deleteDocument"): 1,
    }
    expected_method_counts = {
        (provider_source(name), method): count
        for (name, method), count in provider_method_counts.items()
    }
    saf_catalog_sources = {
        provider_source("ProviderSafCatalog.java"),
        provider_source("DmFileProvider.java"),
        provider_source("ProviderTransfers.java"),
        provider_source("ProviderDirectoryListings.java"),
        provider_source("ProviderMutations.java"),
        provider_source("AndroidSafCatalog.java"),
        provider_source("AndroidSafMutationIdentityReader.java"),
        provider_source("ProviderUploadWriters.java"),
        provider_source("SafDocumentCursorReader.java"),
        provider_source("SafUploadDocumentStore.java"),
    }
    snapshot_source = production_sources.get(
        provider_source("ProviderSafCatalog.java"),
        "",
    )
    snapshot_body = (
        "staticList<SafRoot>snapshotRoots(finalProviderSafCatalogcatalog){"
        "returnCollections.unmodifiableList(newArrayList<>(catalog.roots()));}"
    )
    if re.sub(r"\s+", "", snapshot_source).count(snapshot_body) != 1:
        fail(
            "Android provider integrity contract exact snapshot method body changed: "
            f"{provider_source('ProviderSafCatalog.java')}"
        )

    methods = sorted(
        {method for _, _, method in expected_calls},
        key=len,
        reverse=True,
    )
    alternatives = "|".join(re.escape(method) for method in methods)
    receiver_pattern = re.compile(
        r"\b(?P<receiver>[A-Za-z_$][\w$]*"
        r"(?:\s*\.\s*[A-Za-z_$][\w$]*)*)"
        rf"\s*\.\s*(?P<method>{alternatives})\s*\("
    )
    suffix_pattern = re.compile(rf"\.\s*(?:{alternatives})\s*\(")
    reference_pattern = re.compile(rf"::\s*(?:{alternatives})\b")
    actual_calls: dict[tuple[str, str, str], int] = {}
    actual_method_counts: dict[tuple[str, str], int] = {}

    for name, source in production_sources.items():
        if "ProviderSafCatalog" in source and name not in saf_catalog_sources:
            fail(
                "Android provider integrity contract has an unknown SAF catalog owner: "
                f"{name}"
            )
        for marker, (owner, expected) in protected_catalog_calls.items():
            actual = source.count(marker)
            allowed = expected if name == owner else 0
            if actual != allowed:
                fail(
                    "Android provider integrity contract has an unbound catalog call: "
                    f"{name} / {marker}: {actual}, expected {allowed}"
                )
        if reference_pattern.search(source):
            fail(
                "Android provider integrity contract forbids protected operation "
                f"method references: {name}"
            )
        for method in methods:
            count = len(re.findall(rf"\b{re.escape(method)}\s*\(", source))
            if count:
                actual_method_counts[(name, method)] = count
        matches = list(receiver_pattern.finditer(source))
        if len(matches) != len(suffix_pattern.findall(source)):
            fail(
                "Android provider integrity contract has an opaque protected "
                f"operation receiver: {name}"
            )
        for match in matches:
            receiver = re.sub(r"\s+", "", match.group("receiver"))
            key = (name, receiver, match.group("method"))
            actual_calls[key] = actual_calls.get(key, 0) + 1

    for key in sorted(set(expected_calls) | set(actual_calls)):
        actual = actual_calls.get(key, 0)
        expected = expected_calls.get(key, 0)
        if actual != expected:
            name, receiver, method = key
            fail(
                "Android provider integrity contract has an unbound protected "
                f"operation call: {name} / {receiver}.{method}: "
                f"{actual}, expected {expected}"
            )

    for key in sorted(set(expected_method_counts) | set(actual_method_counts)):
        actual = actual_method_counts.get(key, 0)
        expected = expected_method_counts.get(key, 0)
        if actual != expected:
            name, method = key
            fail(
                "Android provider integrity contract protected operation count "
                f"changed: {name} / {method}: {actual}, expected {expected}"
            )
