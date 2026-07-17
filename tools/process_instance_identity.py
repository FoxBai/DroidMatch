#!/usr/bin/env python3

"""Capture and compare a PID's boot-scoped process-start identity."""

from __future__ import annotations

import ctypes
import os
import re
import subprocess
import sys


TOKEN_PATTERN = re.compile(r"^[a-z0-9][a-z0-9:._-]{10,255}$")


class ProcessIdentityUnavailable(RuntimeError):
    """The platform could not safely identify a live process instance."""


def checked_pid(value: int | str) -> int:
    try:
        pid = int(value)
    except (TypeError, ValueError) as error:
        raise ValueError("PID must be a positive integer") from error
    if pid <= 0:
        raise ValueError("PID must be a positive integer")
    return pid


def darwin_boot_id() -> str:
    result = subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
        check=True,
        capture_output=True,
        text=True,
    )
    value = result.stdout.strip().lower()
    if not re.fullmatch(r"[0-9a-f-]{36}", value):
        raise ProcessIdentityUnavailable("invalid Darwin boot-session identity")
    return value


def darwin_identity(pid: int) -> str | None:
    class ProcBSDInfo(ctypes.Structure):
        _fields_ = [
            ("prefix", ctypes.c_uint32 * 12),
            ("command", ctypes.c_char * 16),
            ("name", ctypes.c_char * 32),
            ("suffix", ctypes.c_uint32 * 5),
            ("nice", ctypes.c_int32),
            ("start_seconds", ctypes.c_uint64),
            ("start_microseconds", ctypes.c_uint64),
        ]

    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    proc_pidinfo = library.proc_pidinfo
    proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    proc_pidinfo.restype = ctypes.c_int
    info = ProcBSDInfo()
    size = proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    if size == 0:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return None
        except PermissionError:
            pass
        raise ProcessIdentityUnavailable("proc_pidinfo could not identify a live PID")
    if size != ctypes.sizeof(info) or info.prefix[3] != pid:
        raise ProcessIdentityUnavailable("proc_pidinfo returned incomplete identity")
    return (
        f"darwin:{darwin_boot_id()}:{info.prefix[5]}:"
        f"{info.start_seconds}:{info.start_microseconds}"
    )


def linux_identity(pid: int) -> str | None:
    stat_path = f"/proc/{pid}/stat"
    try:
        with open(stat_path, "r", encoding="ascii") as source:
            process_stat = source.read()
        process_info = os.stat(f"/proc/{pid}")
    except FileNotFoundError:
        return None
    closing_parenthesis = process_stat.rfind(")")
    fields = process_stat[closing_parenthesis + 2 :].split()
    if closing_parenthesis < 1 or len(fields) <= 19 or not fields[19].isdigit():
        raise ProcessIdentityUnavailable("invalid Linux process stat identity")
    with open("/proc/sys/kernel/random/boot_id", "r", encoding="ascii") as source:
        boot_id = source.read().strip().lower()
    if not re.fullmatch(r"[0-9a-f-]{36}", boot_id):
        raise ProcessIdentityUnavailable("invalid Linux boot identity")
    return f"linux:{boot_id}:{process_info.st_uid}:{fields[19]}"


def process_identity(value: int | str) -> str | None:
    pid = checked_pid(value)
    if sys.platform == "darwin":
        return darwin_identity(pid)
    if sys.platform.startswith("linux"):
        return linux_identity(pid)
    raise ProcessIdentityUnavailable("unsupported process-identity platform")


def checked_token(value: str) -> str:
    if not TOKEN_PATTERN.fullmatch(value):
        raise ValueError("invalid process-instance identity")
    return value


def main() -> None:
    if len(sys.argv) not in (3, 4):
        raise SystemExit(2)
    action = sys.argv[1]
    try:
        identity = process_identity(sys.argv[2])
        if action == "capture" and len(sys.argv) == 3:
            if identity is None:
                raise SystemExit(1)
            print(identity)
            return
        if action == "matches" and len(sys.argv) == 4:
            expected = checked_token(sys.argv[3])
            raise SystemExit(0 if identity == expected else 1)
    except (OSError, subprocess.SubprocessError, ValueError, ProcessIdentityUnavailable):
        raise SystemExit(2)
    raise SystemExit(2)


if __name__ == "__main__":
    main()
