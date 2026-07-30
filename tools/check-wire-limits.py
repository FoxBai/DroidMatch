#!/usr/bin/env python3
"""Keep documented M1 framing and transfer limits aligned on both platforms."""

from __future__ import annotations

import argparse
import ast
from dataclasses import dataclass
import os
from pathlib import Path
import re
import stat
import sys


MAX_INPUT_BYTES = 2 * 1024 * 1024


@dataclass(frozen=True)
class ConstantContract:
    path: str
    name: str
    expected: int


CONSTANTS = (
    ConstantContract(
        "mac/Sources/DroidMatchCore/RpcWireLimits.swift",
        "maximumEnvelopeLengthBytes",
        4 * 1024 * 1024,
    ),
    ConstantContract(
        "mac/Sources/DroidMatchCore/RpcWireLimits.swift",
        "defaultTransferChunkSizeBytes",
        256 * 1024,
    ),
    ConstantContract(
        "mac/Sources/DroidMatchCore/RpcWireLimits.swift",
        "maximumTransferChunkSizeBytes",
        1024 * 1024,
    ),
    ConstantContract(
        "mac/Sources/DroidMatchCore/RpcWireLimits.swift",
        "maximumTransferInFlightChunks",
        4,
    ),
    ConstantContract(
        "mac/Sources/DroidMatchCore/RpcWireLimits.swift",
        "maximumTransferInFlightBytes",
        2 * 1024 * 1024,
    ),
    ConstantContract(
        "android/app/src/main/java/app/droidmatch/m1/RpcWireLimits.java",
        "MAX_ENVELOPE_LENGTH_BYTES",
        4 * 1024 * 1024,
    ),
    ConstantContract(
        "android/app/src/main/java/app/droidmatch/m1/RpcWireLimits.java",
        "DEFAULT_TRANSFER_CHUNK_SIZE_BYTES",
        256 * 1024,
    ),
    ConstantContract(
        "android/app/src/main/java/app/droidmatch/m1/RpcWireLimits.java",
        "MAX_TRANSFER_CHUNK_SIZE_BYTES",
        1024 * 1024,
    ),
    ConstantContract(
        "android/app/src/main/java/app/droidmatch/m1/RpcWireLimits.java",
        "MAX_TRANSFER_IN_FLIGHT_CHUNKS",
        4,
    ),
    ConstantContract(
        "android/app/src/main/java/app/droidmatch/m1/RpcWireLimits.java",
        "MAX_TRANSFER_IN_FLIGHT_BYTES",
        2 * 1024 * 1024,
    ),
)

DOCUMENT_FACTS = {
    "docs/protocol.md": (
        "`envelope_length` must be greater than `0` and no larger than 4 MiB.",
        "M1 default transfer chunk size is 256 KiB.",
        "it must never exceed 1 MiB in M1.",
    ),
    "docs/protocol-runtime.md": (
        "Maximum `envelope_length` is 4 MiB.",
        "Default transfer chunk size | 256 KiB",
        "Maximum transfer chunk size | 1 MiB",
        "at most 4 chunks or 2 MiB of unacknowledged transfer data in flight",
    ),
}

