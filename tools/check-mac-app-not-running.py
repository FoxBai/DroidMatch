#!/usr/bin/env python3
"""Refuse to publish over a DroidMatch App that still owns a live process."""

from __future__ import annotations

import ctypes
import os
from pathlib import Path
import struct
import sys
from typing import Iterable, Iterator


APP_EXECUTABLE = Path("Contents/MacOS/DroidMatch")
DELETED_SUFFIX = " (deleted)"


class ProcessInspectionError(RuntimeError):
    pass


def normalized_path(path: str | os.PathLike[str]) -> str:
    value = os.fspath(path)
    if value.endswith(DELETED_SUFFIX):
        value = value[: -len(DELETED_SUFFIX)]
    return os.path.realpath(os.path.abspath(value))


def linux_process_paths() -> Iterator[str]:
    proc = Path("/proc")
    if not proc.is_dir():
        raise ProcessInspectionError("the process filesystem is unavailable")
    observed = 0
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        paths = []
        try:
            paths.append(os.readlink(entry / "exe"))
        except (FileNotFoundError, PermissionError, ProcessLookupError, OSError):
            pass
        try:
            command_line = (entry / "cmdline").read_bytes()
            argument_zero = command_line.split(b"\0", 1)[0]
            if argument_zero:
                argument_path = os.fsdecode(argument_zero)
                if not os.path.isabs(argument_path):
                    argument_path = os.path.join(os.readlink(entry / "cwd"), argument_path)
                paths.append(argument_path)
        except (FileNotFoundError, PermissionError, ProcessLookupError, OSError):
            pass
        for path in paths:
            observed += 1
            yield path
    if observed == 0:
        raise ProcessInspectionError("no process executable paths were readable")


def darwin_process_paths() -> Iterator[str]:
    try:
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        list_pids = library.proc_listpids
        pid_path = library.proc_pidpath
    except (OSError, AttributeError) as error:
        raise ProcessInspectionError("libproc process inspection is unavailable") from error

    list_pids.argtypes = [ctypes.c_uint32, ctypes.c_uint32,
                          ctypes.c_void_p, ctypes.c_int]
    list_pids.restype = ctypes.c_int
    pid_path.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    pid_path.restype = ctypes.c_int
    required_bytes = list_pids(1, 0, None, 0)  # PROC_ALL_PIDS
    if required_bytes <= 0:
        raise ProcessInspectionError("the process list could not be read")
    capacity = max(1024, (required_bytes // ctypes.sizeof(ctypes.c_int)) * 2)
    pids = (ctypes.c_int * capacity)()
    used_bytes = list_pids(1, 0, pids, ctypes.sizeof(pids))
    if used_bytes <= 0:
        raise ProcessInspectionError("the process list could not be populated")

    system = ctypes.CDLL(None, use_errno=True)
    sysctl = system.sysctl
    sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint,
                       ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t),
                       ctypes.c_void_p, ctypes.c_size_t]
    sysctl.restype = ctypes.c_int

    def argument_executable(pid: int) -> str | None:
        mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
        size = ctypes.c_size_t(0)
        if sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
            return None
        if size.value <= struct.calcsize("i") or size.value > 1024 * 1024:
            return None
        data = ctypes.create_string_buffer(size.value)
        if sysctl(mib, 3, data, ctypes.byref(size), None, 0) != 0:
            return None
        payload = data.raw[struct.calcsize("i") : size.value]
        encoded_path = payload.split(b"\0", 1)[0]
        return os.fsdecode(encoded_path) if encoded_path else None

    observed = 0
    path_buffer = ctypes.create_string_buffer(4096)
    for pid in pids[: used_bytes // ctypes.sizeof(ctypes.c_int)]:
        if pid <= 0:
            continue
        path_buffer.value = b""
        if pid_path(pid, path_buffer, ctypes.sizeof(path_buffer)) > 0:
            observed += 1
            yield os.fsdecode(path_buffer.value)
        launch_path = argument_executable(pid)
        if launch_path is not None:
            observed += 1
            yield launch_path
    if observed == 0:
        raise ProcessInspectionError("no process executable paths were readable")


def process_paths() -> Iterable[str]:
    if sys.platform == "darwin":
        return darwin_process_paths()
    if sys.platform.startswith("linux"):
        return linux_process_paths()
    raise ProcessInspectionError(f"unsupported process-inspection platform: {sys.platform}")


def is_app_running(app_path: Path, executable_paths: Iterable[str]) -> bool:
    target = normalized_path(app_path / APP_EXECUTABLE)
    return any(normalized_path(path) == target for path in executable_paths)


def main() -> int:
    if len(sys.argv) != 2 or not sys.argv[1].endswith(".app"):
        print("usage: check-mac-app-not-running.py <DroidMatch.app>", file=sys.stderr)
        return 2
    app_path = Path(sys.argv[1])
    try:
        running = is_app_running(app_path, process_paths())
    except (OSError, ProcessInspectionError) as error:
        print(f"Could not safely inspect running Apps: {error}", file=sys.stderr)
        print("中文：无法安全检查正在运行的 App；已停止发布。", file=sys.stderr)
        return 1
    if running:
        print("DroidMatch is still running from the publication target. Quit it before rebuilding this App.", file=sys.stderr)
        print("中文：目标位置的 DroidMatch 仍在运行；请先退出，再重新构建此 App。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
