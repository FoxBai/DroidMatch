#!/usr/bin/env python3
"""Behavior regressions for the running-App publication guard."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools/check-mac-app-not-running.py"
SPEC = importlib.util.spec_from_file_location("check_mac_app_not_running", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load running-App checker")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


with tempfile.TemporaryDirectory() as temporary_directory:
    root = Path(temporary_directory)
    app = root / "Folder with space" / "DroidMatch.app"
    executable = app / MODULE.APP_EXECUTABLE
    executable.parent.mkdir(parents=True)

    assert not MODULE.is_app_running(app, ["/usr/bin/unrelated"])
    assert MODULE.is_app_running(app, [str(executable)])
    assert MODULE.is_app_running(app, [str(executable) + MODULE.DELETED_SUFFIX])

    shutil.copy("/bin/sleep", executable)
    replacement_app = root / "Replacement DroidMatch.app"
    replacement_executable = replacement_app / MODULE.APP_EXECUTABLE
    replacement_executable.parent.mkdir(parents=True)
    shutil.copy("/bin/sleep", replacement_executable)
    if sys.platform.startswith("linux"):
        launch_path = str(Path(app.name) / MODULE.APP_EXECUTABLE)
        process = subprocess.Popen([launch_path, "30"], cwd=app.parent)
    else:
        process = subprocess.Popen([str(executable), "30"])
    try:
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if MODULE.is_app_running(app, MODULE.process_paths()):
                break
            time.sleep(0.02)
        else:
            raise AssertionError("live DroidMatch executable was not detected")
        old_app = root / "Renamed DroidMatch.app"
        app.rename(old_app)
        assert MODULE.is_app_running(app, MODULE.process_paths())
        replacement_app.rename(app)
        assert MODULE.is_app_running(app, MODULE.process_paths())
        (old_app / MODULE.APP_EXECUTABLE).unlink()
        assert MODULE.is_app_running(app, MODULE.process_paths())
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)

    assert not MODULE.is_app_running(app, MODULE.process_paths())

print("Running Mac App publication guard tests passed.")
print("中文：运行中 Mac App 发布保护测试通过。")
