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
TOOL_ROOT = REPO_ROOT / "tools"
TOOL_SUFFIXES = {".sh", ".py"}
TECHNICAL_DEBT = REPO_ROOT / "docs" / "technical-debt.md"
MAXIMUM_MARKER = re.compile(
    r"<!-- source-size-max "
    r"production=(?P<production_path>[^:]+):(?P<production_lines>\d+) "
    r"test=(?P<test_path>[^:]+):(?P<test_lines>\d+) -->"
)
TOOL_MAXIMUM_MARKER = re.compile(
    r"<!-- tool-size-max path=(?P<path>[^:]+):(?P<lines>\d+) -->"
)
CURRENT_MAXIMUM_CLAIM_PATTERNS = {
    "English": re.compile(
        r"the largest production file is now the "
        r"(?P<production_lines>\d+)-line "
        r"(?P<production_platform>Mac|Android) `(?P<production_name>[^`]+)` "
        r"and the largest test file is now the "
        r"(?P<test_lines>\d+)-line "
        r"(?P<test_platform>Mac|Android) `(?P<test_name>[^`]+)`"
    ),
    "Chinese": re.compile(
        r"最大生产文件现为 (?P<production_lines>\d+) 行的 "
        r"(?P<production_platform>Mac|Android) `(?P<production_name>[^`]+)`，"
        r"最大测试文件现为 (?P<test_lines>\d+) 行的 "
        r"(?P<test_platform>Mac|Android) `(?P<test_name>[^`]+)`"
    ),
}

# These are debt ceilings, not preferred sizes. A listed file may shrink but
# must not grow; remove its exception once it falls below DEFAULT_MAX_LINES.
LEGACY_CEILINGS = {}
TOOL_LEGACY_CEILINGS = {}


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


def handwritten_tool_files() -> list[Path]:
    if not TOOL_ROOT.exists():
        return []
    return sorted(
        path
        for path in TOOL_ROOT.rglob("*")
        if path.is_file()
        and path.suffix in TOOL_SUFFIXES
        and "__pycache__" not in path.parts
    )


def line_count(path: Path) -> int:
    with path.open("r", encoding="utf-8") as source:
        return sum(1 for _ in source)


def tool_budget_failures(
    sizes: list[tuple[int, str]],
    legacy_ceilings: dict[str, int],
) -> list[str]:
    failures: list[str] = []
    exceptions_seen: set[str] = set()
    for count, relative in sizes:
        ceiling = legacy_ceilings.get(relative, DEFAULT_MAX_LINES)
        if relative in legacy_ceilings:
            exceptions_seen.add(relative)
            if count <= DEFAULT_MAX_LINES:
                failures.append(
                    f"{relative}: now {count} lines; remove its stale tool exception"
                )
            elif count < ceiling:
                failures.append(
                    f"{relative}: now {count} lines; lower its tool ceiling from {ceiling}"
                )
        if count > ceiling:
            failures.append(f"{relative}: {count} lines exceeds tool ceiling {ceiling}")

    for relative in sorted(set(legacy_ceilings) - exceptions_seen):
        failures.append(f"{relative}: tool exception points to a missing script")
    return failures


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


def tool_maximum_marker(text: str) -> tuple[str, int] | None:
    match = TOOL_MAXIMUM_MARKER.search(text)
    if match is None:
        return None
    return match.group("path"), int(match.group("lines"))


def source_platform(relative_path: str) -> str:
    if relative_path.startswith("mac/"):
        return "Mac"
    if relative_path.startswith("android/"):
        return "Android"
    raise ValueError(f"unsupported source platform: {relative_path}")


