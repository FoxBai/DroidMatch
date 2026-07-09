#!/usr/bin/env python3
"""Check local Markdown links used by DroidMatch documentation.

English: this gate validates that relative Markdown link and image targets
exist, while leaving external URLs and heading anchors to their source sites.
中文：这个 gate 校验 Markdown 里的本地相对链接和图片目标是否存在；外部 URL
和标题锚点由对应站点或渲染器负责。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse


REPO_ROOT = Path(__file__).resolve().parents[1]
SKIPPED_DIRS = {
    ".git",
    ".gradle",
    ".swiftpm",
    ".build",
    "build",
}
INLINE_LINK_RE = re.compile(r"!?\[[^\]\n]*\]\(([^)\n]+)\)")
REFERENCE_LINK_RE = re.compile(r"^\s*\[[^\]]+\]:\s+(\S+)", re.MULTILINE)


def is_within_skipped_dir(path: Path) -> bool:
    relative_parts = path.relative_to(REPO_ROOT).parts
    return any(part in SKIPPED_DIRS for part in relative_parts)


def markdown_files() -> list[Path]:
    return sorted(
        path
        for path in REPO_ROOT.rglob("*.md")
        if path.is_file() and not is_within_skipped_dir(path)
    )


def line_number_for_offset(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def normalize_target(raw_target: str) -> str | None:
    target = raw_target.strip()
    if not target:
        return None

    if target.startswith("<"):
        closing = target.find(">")
        if closing == -1:
            return None
        target = target[1:closing]
    else:
        target = target.split()[0]

    target = unquote(target)
    parsed = urlparse(target)
    if parsed.scheme or target.startswith("#"):
        return None

    without_anchor = target.split("#", 1)[0]
    without_query = without_anchor.split("?", 1)[0]
    if not without_query:
        return None
    return without_query


def resolve_target(markdown_file: Path, target: str) -> Path:
    if target.startswith("/"):
        return (REPO_ROOT / target.lstrip("/")).resolve()
    return (markdown_file.parent / target).resolve()


def iter_link_targets(text: str) -> list[tuple[int, str]]:
    matches: list[tuple[int, str]] = []
    for regex in (INLINE_LINK_RE, REFERENCE_LINK_RE):
        for match in regex.finditer(text):
            normalized = normalize_target(match.group(1))
            if normalized is not None:
                matches.append((match.start(1), normalized))
    return matches


def main() -> int:
    failures: list[str] = []
    checked_targets = 0

    for markdown_file in markdown_files():
        text = markdown_file.read_text(encoding="utf-8")
        for offset, target in iter_link_targets(text):
            checked_targets += 1
            resolved = resolve_target(markdown_file, target)
            if not resolved.exists():
                relative_markdown = markdown_file.relative_to(REPO_ROOT)
                failures.append(
                    f"{relative_markdown}:{line_number_for_offset(text, offset)} "
                    f"missing local Markdown target: {target}"
                )

    if failures:
        print("Markdown link check failed.", file=sys.stderr)
        print("中文：Markdown 本地链接检查失败。", file=sys.stderr)
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1

    print(
        f"Markdown link check passed: {checked_targets} local targets in "
        f"{len(markdown_files())} Markdown files."
    )
    print(
        f"中文：Markdown 链接检查通过：{len(markdown_files())} 个 Markdown 文件中 "
        f"{checked_targets} 个本地目标存在。"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
