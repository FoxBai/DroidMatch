#!/usr/bin/env python3
"""Offline regressions for the bounded command runner."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import time


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "tools/run-command-with-timeout.py"


completed = subprocess.run(
    [sys.executable, str(RUNNER), "2", "sh", "-c", "printf bounded; exit 7"],
    check=False,
    capture_output=True,
    text=True,
)
assert completed.returncode == 7
assert completed.stdout == "bounded"

invalid = subprocess.run(
    [sys.executable, str(RUNNER), "zero", "true"],
    check=False,
    capture_output=True,
    text=True,
)
assert invalid.returncode == 2
assert "usage:" in invalid.stderr

with TemporaryDirectory() as temporary_directory:
    child_pid_path = Path(temporary_directory) / "child.pid"
    timed_out = subprocess.run(
        [
            sys.executable,
            str(RUNNER),
            "0.05",
            "sh",
            "-c",
            f"sleep 60 & echo $! >'{child_pid_path}'; wait",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert timed_out.returncode == 124
    assert "command timed out" in timed_out.stderr
    child_pid = int(child_pid_path.read_text(encoding="utf-8"))
    time.sleep(0.05)
    try:
        os.kill(child_pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError("timed-out child process remained alive")

print("Bounded command runner regressions passed.")
print("中文：有界命令 runner 离线回归通过。")
