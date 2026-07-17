#!/usr/bin/env python3
"""Fail closed when the product Help menu regresses to an empty Help Book."""

from __future__ import annotations

from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]

REQUIRED_SNIPPETS = {
    "mac/Sources/DroidMatchApp/DroidMatchDesktopApp.swift": (
        "ProductHelpCommands()",
        'Window(AppStrings.helpWindowTitle, id: ProductHelpWindow.id)',
    ),
    "mac/Sources/DroidMatchApp/ProductHelpView.swift": (
        "CommandGroup(replacing: .help)",
        "openWindow(id: ProductHelpWindow.id)",
        "AppStrings.helpKeychainPrivacy",
        "AppStrings.helpKeychainConnectionPrompt",
        "ProductAccessibilityIdentifiers.helpWindow",
    ),
    "mac/Sources/DroidMatchApp/AppStrings.swift": (
        'static let helpMenuTitle = value("DroidMatch Help")',
        "opening Help never reads credentials or connects a device.",
        "Only an explicit device connection reads a saved pairing key.",
    ),
}

FORBIDDEN_HELP_VIEW_SNIPPETS = (
    "http://",
    "https://",
    "NSWorkspace.shared.open",
    "KeychainPairingCredentialStore",
    "DeviceSessionModel",
)


class ProductHelpContractError(Exception):
    pass


def read_source(root: Path, relative_path: str) -> str:
    try:
        return (root / relative_path).read_text(encoding="utf-8")
    except OSError as error:
        raise ProductHelpContractError(f"{relative_path} is unavailable") from error


def validate(root: Path) -> None:
    sources = {
        relative_path: read_source(root, relative_path)
        for relative_path in REQUIRED_SNIPPETS
    }
    for relative_path, snippets in REQUIRED_SNIPPETS.items():
        missing = [snippet for snippet in snippets if snippet not in sources[relative_path]]
        if missing:
            raise ProductHelpContractError(
                f"{relative_path} is missing the local Help contract: {missing}"
            )

    help_source = sources["mac/Sources/DroidMatchApp/ProductHelpView.swift"]
    forbidden = [
        snippet for snippet in FORBIDDEN_HELP_VIEW_SNIPPETS if snippet in help_source
    ]
    if forbidden:
        raise ProductHelpContractError(
            "ProductHelpView must remain local and credential-free: "
            f"{forbidden}"
        )


def main() -> int:
    try:
        validate(ROOT)
    except ProductHelpContractError as error:
        print(f"Product Help contract failed: {error}", file=sys.stderr)
        print(f"中文：产品帮助契约失败：{error}", file=sys.stderr)
        return 1

    print("Product Help contract passed: local Help replaces the empty Help Book action.")
    print("中文：产品帮助契约通过：本地帮助已替换无内容的系统帮助入口。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
