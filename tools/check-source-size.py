#!/usr/bin/env python3
"""Keep handwritten production and test sources below the reviewability ceiling."""

from __future__ import annotations

from pathlib import Path
import re
import sys


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MAX_LINES = 800
SOURCE_ROOTS = (
    REPO_ROOT / "mac" / "Sources",
    REPO_ROOT / "mac" / "Tests",
    REPO_ROOT / "android" / "app" / "src" / "main" / "java",
    REPO_ROOT / "android" / "app" / "src" / "test" / "java",
    REPO_ROOT / "android" / "app" / "src" / "androidTest" / "java",
)
SOURCE_SUFFIXES = {".swift", ".java", ".kt"}
TECHNICAL_DEBT = REPO_ROOT / "docs" / "technical-debt.md"
MAXIMUM_MARKER = re.compile(
    r"<!-- source-size-max "
    r"production=(?P<production_path>[^:]+):(?P<production_lines>\d+) "
    r"test=(?P<test_path>[^:]+):(?P<test_lines>\d+) -->"
)

# These are debt ceilings, not preferred sizes. A listed file may shrink but
# must not grow; remove its exception once it falls below DEFAULT_MAX_LINES.
LEGACY_CEILINGS = {}


def handwritten_source_files() -> list[Path]:
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


def is_test_source(relative: Path) -> bool:
    parts = relative.parts
    return (
        parts[:2] == ("mac", "Tests")
        or parts[:5] == ("android", "app", "src", "test", "java")
        or parts[:5] == ("android", "app", "src", "androidTest", "java")
    )


def maximum_marker(text: str) -> tuple[str, int, str, int] | None:
    match = MAXIMUM_MARKER.search(text)
    if match is None:
        return None
    return (
        match.group("production_path"),
        int(match.group("production_lines")),
        match.group("test_path"),
        int(match.group("test_lines")),
    )


def main() -> int:
    failures: list[str] = []
    exceptions_seen: set[str] = set()
    production_sizes: list[tuple[int, str]] = []
    test_sizes: list[tuple[int, str]] = []

    for path in handwritten_source_files():
        relative = path.relative_to(REPO_ROOT).as_posix()
        count = line_count(path)
        sizes = test_sizes if is_test_source(path.relative_to(REPO_ROOT)) else production_sizes
        sizes.append((count, relative))
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

    if not production_sizes or not test_sizes:
        failures.append("production and test source sets must both be non-empty")
    else:
        production_max = max(production_sizes, key=lambda item: (item[0], item[1]))
        test_max = max(test_sizes, key=lambda item: (item[0], item[1]))
        documented = maximum_marker(TECHNICAL_DEBT.read_text(encoding="utf-8"))
        actual = (production_max[1], production_max[0], test_max[1], test_max[0])
        if documented is None:
            failures.append("docs/technical-debt.md is missing the source-size-max marker")
        elif documented != actual:
            failures.append(
                "docs/technical-debt.md source-size-max marker is stale: "
                f"expected production={actual[0]}:{actual[1]} "
                f"test={actual[2]}:{actual[3]}"
            )

    if failures:
        print("Source-size budget failed:", file=sys.stderr)
        print("中文：源码规模门禁失败：", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    legacy_count = len(LEGACY_CEILINGS)
    print(
        "Largest handwritten sources: "
        f"production={production_max[1]}:{production_max[0]} "
        f"test={test_max[1]}:{test_max[0]}"
    )
    print(
        "中文：最大手写源码："
        f"生产={production_max[1]}:{production_max[0]} "
        f"测试={test_max[1]}:{test_max[0]}"
    )
    if legacy_count == 0:
        print(
            "Source-size budget passed: "
            f"all handwritten production and test files <= {DEFAULT_MAX_LINES} lines; "
            "no legacy monolith exceptions remain."
        )
        print(
            "中文：源码规模门禁通过：全部手写生产与测试文件不超过 "
            f"{DEFAULT_MAX_LINES} 行，已无存量巨石例外。"
        )
    else:
        legacy_noun = "legacy monolith" if legacy_count == 1 else "legacy monoliths"
        print(
            "Source-size budget passed: "
            f"new handwritten production and test files <= {DEFAULT_MAX_LINES} lines; "
            f"{legacy_count} {legacy_noun} did not grow."
        )
        print(
            "中文：源码规模门禁通过：新增手写生产与测试文件不超过 "
            f"{DEFAULT_MAX_LINES} 行，{legacy_count} 个存量巨石文件未增长。"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