CODE_FACTS = {
    "mac/Sources/DroidMatchCore/FrameCodec.swift": (
        "defaultMaxEnvelopeLength = RpcWireLimits.maximumEnvelopeLengthBytes",
    ),
    "mac/Sources/DroidMatchCore/FrameReader.swift": (
        "FrameCodec.validatedMaximumEnvelopeLength",
    ),
    "mac/Sources/DroidMatchCore/AsyncFramedTcpSession.swift": (
        "try codec.validateConfiguration()",
    ),
    "mac/Sources/DroidMatchCore/UploadWindow.swift": (
        "maxInFlightChunks = RpcWireLimits.maximumTransferInFlightChunks",
        "maxInFlightBytes = Int64(RpcWireLimits.maximumTransferInFlightBytes)",
    ),
    "mac/Sources/DroidMatchCore/AsyncRpcRoutingState.swift": (
        "maxDownloadInFlightChunks = RpcWireLimits.maximumTransferInFlightChunks",
        "maxDownloadInFlightBytes = RpcWireLimits.maximumTransferInFlightBytes",
        "maxTransferChunkBytes = RpcWireLimits.maximumTransferChunkSizeBytes",
    ),
    "mac/Sources/DroidMatchCore/AsyncUploadCoordinator.swift": (
        "preferredChunkSizeBytes: UInt32 = RpcWireLimits.defaultTransferChunkSizeBytes",
    ),
    "mac/Sources/DroidMatchCore/AsyncMixedTransferSmokeClient.swift": (
        "preferredChunkSizeBytes: UInt32 = RpcWireLimits.defaultTransferChunkSizeBytes",
    ),
    "mac/Sources/DroidMatchCore/AsyncRpcControlClient.swift": (
        "preferredChunkSizeBytes: UInt32 = RpcWireLimits.defaultTransferChunkSizeBytes",
    ),
    "mac/Sources/DroidMatchCore/AsyncDownloadCoordinator.swift": (
        "preferredChunkSizeBytes: UInt32 = RpcWireLimits.defaultTransferChunkSizeBytes",
    ),
    "mac/Sources/DroidMatchCore/DualDownloadSmokeClient.swift": (
        "preferredChunkSizeBytes: UInt32 = RpcWireLimits.defaultTransferChunkSizeBytes",
    ),
    "android/app/src/main/java/app/droidmatch/m1/FramedIo.java": (
        "MAX_ENVELOPE_LENGTH = RpcWireLimits.MAX_ENVELOPE_LENGTH_BYTES",
    ),
    "android/app/src/main/java/app/droidmatch/m1/RpcTransferFrames.java": (
        "RpcWireLimits.DEFAULT_TRANSFER_CHUNK_SIZE_BYTES",
        "RpcWireLimits.MAX_TRANSFER_CHUNK_SIZE_BYTES",
    ),
    "android/app/src/main/java/app/droidmatch/m1/RpcTransferStreams.java": (
        "MAX_TRANSFER_IN_FLIGHT_CHUNKS = RpcWireLimits.MAX_TRANSFER_IN_FLIGHT_CHUNKS",
        "RpcWireLimits.MAX_TRANSFER_IN_FLIGHT_BYTES",
    ),
}

MIRROR_ROOTS = (
    "mac/Sources/DroidMatchCore",
    "android/app/src/main/java/app/droidmatch/m1",
)
AUTHORIZED_NUMERIC_LIMIT_FILES = {
    "mac/Sources/DroidMatchCore/RpcWireLimits.swift",
    "android/app/src/main/java/app/droidmatch/m1/RpcWireLimits.java",
}
WIRE_BYTE_LIMITS = {
    256 * 1024,
    1024 * 1024,
    2 * 1024 * 1024,
    4 * 1024 * 1024,
}
NON_WIRE_NUMERIC_EXCEPTIONS = {
    # Independent JSON-record allocation cap, not a frame or transfer window.
    (
        "mac/Sources/DroidMatchCore/TransferResumeRecords.swift",
        "maximumRecordBytes",
        1024 * 1024,
    ),
}


def _read_bounded_regular_file(path: Path) -> str:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("not a regular file")
        if metadata.st_size > MAX_INPUT_BYTES:
            raise ValueError(f"file exceeds {MAX_INPUT_BYTES}-byte checker limit")
        chunks: list[bytes] = []
        remaining = MAX_INPUT_BYTES + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > MAX_INPUT_BYTES:
            raise ValueError(f"file exceeds {MAX_INPUT_BYTES}-byte checker limit")
        return data.decode("utf-8")
    finally:
        os.close(descriptor)


def _evaluate_integer(expression: str) -> int:
    if len(expression) > 96:
        raise ValueError("integer expression is too long")
    stripped = expression.strip()
    if re.fullmatch(r"[0-9\s()+\-*/<]+", stripped) is None:
        raise ValueError("unsupported integer expression")
    node = ast.parse(stripped, mode="eval")

    def evaluate(current: ast.AST) -> int:
        if isinstance(current, ast.Expression):
            return evaluate(current.body)
        if isinstance(current, ast.Constant) and type(current.value) is int:
            return current.value
        if isinstance(current, ast.UnaryOp) and isinstance(current.op, (ast.UAdd, ast.USub)):
            value = evaluate(current.operand)
            return value if isinstance(current.op, ast.UAdd) else -value
        if isinstance(current, ast.BinOp) and isinstance(
            current.op, (ast.Add, ast.Sub, ast.Mult, ast.FloorDiv, ast.LShift)
        ):
            left = evaluate(current.left)
            right = evaluate(current.right)
            if isinstance(current.op, ast.Add):
                return left + right
            if isinstance(current.op, ast.Sub):
                return left - right
            if isinstance(current.op, ast.Mult):
                return left * right
            if isinstance(current.op, ast.FloorDiv):
                return left // right
            if right < 0 or right > 63:
                raise ValueError("invalid shift count")
            return left << right
        raise ValueError("unsupported integer expression")

    value = evaluate(node)
    if value < -(1 << 63) or value > (1 << 63) - 1:
        raise ValueError("integer expression exceeds signed 64-bit bounds")
    return value


