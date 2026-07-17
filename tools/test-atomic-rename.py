#!/usr/bin/env python3

"""Offline regressions for cross-platform atomic publication rename."""

from __future__ import annotations

import errno
import os
import tempfile
from pathlib import Path

from atomic_rename import (
    EXCHANGE,
    EXCLUSIVE,
    current_directory_fd,
    rename_configuration,
    rename_paths,
)


assert rename_configuration("darwin", EXCHANGE) == ("renameatx_np", 2)
assert rename_configuration("darwin", EXCLUSIVE) == ("renameatx_np", 4)
assert rename_configuration("linux", EXCHANGE) == ("renameat2", 2)
assert rename_configuration("linux", EXCLUSIVE) == ("renameat2", 1)
assert current_directory_fd("darwin") == -2
assert current_directory_fd("linux") == -100
try:
    rename_configuration("unsupported", EXCLUSIVE)
except RuntimeError:
    pass
else:
    raise AssertionError("unsupported platforms must fail closed")

with tempfile.TemporaryDirectory(prefix="droidmatch-atomic-rename-") as temporary:
    root = Path(temporary)
    source = root / "source"
    destination = root / "destination"
    source.write_text("candidate", encoding="ascii")
    rename_paths(str(source), str(destination), EXCLUSIVE)
    assert not source.exists()
    assert destination.read_text(encoding="ascii") == "candidate"

    source.write_text("second", encoding="ascii")
    try:
        rename_paths(str(source), str(destination), EXCLUSIVE)
    except OSError as error:
        assert error.errno == errno.EEXIST
    else:
        raise AssertionError("exclusive rename replaced an existing destination")
    assert source.read_text(encoding="ascii") == "second"
    assert destination.read_text(encoding="ascii") == "candidate"

    rename_paths(str(source), str(destination), EXCHANGE)
    assert source.read_text(encoding="ascii") == "candidate"
    assert destination.read_text(encoding="ascii") == "second"

    previous_directory = os.getcwd()
    try:
        os.chdir(root)
        relative_source = Path("relative-source")
        relative_destination = Path("relative-destination")
        relative_source.write_text("relative", encoding="ascii")
        rename_paths(str(relative_source), str(relative_destination), EXCLUSIVE)
        assert relative_destination.read_text(encoding="ascii") == "relative"
    finally:
        os.chdir(previous_directory)

print("Atomic publication rename tests passed.")
print("中文：原子发布重命名测试通过。")
