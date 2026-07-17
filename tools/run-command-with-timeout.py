#!/usr/bin/env python3
"""Run one command with a process-group timeout and stable exit status 124."""

from __future__ import annotations

import os
import signal
import subprocess
import sys


USAGE = "usage: run-command-with-timeout.py SECONDS COMMAND [ARG ...]"


def terminate_process_group(process: subprocess.Popen[bytes], first_signal: int) -> None:
    try:
        os.killpg(process.pid, first_signal)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=3)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    process.wait()


def main(arguments: list[str]) -> int:
    if len(arguments) < 3:
        print(USAGE, file=sys.stderr)
        return 2
    try:
        timeout_seconds = float(arguments[1])
    except ValueError:
        print(USAGE, file=sys.stderr)
        return 2
    if timeout_seconds <= 0:
        print(USAGE, file=sys.stderr)
        return 2

    try:
        process = subprocess.Popen(arguments[2:], start_new_session=True)
    except OSError as error:
        print(f"could not start command: {error}", file=sys.stderr)
        return 127
    try:
        return process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        terminate_process_group(process, signal.SIGTERM)
        print(
            f"command timed out after {timeout_seconds:g} seconds: {arguments[2]}",
            file=sys.stderr,
        )
        return 124
    except KeyboardInterrupt:
        terminate_process_group(process, signal.SIGINT)
        return 130


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