def _constant_value(text: str, name: str) -> int:
    pattern = re.compile(
        rf"\b{re.escape(name)}\b(?:\s*:\s*[A-Za-z0-9_.<>]+)?\s*=\s*(?P<value>[^;\n]+)"
    )
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise ValueError(f"expected exactly one assignment for {name}, found {len(matches)}")
    return _evaluate_integer(matches[0].group("value"))


def _normalized(text: str) -> str:
    return " ".join(text.split())


def _numeric_limit_mirrors(root: Path) -> list[str]:
    failures: list[str] = []
    assignment = re.compile(
        r"\b(?P<name>[A-Za-z_][A-Za-z0-9_]*)\b"
        r"(?:\s*:\s*[A-Za-z0-9_.<>]+)?\s*=\s*(?P<value>[^;\n]+)"
    )
    for relative_root in MIRROR_ROOTS:
        scan_root = root / relative_root
        if not scan_root.is_dir():
            failures.append(f"missing wire-limit source root: {relative_root}")
            continue
        for directory, directory_names, file_names in os.walk(scan_root, followlinks=False):
            directory_names[:] = [
                name
                for name in directory_names
                if not (Path(directory) / name).is_symlink()
            ]
            for file_name in file_names:
                if not file_name.endswith((".swift", ".java")):
                    continue
                path = Path(directory) / file_name
                relative_path = path.relative_to(root).as_posix()
                if relative_path in AUTHORIZED_NUMERIC_LIMIT_FILES:
                    continue
                try:
                    text = _read_bounded_regular_file(path)
                except (OSError, UnicodeError, ValueError) as error:
                    failures.append(f"cannot scan {relative_path}: {error}")
                    continue
                for match in assignment.finditer(text):
                    expression = match.group("value").strip().rstrip(",")
                    try:
                        value = _evaluate_integer(expression)
                    except (SyntaxError, ValueError, ZeroDivisionError):
                        continue
                    identity = (relative_path, match.group("name"), value)
                    if value in WIRE_BYTE_LIMITS and identity not in NON_WIRE_NUMERIC_EXCEPTIONS:
                        failures.append(
                            f"{relative_path} duplicates wire byte limit in "
                            f"{match.group('name')}={value}; use RpcWireLimits"
                        )
    return failures


def validate(root: Path) -> list[str]:
    failures: list[str] = []
    cache: dict[str, str] = {}
    failed_paths: set[str] = set()

    def source(relative_path: str) -> str | None:
        if relative_path in cache:
            return cache[relative_path]
        if relative_path in failed_paths:
            return None
        try:
            cache[relative_path] = _read_bounded_regular_file(root / relative_path)
        except (OSError, UnicodeError, ValueError) as error:
            failed_paths.add(relative_path)
            failures.append(f"cannot read {relative_path}: {error}")
            return None
        return cache[relative_path]

    for contract in CONSTANTS:
        text = source(contract.path)
        if text is None:
            continue
        try:
            actual = _constant_value(text, contract.name)
        except (SyntaxError, ValueError, ZeroDivisionError) as error:
            failures.append(f"{contract.path} {contract.name}: {error}")
            continue
        if actual != contract.expected:
            failures.append(
                f"{contract.path} {contract.name}={actual}, expected {contract.expected}"
            )

    for relative_path, required_facts in CODE_FACTS.items():
        text = source(relative_path)
        if text is None:
            continue
        normalized = _normalized(text)
        for fact in required_facts:
            if _normalized(fact) not in normalized:
                failures.append(f"{relative_path} is missing wire-limit use: {fact}")

    for relative_path, required_facts in DOCUMENT_FACTS.items():
        text = source(relative_path)
        if text is None:
            continue
        normalized = _normalized(text)
        for fact in required_facts:
            if _normalized(fact) not in normalized:
                failures.append(f"{relative_path} is missing wire-limit fact: {fact}")
    failures.extend(_numeric_limit_mirrors(root))
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root (defaults to the checker parent)",
    )
    args = parser.parse_args()
    failures = validate(args.root.resolve())
    if failures:
        for failure in failures:
            print(f"wire-limit check failed: {failure}", file=sys.stderr)
        return 1
    print("Wire-limit contract check passed.")
    print("中文：双端线协议限额一致性检查通过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
