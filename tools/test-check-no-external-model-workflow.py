#!/usr/bin/env python3
"""Unit-test the external model workflow guard without changing the checkout."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile


MODULE_PATH = Path(__file__).with_name("check-no-external-model-workflow.py")
SPEC = importlib.util.spec_from_file_location("external_model_guard", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def assert_detected(text: str) -> None:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "candidate.txt"
        path.write_text(text, encoding="utf-8")
        references = MODULE.find_references([path])
        assert references == [(path, 1)], references


assert_detected("z" + "code")
assert_detected("Mi" + "Mo" + " 2.5 Pro")
assert_detected("Deep" + "Seek" + " V4")
assert_detected("GLM" + "5.2")
assert_detected("GLM" + "-5.2")

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "safe.txt"
    path.write_text(
        "third-party runtime notices remain allowed; no provider workflow here.\n",
        encoding="utf-8",
    )
    assert MODULE.find_references([path]) == []

print("External model workflow guard tests passed.")
print("中文：外部模型工作流防回归测试通过。")
