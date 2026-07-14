#!/usr/bin/env python3
"""Focused regression tests for the live-document truth gate."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile


SCRIPT = Path(__file__).with_name("check-live-doc-truth.py")
SPEC = importlib.util.spec_from_file_location("droidmatch_live_doc_truth", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {SCRIPT}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def assert_rejected(text: str, expected_name: str) -> None:
    failures = MODULE.find_stale_claims(text)
    if not any(expected_name in failure for failure in failures):
        raise AssertionError(f"expected {expected_name!r} to reject {text!r}: {failures}")


def assert_accepted(text: str) -> None:
    failures = MODULE.find_stale_claims(text)
    if failures:
        raise AssertionError(f"unexpected stale-claim rejection for {text!r}: {failures}")


assert_rejected(
    "Product automatic upload recovery includes SAF.\n"
    "SAF still needs an exact remote partial checkpoint before retry.",
    "SAF resume described as requiring an exact remote partial",
)
assert_rejected(
    "SAF upload cleanup cannot run until a protocol delete mutation exists.",
    "SAF upload cleanup described as unsupported pending delete/mutation",
)
assert_rejected(
    "Still to exercise:\n- Physical USB unplug during a download.",
    "archived physical download unplug listed as pending",
)
assert_rejected(
    "Still to exercise:\n- Real-device source replacement before resume.",
    "archived source-change resume evidence listed as pending",
)
assert_rejected(
    "A sandbox-entitled bundle still needs end-to-end verification",
    "exact stale claim",
)

assert_accepted(
    "SAF recovery truncates a longer provider partial to the durable Mac ACK "
    "before replay; a missing or shorter partial fails closed."
)
assert_accepted(
    "Direct-root SAF upload cleanup uses a fresh authenticated delete-path session."
)
assert_accepted(
    "The unsupported-resume flag checks MediaStore. The cleanup flag removes "
    "direct-root SAF targets through a fresh authenticated delete mutation."
)
assert_accepted(
    "Physical USB unplug during a 10GiB download is archived on Slot C."
)
assert_accepted(
    "Already exercised:\n- Real-device source deletion before resume passed."
)


def populate_minimal_live_docs(root: Path) -> None:
    for relative_path in MODULE.LIVE_DOCS:
        path = root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        if relative_path == "docs/m1-status.md":
            text = "# Test document\n\nLast updated: 2026-07-15\n"
        elif relative_path == "docs/m1-status-zh.md":
            text = "# 测试文档\n\n最后更新：2026-07-15\n"
        else:
            text = "# Test document\n"
        path.write_text(text, encoding="utf-8")
    for relative_path, facts in MODULE.REQUIRED_LIVE_DOC_FACTS.items():
        path = root / relative_path
        with path.open("a", encoding="utf-8") as handle:
            for fact in facts:
                handle.write(f"{fact}\n")


with tempfile.TemporaryDirectory(prefix="droidmatch-live-doc-truth-") as temp:
    root = Path(temp)
    populate_minimal_live_docs(root)
    failures = MODULE.validate_live_docs(root)
    if failures:
        raise AssertionError(f"valid minimal repository was rejected: {failures}")

    status_zh = root / "docs/m1-status-zh.md"
    status_zh.write_text(
        status_zh.read_text(encoding="utf-8").replace(
            "最后更新：2026-07-15", "最后更新：2026-07-14"
        ),
        encoding="utf-8",
    )
    failures = MODULE.validate_live_docs(root)
    if not any("bilingual M1 status dates differ" in failure for failure in failures):
        raise AssertionError(f"repository scan missed bilingual date drift: {failures}")
    status_zh.write_text(
        status_zh.read_text(encoding="utf-8").replace(
            "最后更新：2026-07-14", "最后更新：2026-07-15"
        ),
        encoding="utf-8",
    )

    status_en = root / "docs/m1-status.md"
    status_en.write_text(
        status_en.read_text(encoding="utf-8").replace(
            "Last updated: 2026-07-15", "Updated on 2026-07-15"
        ),
        encoding="utf-8",
    )
    failures = MODULE.validate_live_docs(root)
    if not any("exactly one canonical update date" in failure for failure in failures):
        raise AssertionError(f"repository scan missed absent canonical date: {failures}")
    status_en.write_text(
        status_en.read_text(encoding="utf-8").replace(
            "Updated on 2026-07-15", "Last updated: 2026-07-15"
        ),
        encoding="utf-8",
    )

    status_zh.write_text(
        status_zh.read_text(encoding="utf-8").replace(
            MODULE.DIRECT_MAIN_TOOL_FACT, "removed-direct-main-tool-fact"
        ),
        encoding="utf-8",
    )
    failures = MODULE.validate_live_docs(root)
    if not any(
        "docs/m1-status-zh.md is missing current product fact" in failure
        and MODULE.DIRECT_MAIN_TOOL_FACT in failure
        for failure in failures
    ):
        raise AssertionError(f"repository scan missed direct-main tool drift: {failures}")
    status_zh.write_text(
        status_zh.read_text(encoding="utf-8").replace(
            "removed-direct-main-tool-fact", MODULE.DIRECT_MAIN_TOOL_FACT
        ),
        encoding="utf-8",
    )

    status_zh.write_text(
        status_zh.read_text(encoding="utf-8").replace(
            "最后更新：2026-07-15", "最后更新：2026-02-30"
        ),
        encoding="utf-8",
    )
    failures = MODULE.validate_live_docs(root)
    if not any("invalid canonical update date" in failure for failure in failures):
        raise AssertionError(f"repository scan missed invalid calendar date: {failures}")
    status_zh.write_text(
        status_zh.read_text(encoding="utf-8").replace(
            "最后更新：2026-02-30", "最后更新：2026-07-15"
        ),
        encoding="utf-8",
    )

    protocol_runtime = root / "docs/protocol-runtime.md"
    protocol_runtime.write_text(
        protocol_runtime.read_text(encoding="utf-8")
        + "SAF upload cleanup is not supported until delete mutation lands.\n",
        encoding="utf-8",
    )
    failures = MODULE.validate_live_docs(root)
    if not any("SAF upload cleanup" in failure for failure in failures):
        raise AssertionError(f"repository scan missed paraphrased stale claim: {failures}")

    protocol_runtime.write_text("# Test document\n", encoding="utf-8")
    readme = root / "README.md"
    readme.write_text("# Test document\n", encoding="utf-8")
    failures = MODULE.validate_live_docs(root)
    if not any("README.md is missing current product fact" in failure for failure in failures):
        raise AssertionError(f"repository scan missed required current fact: {failures}")

    (root / "android/README.md").unlink()
    failures = MODULE.validate_live_docs(root)
    if "missing live document: android/README.md" not in failures:
        raise AssertionError(f"repository scan missed absent live document: {failures}")

print("Live-document truth checker tests passed.")
print("中文：活文档当前事实检查器测试通过。")
