#!/usr/bin/env python3
"""Keep a hook process group owned until the fault proxy tears it down."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result-file", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("hook command is required")
    return args


def write_result(path: Path, payload: dict[str, object]) -> None:
    temporary = path.with_name(f"{path.name}.new.{os.getpid()}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
            json.dump(payload, destination)
            destination.write("\n")
            destination.flush()
            os.fsync(destination.fileno())
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        temporary.unlink(missing_ok=True)
        raise
    os.replace(temporary, path)


def main() -> None:
    args = parse_args()
    try:
        start_byte = sys.stdin.buffer.read(1)
    except InterruptedError:
        start_byte = b""
    if start_byte != b"S":
        return
    process = subprocess.Popen(
        args.command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    stdout, stderr = process.communicate()
    write_result(
        Path(args.result_file),
        {
            "returncode": process.returncode,
            "stdout": stdout,
            "stderr": stderr,
        },
    )

    # The proxy deliberately terminates this supervisor's process group after
    # reading the result. Remaining alive keeps the PGID owned and therefore
    # prevents it from being reused between identity verification and killpg.
    while True:
        try:
            signal_byte = sys.stdin.buffer.read(1)
        except InterruptedError:
            continue
        if not signal_byte:
            return


if __name__ == "__main__":
    main()
