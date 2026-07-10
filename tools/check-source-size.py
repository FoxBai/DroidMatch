#!/usr/bin/env python3
"""Prevent existing source monoliths from growing while they are decomposed."""

from __future__ import annotations

from pathlib import Path
import sys


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MAX_LINES = 1_000
SOURCE_ROOTS = (
    REPO_ROOT / "mac" / "Sources",
    REPO_ROOT / "android" / "app" / "src" / "main" / "java",
)
SOURCE_SUFFIXES = {".swift", ".java", ".kt"}

# These are debt ceilings, not preferred sizes. A listed file may shrink but
# must not grow; remove its exception once it falls below DEFAULT_MAX_LINES.
LEGACY_CEILINGS = {
    "android/app/src/main/java/app/droidmatch/m1/DmFileProvider.java": 2_568,
    "android/app/src/main/java/app/droidmatch/m1/RpcDispatcher.java": 2_293,
    "mac/Sources/DroidMatchHarness/main.swift": 1_457,
    "mac/Sources/DroidMatchCore/AsyncRpcMultiplexer.swift": 1_218,
}


def source_files() -> list[Path]:
    files: list[Path] = []
    for root in SOURCE_ROOTS:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix not in SOURCE_SUFFIXES:
                continue
            relative = path.relative_to(REPO_ROOT)
            if "Generated" in relative.parts or "build" in relative.parts:
                continue
            files.append(path)
    return sorted(files)


def line_count(path: Path) -> int:
    with path.open("r", encoding="utf-8") as source:
        return sum(1 for _ in source)


def main() -> int:
    failures: list[str] = []
    exceptions_seen: set[str] = set()

    for path in source_files():
        relative = path.relative_to(REPO_ROOT).as_posix()
        count = line_count(path)
        ceiling = LEGACY_CEILINGS.get(relative, DEFAULT_MAX_LINES)
        if relative in LEGACY_CEILINGS:
            exceptions_seen.add(relative)
            if count <= DEFAULT_MAX_LINES:
                failures.append(
                    f"{relative}: now {count} lines; remove its stale legacy exception"
                )
        if count > ceiling:
            failures.append(f"{relative}: {count} lines exceeds ceiling {ceiling}")

    missing_exceptions = sorted(set(LEGACY_CEILINGS) - exceptions_seen)
    for relative in missing_exceptions:
        failures.append(f"{relative}: legacy exception points to a missing source file")

    if failures:
        print("Source-size budget failed:", file=sys.stderr)
        print("中文：源码规模门禁失败：", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(
        "Source-size budget passed: "
        f"new production files <= {DEFAULT_MAX_LINES} lines; "
        f"{len(LEGACY_CEILINGS)} legacy monoliths did not grow."
    )
    print(
        "中文：源码规模门禁通过：新增生产文件不超过 "
        f"{DEFAULT_MAX_LINES} 行，{len(LEGACY_CEILINGS)} 个存量巨石文件未增长。"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
