#!/usr/bin/env python3
"""Run one command while repeatedly enforcing a direct selected USB path."""

from __future__ import annotations

import os
import re
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path


CHECK_INTERVAL_SECONDS = 0.5
CHECK_TIMEOUT_SECONDS = 20
TERMINATE_GRACE_SECONDS = 5
MONITOR_FAILURE_STATUS = 86
SAFE_SERIAL = re.compile(r"[A-Za-z0-9._:-]{6,}")
CHECKER = Path(__file__).with_name("check-direct-usb-device.py")
WATCHED_SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
_interrupted_signal: int | None = None


def _record_interruption(signal_number: int, _frame: object) -> None:
    global _interrupted_signal
    if _interrupted_signal is None:
        _interrupted_signal = signal_number


def _interruption_status() -> int | None:
    if _interrupted_signal is None:
        return None
    return 128 + _interrupted_signal


def _topology_is_direct(serial: str) -> bool:
    try:
        result = subprocess.run(
            [sys.executable, str(CHECKER), "--serial", serial],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=CHECK_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def _private_regular_identity(metadata: os.stat_result) -> tuple[int, int] | None:
    if not (
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_nlink == 1
        and metadata.st_uid == os.geteuid()
        and stat.S_IMODE(metadata.st_mode) & 0o077 == 0
    ):
        return None
    return metadata.st_dev, metadata.st_ino


def _private_regular_file_identity(path: Path) -> tuple[int, int] | None:
    try:
        metadata = path.lstat()
    except OSError:
        return None
    return _private_regular_identity(metadata)


def _open_private_regular_file(path: Path) -> tuple[int, tuple[int, int]] | None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError:
        return None
    try:
        identity = _private_regular_identity(os.fstat(descriptor))
    except OSError:
        os.close(descriptor)
        return None
    if identity is None:
        os.close(descriptor)
        return None
    return descriptor, identity


def _terminate(child: subprocess.Popen[bytes]) -> bool:
    cleanup_permitted = True
    group_is_gone = False
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except PermissionError:
        cleanup_permitted = False
    deadline = time.monotonic() + TERMINATE_GRACE_SECONDS
    while time.monotonic() < deadline:
        child.poll()
        try:
            os.killpg(child.pid, 0)
        except ProcessLookupError:
            group_is_gone = True
            break
        except PermissionError:
            cleanup_permitted = False
            break
        time.sleep(0.01)
    if not group_is_gone:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            group_is_gone = True
        except PermissionError:
            cleanup_permitted = False
    try:
        child.wait(timeout=1)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
    try:
        os.killpg(child.pid, 0)
    except ProcessLookupError:
        group_is_gone = True
    except PermissionError:
        group_is_gone = False
        cleanup_permitted = False
    else:
        group_is_gone = False
    return cleanup_permitted and group_is_gone and child.poll() is not None


def _publish_child_status(path: Path, status: int) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        payload = f"{status}\n".encode("ascii")
        written = 0
        while written < len(payload):
            count = os.write(descriptor, payload[written:])
            if count <= 0:
                raise OSError("child status write did not make progress")
            written += count
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def run_monitored(serial: str, guard: Path, status_file: Path, command: list[str]) -> int:
    opened_guard = _open_private_regular_file(guard)
    if opened_guard is None:
        return MONITOR_FAILURE_STATUS
    guard_descriptor, guard_identity = opened_guard
    if (
        _interruption_status() is not None
        or status_file.exists()
        or status_file.is_symlink()
    ):
        os.close(guard_descriptor)
        return MONITOR_FAILURE_STATUS
    if not _topology_is_direct(serial):
        os.close(guard_descriptor)
        return MONITOR_FAILURE_STATUS
    interruption = _interruption_status()
    if interruption is not None:
        os.close(guard_descriptor)
        return interruption

    child: subprocess.Popen[bytes] | None = None
    result = MONITOR_FAILURE_STATUS
    status: int | None = None
    supervision_failed = False
    cleanup_attempted = False
    try:
        child = subprocess.Popen(command, start_new_session=True)
        interruption = _interruption_status()
        if interruption is not None:
            result = interruption
            supervision_failed = True
        while not supervision_failed:
            try:
                status = child.wait(timeout=CHECK_INTERVAL_SECONDS)
                break
            except subprocess.TimeoutExpired:
                interruption = _interruption_status()
                if interruption is not None:
                    result = interruption
                    supervision_failed = True
                    break
                if not _topology_is_direct(serial):
                    supervision_failed = True
                    break
        interruption = _interruption_status()
        if interruption is not None:
            result = interruption
        elif (
            supervision_failed
            or status is None
            or child.poll() is None
        ):
            result = MONITOR_FAILURE_STATUS
        else:
            cleanup_succeeded = _terminate(child)
            cleanup_attempted = True
            final_direct = _topology_is_direct(serial)
            interruption = _interruption_status()
            if interruption is not None:
                result = interruption
            elif (
                not cleanup_succeeded
                or not final_direct
                or _private_regular_file_identity(guard) != guard_identity
            ):
                result = MONITOR_FAILURE_STATUS
            else:
                _publish_child_status(status_file, status)
                result = _interruption_status() or 0
    except (OSError, subprocess.SubprocessError):
        result = MONITOR_FAILURE_STATUS
    finally:
        if child is not None and not cleanup_attempted:
            _terminate(child)
        os.close(guard_descriptor)
    interruption = _interruption_status()
    if interruption is not None:
        result = interruption
        try:
            status_file.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            result = MONITOR_FAILURE_STATUS
    return result


def main(argv: list[str]) -> int:
    global _interrupted_signal
    try:
        separator = argv.index("--")
    except ValueError:
        separator = -1
    if (
        separator != 6
        or argv[0] != "--serial"
        or not SAFE_SERIAL.fullmatch(argv[1])
        or argv[2] != "--failure-guard"
        or not argv[3]
        or argv[4] != "--child-status-file"
        or not argv[5]
        or not argv[7:]
    ):
        print("direct USB monitor refused: invalid invocation", file=sys.stderr)
        return 2
    guard = Path(argv[3])
    status_file = Path(argv[5])
    if (
        not guard.is_absolute()
        or not guard.parent.is_dir()
        or not status_file.is_absolute()
        or status_file.parent != guard.parent
    ):
        print("direct USB monitor refused: invalid guard boundary", file=sys.stderr)
        return 2
    watched = set(WATCHED_SIGNALS)
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, watched)
    previous_handlers = {}
    _interrupted_signal = None
    try:
        for signal_number in WATCHED_SIGNALS:
            previous_handlers[signal_number] = signal.signal(
                signal_number, _record_interruption
            )
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        result = run_monitored(argv[1], guard, status_file, argv[7:])
    finally:
        signal.pthread_sigmask(signal.SIG_BLOCK, watched)
        interruption = _interruption_status()
        pending = signal.sigpending().intersection(watched)
        if interruption is None and pending:
            interruption = 128 + min(pending)
        for signal_number in WATCHED_SIGNALS:
            signal.signal(signal_number, signal.SIG_IGN)
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        for signal_number, previous in previous_handlers.items():
            signal.signal(signal_number, previous)
        _interrupted_signal = None
    return interruption or result


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