def current_maximum_claim_failures(
    text: str,
    actual: tuple[str, int, str, int],
) -> list[str]:
    """Require one matching English and Chinese current-maximum claim."""
    production_path, production_lines, test_path, test_lines = actual
    expected = (
        production_lines,
        source_platform(production_path),
        Path(production_path).name,
        test_lines,
        source_platform(test_path),
        Path(test_path).name,
    )
    failures: list[str] = []
    for language, pattern in CURRENT_MAXIMUM_CLAIM_PATTERNS.items():
        matches = list(pattern.finditer(text))
        if len(matches) != 1:
            failures.append(
                "docs/technical-debt.md must contain exactly one canonical "
                f"{language} current source-maximum claim (found {len(matches)})"
            )
            continue
        match = matches[0]
        documented = (
            int(match.group("production_lines")),
            match.group("production_platform"),
            match.group("production_name"),
            int(match.group("test_lines")),
            match.group("test_platform"),
            match.group("test_name"),
        )
        if documented != expected:
            failures.append(
                f"docs/technical-debt.md {language} current source-maximum "
                f"claim is stale: expected {expected}, found {documented}"
            )
    return failures


def main() -> int:
    failures: list[str] = []
    exceptions_seen: set[str] = set()
    production_sizes: list[tuple[int, str]] = []
    test_sizes: list[tuple[int, str]] = []
    tool_sizes: list[tuple[int, str]] = []

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

    for path in handwritten_tool_files():
        relative = path.relative_to(REPO_ROOT).as_posix()
        count = line_count(path)
        tool_sizes.append((count, relative))
    failures.extend(tool_budget_failures(tool_sizes, TOOL_LEGACY_CEILINGS))

    if not production_sizes or not test_sizes:
        failures.append("production and test source sets must both be non-empty")
    else:
        production_max = max(production_sizes, key=lambda item: (item[0], item[1]))
        test_max = max(test_sizes, key=lambda item: (item[0], item[1]))
        technical_debt = TECHNICAL_DEBT.read_text(encoding="utf-8")
        documented = maximum_marker(technical_debt)
        actual = (production_max[1], production_max[0], test_max[1], test_max[0])
        if documented is None:
            failures.append("docs/technical-debt.md is missing the source-size-max marker")
        elif documented != actual:
            failures.append(
                "docs/technical-debt.md source-size-max marker is stale: "
                f"expected production={actual[0]}:{actual[1]} "
                f"test={actual[2]}:{actual[3]}"
            )
        failures.extend(current_maximum_claim_failures(technical_debt, actual))

    if not tool_sizes:
        failures.append("handwritten tool source set must be non-empty")
    else:
        tool_max = max(tool_sizes, key=lambda item: (item[0], item[1]))
        technical_debt = TECHNICAL_DEBT.read_text(encoding="utf-8")
        documented_tool_max = tool_maximum_marker(technical_debt)
        actual_tool_max = (tool_max[1], tool_max[0])
        if documented_tool_max is None:
            failures.append("docs/technical-debt.md is missing the tool-size-max marker")
        elif documented_tool_max != actual_tool_max:
            failures.append(
                "docs/technical-debt.md tool-size-max marker is stale: "
                f"expected path={actual_tool_max[0]}:{actual_tool_max[1]}"
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
    print(f"Largest handwritten tool: {tool_max[1]}:{tool_max[0]}")
    print(f"中文：最大手写工具脚本：{tool_max[1]}:{tool_max[0]}")
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
    tool_legacy_count = len(TOOL_LEGACY_CEILINGS)
    if tool_legacy_count == 0:
        print(
            "Tool-size budget passed: all handwritten shell/Python files <= "
            f"{DEFAULT_MAX_LINES} lines; no tool exceptions remain."
        )
        print(
            "中文：工具规模门禁通过：全部手写 shell/Python 文件不超过 "
            f"{DEFAULT_MAX_LINES} 行，已无工具例外。"
        )
    else:
        print(
            "Tool-size budget passed: new handwritten shell/Python files <= "
            f"{DEFAULT_MAX_LINES} lines; {tool_legacy_count} exact legacy tool ceiling "
            "did not grow."
        )
        print(
            "中文：工具规模门禁通过：新增手写 shell/Python 文件不超过 "
            f"{DEFAULT_MAX_LINES} 行，{tool_legacy_count} 个精确存量工具上限未增长。"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
