#!/usr/bin/env python3
"""Verify bilingual resource parity and printf-style formatting contracts."""

from __future__ import annotations

from collections import Counter
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
MAC_ENTRY = re.compile(
    r'^\s*"(?P<key>(?:\\.|[^"\\])*)"\s*=\s*"(?P<value>(?:\\.|[^"\\])*)"\s*;\s*$',
    re.MULTILINE,
)
FORMAT_TOKEN = re.compile(
    r"%(?!%)(?:\d+\$)?[-+0 #']*\d*(?:\.\d+)?(?P<kind>[A-Za-z@])"
)


class LocalizationError(Exception):
    pass


def formatting_signature(value: str) -> Counter[str]:
    # Argument positions may legitimately change in a translation. The value
    # type/count may not: passing an object to %d is a runtime formatting bug.
    return Counter(match.group("kind") for match in FORMAT_TOKEN.finditer(value))


def unique_entries(entries: list[tuple[str, str]], label: str) -> dict[str, str]:
    result: dict[str, str] = {}
    duplicates: list[str] = []
    for key, value in entries:
        if key in result:
            duplicates.append(key)
        result[key] = value
    if duplicates:
        raise LocalizationError(f"{label} has duplicate keys: {sorted(set(duplicates))}")
    empty = sorted(key for key, value in result.items() if not value.strip())
    if empty:
        raise LocalizationError(f"{label} has empty translations: {empty}")
    return result


def read_mac(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    entries = [(match.group("key"), match.group("value")) for match in MAC_ENTRY.finditer(text)]
    if not entries:
        raise LocalizationError(f"{path.relative_to(ROOT)} has no string entries")
    return unique_entries(entries, path.relative_to(ROOT).as_posix())


def read_android(path: Path) -> dict[str, str]:
    root = ET.parse(path).getroot()
    entries: list[tuple[str, str]] = []
    for element in root.findall("string"):
        name = element.get("name")
        if not name:
            raise LocalizationError(f"{path.relative_to(ROOT)} has an unnamed string")
        value = "".join(element.itertext())
        entries.append((name, value))
    return unique_entries(entries, path.relative_to(ROOT).as_posix())


def compare(label: str, base: dict[str, str], translation: dict[str, str]) -> None:
    missing = sorted(set(base) - set(translation))
    extra = sorted(set(translation) - set(base))
    if missing or extra:
        raise LocalizationError(
            f"{label} key mismatch; missing={missing or 'none'} extra={extra or 'none'}"
        )
    mismatched = [
        key
        for key in sorted(base)
        if formatting_signature(base[key]) != formatting_signature(translation[key])
    ]
    if mismatched:
        details = [
            f"{key}: {dict(formatting_signature(base[key]))} != "
            f"{dict(formatting_signature(translation[key]))}"
            for key in mismatched
        ]
        raise LocalizationError(f"{label} format mismatch: {'; '.join(details)}")


def main() -> int:
    try:
        mac_en = read_mac(
            ROOT / "mac/Sources/DroidMatchApp/Resources/en.lproj/Localizable.strings"
        )
        mac_zh = read_mac(
            ROOT / "mac/Sources/DroidMatchApp/Resources/zh-Hans.lproj/Localizable.strings"
        )
        android_en = read_android(ROOT / "android/app/src/main/res/values/strings.xml")
        android_zh = read_android(
            ROOT / "android/app/src/main/res/values-zh-rCN/strings.xml"
        )
        compare("Mac en/zh-Hans", mac_en, mac_zh)
        compare("Android en/zh-rCN", android_en, android_zh)
    except (LocalizationError, ET.ParseError, OSError) as error:
        print(f"Localization contract failed: {error}", file=sys.stderr)
        print(f"中文：本地化资源契约失败：{error}", file=sys.stderr)
        return 1

    print(
        "Localization contract passed: "
        f"Mac {len(mac_en)} keys; Android {len(android_en)} keys."
    )
    print(
        "中文：本地化资源契约通过："
        f"Mac {len(mac_en)} 个键；Android {len(android_en)} 个键。"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
