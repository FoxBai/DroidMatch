#!/usr/bin/env python3
"""Focused regressions for the cross-platform wire-limit contract gate."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile


SCRIPT = Path(__file__).with_name("check-wire-limits.py")
SPEC = importlib.util.spec_from_file_location("droidmatch_wire_limits", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {SCRIPT}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def populate_valid_fixture(root: Path) -> None:
    contracts_by_path: dict[str, list[object]] = {}
    for contract in MODULE.CONSTANTS:
        contracts_by_path.setdefault(contract.path, []).append(contract)
    for relative_path, contracts in contracts_by_path.items():
        path = root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "\n".join(
                f"static let {contract.name} = {contract.expected}"
                for contract in contracts
            )
            + "\n",
            encoding="utf-8",
        )
    for relative_path, facts in MODULE.CODE_FACTS.items():
        path = root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(facts) + "\n", encoding="utf-8")
    for relative_path, facts in MODULE.DOCUMENT_FACTS.items():
        path = root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(facts) + "\n", encoding="utf-8")


with tempfile.TemporaryDirectory(prefix="droidmatch-wire-limits-") as temp:
    root = Path(temp)
    populate_valid_fixture(root)
    failures = MODULE.validate(root)
    if failures:
        raise AssertionError(f"valid contract fixture was rejected: {failures}")

    swift_limits = root / "mac/Sources/DroidMatchCore/RpcWireLimits.swift"
    original_swift = swift_limits.read_text(encoding="utf-8")
    swift_limits.write_text(
        original_swift.replace(
            "maximumEnvelopeLengthBytes = 4194304",
            "maximumEnvelopeLengthBytes = 8 * 1024 * 1024",
        ),
        encoding="utf-8",
    )
    failures = MODULE.validate(root)
    if not any("maximumEnvelopeLengthBytes=8388608" in failure for failure in failures):
        raise AssertionError(f"Mac envelope-limit drift was not rejected: {failures}")
    swift_limits.write_text(original_swift, encoding="utf-8")

    android_limits = root / (
        "android/app/src/main/java/app/droidmatch/m1/RpcWireLimits.java"
    )
    original_android = android_limits.read_text(encoding="utf-8")
    android_limits.write_text(
        original_android.replace(
            "MAX_TRANSFER_IN_FLIGHT_CHUNKS = 4",
            "MAX_TRANSFER_IN_FLIGHT_CHUNKS = 5",
        ),
        encoding="utf-8",
    )
    failures = MODULE.validate(root)
    if not any("MAX_TRANSFER_IN_FLIGHT_CHUNKS=5" in failure for failure in failures):
        raise AssertionError(f"Android window drift was not rejected: {failures}")
    android_limits.write_text(original_android, encoding="utf-8")

    runtime = root / "docs/protocol-runtime.md"
    original_runtime = runtime.read_text(encoding="utf-8")
    runtime.write_text(
        original_runtime.replace(
            "at most 4 chunks or 2 MiB",
            "at most 8 chunks or 4 MiB",
        ),
        encoding="utf-8",
    )
    failures = MODULE.validate(root)
    if not any("missing wire-limit fact" in failure for failure in failures):
        raise AssertionError(f"documentation window drift was not rejected: {failures}")
    runtime.write_text(original_runtime, encoding="utf-8")

    framed_io = root / "android/app/src/main/java/app/droidmatch/m1/FramedIo.java"
    original_framed_io = framed_io.read_text(encoding="utf-8")
    framed_io.write_text(
        original_framed_io.replace(
            "RpcWireLimits.MAX_ENVELOPE_LENGTH_BYTES",
            "localEnvelopeLimit",
        ),
        encoding="utf-8",
    )
    failures = MODULE.validate(root)
    if not any("missing wire-limit use" in failure for failure in failures):
        raise AssertionError(f"disconnected platform limit was not rejected: {failures}")
    framed_io.write_text(original_framed_io, encoding="utf-8")

    accidental = root / "mac/Sources/DroidMatchCore/AccidentalWireMirror.swift"
    accidental.write_text(
        "static let localTransferWindowBytes = 2 * 1024 * 1024\n",
        encoding="utf-8",
    )
    failures = MODULE.validate(root)
    if not any("duplicates wire byte limit" in failure for failure in failures):
        raise AssertionError(f"duplicate numeric mirror was not rejected: {failures}")
    accidental.unlink()

    swift_limits.write_text(
        original_swift.replace(
            "maximumTransferChunkSizeBytes = 1048576",
            "maximumTransferChunkSizeBytes = dynamicLimit",
        ),
        encoding="utf-8",
    )
    failures = MODULE.validate(root)
    if not any("unsupported integer expression" in failure for failure in failures):
        raise AssertionError(f"non-numeric limit was not rejected: {failures}")
    swift_limits.write_text(original_swift, encoding="utf-8")

    android_limits.unlink()
    failures = MODULE.validate(root)
    if not any("cannot read" in failure and "RpcWireLimits.java" in failure for failure in failures):
        raise AssertionError(f"missing platform limit source was not rejected: {failures}")

print("Wire-limit checker tests passed.")
print("中文：双端线协议限额检查器测试通过。")
