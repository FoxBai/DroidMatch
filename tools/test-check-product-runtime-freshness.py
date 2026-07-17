#!/usr/bin/env python3
"""Offline regressions for the stale-runtime product source contract."""

from __future__ import annotations

import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools/check-product-runtime-freshness.py"
SPEC = importlib.util.spec_from_file_location(
    "check_product_runtime_freshness", MODULE_PATH
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load product runtime freshness checker")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def copy_contract_sources(destination: Path) -> None:
    for relative_path in MODULE.REQUIRED_SNIPPETS:
        source = ROOT / relative_path
        target = destination / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source.read_bytes())


def expect_failure(root: Path, expected_fragment: str) -> None:
    try:
        MODULE.validate(root)
    except MODULE.ProductRuntimeFreshnessContractError as error:
        if expected_fragment not in str(error):
            raise AssertionError(f"unexpected failure: {error}") from error
        return
    raise AssertionError("runtime freshness checker unexpectedly passed")


with TemporaryDirectory() as temporary_directory:
    fixture_root = Path(temporary_directory)
    copy_contract_sources(fixture_root)
    MODULE.validate(fixture_root)

    # Every required seam receives an independent removal regression. This
    # binds the checker to process-vnode capture, App/window ownership, command
    # gating, and all three model boundaries rather than to one sentinel token.
    for relative_path, snippets in MODULE.REQUIRED_SNIPPETS.items():
        path = fixture_root / relative_path
        original = path.read_text(encoding="utf-8")
        for snippet in snippets:
            path.write_text(original.replace(snippet, ""), encoding="utf-8")
            expect_failure(fixture_root, "missing stale-runtime safety wiring")
            path.write_text(original, encoding="utf-8")

    for relative_path, snippets in MODULE.FORBIDDEN_SNIPPETS.items():
        path = fixture_root / relative_path
        original = path.read_text(encoding="utf-8")
        for snippet in snippets:
            path.write_text(original + f"\n// injected regression: {snippet}\n", encoding="utf-8")
            expect_failure(fixture_root, "bypasses stale-runtime ownership")
            path.write_text(original, encoding="utf-8")

    builder_path = fixture_root / "tools/build-mac-app.sh"
    builder = builder_path.read_text(encoding="utf-8")
    first_guard = builder.find(MODULE.PUBLICATION_GUARD_CALL)
    second_guard = builder.find(MODULE.PUBLICATION_GUARD_CALL, first_guard + 1)
    builder_path.write_text(
        builder[:second_guard]
        + builder[second_guard + len(MODULE.PUBLICATION_GUARD_CALL) :],
        encoding="utf-8",
    )
    expect_failure(fixture_root, "must cover recovery, replacement, and first publication")
    builder_path.write_text(
        builder.replace(
            "write_transaction_state swapping\n  publication_started=true\n  "
            + MODULE.PUBLICATION_GUARD_CALL,
            MODULE.PUBLICATION_GUARD_CALL
            + "\n  write_transaction_state swapping\n  publication_started=true",
        ),
        encoding="utf-8",
    )
    expect_failure(fixture_root, "does not protect every mutation boundary")

print("Product runtime freshness checker regressions passed.")
print("中文：产品运行时新鲜度检查器离线回归通过。")
