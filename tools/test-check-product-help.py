#!/usr/bin/env python3
"""Offline regressions for the product Help source contract."""

from __future__ import annotations

import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools/check-product-help.py"
SPEC = importlib.util.spec_from_file_location("check_product_help", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load product Help checker")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def copy_contract_sources(destination: Path) -> None:
    for relative_path in MODULE.REQUIRED_SNIPPETS:
        source = ROOT / relative_path
        target = destination / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source.read_bytes())


def expect_failure(root: Path, expected_fragment: str) -> None:
    try:
        MODULE.validate(root)
    except MODULE.ProductHelpContractError as error:
        if expected_fragment not in str(error):
            raise AssertionError(f"unexpected failure: {error}") from error
        return
    raise AssertionError("product Help checker unexpectedly passed")


with TemporaryDirectory() as temporary_directory:
    fixture_root = Path(temporary_directory)
    copy_contract_sources(fixture_root)
    MODULE.validate(fixture_root)

    desktop_path = fixture_root / "mac/Sources/DroidMatchApp/DroidMatchDesktopApp.swift"
    desktop_source = desktop_path.read_text(encoding="utf-8")
    desktop_path.write_text(
        desktop_source.replace("ProductHelpCommands()", "EmptyViewCommands()"),
        encoding="utf-8",
    )
    expect_failure(fixture_root, "local Help contract")

    desktop_path.write_text(desktop_source, encoding="utf-8")
    help_path = fixture_root / "mac/Sources/DroidMatchApp/ProductHelpView.swift"
    help_path.write_text(
        help_path.read_text(encoding="utf-8")
        + '\nlet externalHelp = URL(string: "https://example.invalid")\n',
        encoding="utf-8",
    )
    expect_failure(fixture_root, "credential-free")

print("Product Help checker regressions passed.")
print("中文：产品帮助检查器离线回归通过。")
