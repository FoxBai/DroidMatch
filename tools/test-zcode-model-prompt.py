#!/usr/bin/env python3
"""Offline contract checks for the optional ZCode model wrapper."""

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "tools" / "zcode-model-prompt.mjs"


help_result = subprocess.run(
    [str(WRAPPER), "--help"],
    cwd=ROOT,
    check=True,
    capture_output=True,
    text=True,
)
assert "default: 4096" in help_result.stdout
assert "--require-suffix" in help_result.stdout

# Argument validation must fail before starting ZCode or reading workspace state.
invalid_result = subprocess.run(
    [str(WRAPPER), "--max-output-tokens", "0", "--list-models"],
    cwd=ROOT,
    check=False,
    capture_output=True,
    text=True,
)
assert invalid_result.returncode == 1
assert "must be a positive integer" in invalid_result.stderr

source = WRAPPER.read_text(encoding="utf-8")
assert source.count("retry with --max-output-tokens 4096 or higher") == 2

print("ZCode model wrapper contract tests passed.")
print("中文：ZCode 模型 wrapper 离线契约测试通过。")
