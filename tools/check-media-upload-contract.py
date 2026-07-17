#!/usr/bin/env python3
"""Keep the Swift and Android MediaStore filename allowlists identical."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SWIFT_SOURCE = ROOT / "mac/Sources/DroidMatchCore/ProductUploadDestination.swift"
JAVA_SOURCE = ROOT / "android/app/src/main/java/app/droidmatch/m1/ProviderMimeTypes.java"


def swift_extensions(source: str, name: str) -> set[str]:
    match = re.search(
        rf"private static let {re.escape(name)}: Set<String> = \[(.*?)\n\s*\]",
        source,
        re.DOTALL,
    )
    if match is None:
        raise ValueError(f"Swift {name} allowlist was not found")
    values = re.findall(r'"([a-z0-9]+)"', match.group(1))
    if len(values) != len(set(values)) or not values:
        raise ValueError(f"Swift {name} allowlist is empty or duplicated")
    return set(values)


def java_extensions(source: str) -> tuple[set[str], set[str]]:
    switch = source.partition("switch (extension) {")[2].partition("default: return null;")[0]
    if not switch:
        raise ValueError("Android knownMediaType switch was not found")
    result = {"image": set(), "video": set()}
    pending: list[str] = []
    for line in switch.splitlines():
        pending.extend(re.findall(r'case "([a-z0-9]+)":', line))
        mime = re.search(r'return "(image|video)/[^";]+";', line)
        if mime is None:
            continue
        category = mime.group(1)
        if not pending or result[category].intersection(pending):
            raise ValueError("Android media extension cases are empty or duplicated")
        result[category].update(pending)
        pending = []
    if pending or not result["image"] or not result["video"]:
        raise ValueError("Android media extension switch could not be fully parsed")
    return result["image"], result["video"]


def validate_contract(swift: str, java: str) -> None:
    swift_images = swift_extensions(swift, "imageFileExtensions")
    swift_videos = swift_extensions(swift, "videoFileExtensions")
    java_images, java_videos = java_extensions(java)
    if swift_images != java_images or swift_videos != java_videos:
        raise ValueError(
            "Swift/Android media upload extension allowlists differ: "
            f"images={sorted(swift_images ^ java_images)} "
            f"videos={sorted(swift_videos ^ java_videos)}"
        )
    if "ts" in swift_images | swift_videos:
        raise ValueError("ambiguous .ts must remain outside the MediaStore allowlist")


def main() -> int:
    try:
        validate_contract(
            SWIFT_SOURCE.read_text(encoding="utf-8"),
            JAVA_SOURCE.read_text(encoding="utf-8"),
        )
    except (OSError, ValueError) as error:
        print(f"Media upload contract check failed: {error}", file=sys.stderr)
        print(f"中文：媒体上传契约检查失败：{error}", file=sys.stderr)
        return 1
    print("Media upload extension contract check passed.")
    print("中文：媒体上传扩展名契约检查通过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
