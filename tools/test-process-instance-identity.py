#!/usr/bin/env python3

"""Regression tests for boot-scoped publication-owner identity."""

from __future__ import annotations

import os
import pathlib
import subprocess
import sys


TOOL = pathlib.Path(__file__).with_name("process_instance_identity.py")


def run(*arguments: str, expected: int) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [sys.executable, str(TOOL), *arguments],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == expected, (arguments, result)
    return result


current_pid = str(os.getpid())
captured = run("capture", current_pid, expected=0).stdout.strip()
assert captured and " " not in captured and "\n" not in captured
run("matches", current_pid, captured, expected=0)

child = subprocess.Popen(
    [sys.executable, "-c", "import time; time.sleep(30)"],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
try:
    other = run("capture", str(child.pid), expected=0).stdout.strip()
    assert other != captured
    run("matches", current_pid, other, expected=1)
finally:
    child.terminate()
    child.wait(timeout=5)

run("matches", str(child.pid), other, expected=1)
run("capture", "0", expected=2)
run("matches", current_pid, "invalid", expected=2)

print("Process-instance identity tests passed.")
print("中文：进程实例身份测试通过。")
