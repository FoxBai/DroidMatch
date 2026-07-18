#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import io
import os
import shutil
import signal
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("run-with-direct-usb-monitor.py")
SPEC = importlib.util.spec_from_file_location("direct_usb_monitor", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MONITOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MONITOR)

SERIAL = "RAW-SERIAL-DO-NOT-LEAK"


class MonitorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.guard = self.root / "unverified"
        self.guard.write_text("unverified\n")
        self.guard.chmod(0o600)
        self.status_file = self.root / "child-status"

    def tearDown(self):
        self.temporary.cleanup()

    @mock.patch.object(MONITOR, "_topology_is_direct", return_value=True)
    def test_child_status_is_preserved_when_topology_stays_direct(self, _direct):
        status = MONITOR.run_monitored(
            SERIAL,
            self.guard,
            self.status_file,
            [sys.executable, "-c", "raise SystemExit(7)"],
        )
        self.assertEqual(status, 0)
        self.assertEqual(self.status_file.read_text(), "7\n")
        self.assertTrue(self.guard.exists())

    @mock.patch.object(MONITOR, "_topology_is_direct", return_value=False)
    @mock.patch.object(MONITOR.subprocess, "Popen")
    def test_initial_refusal_never_starts_child(self, popen, _direct):
        self.assertEqual(
            MONITOR.run_monitored(SERIAL, self.guard, self.status_file, ["private"]),
            MONITOR.MONITOR_FAILURE_STATUS,
        )
        popen.assert_not_called()
        self.assertTrue(self.guard.is_file())

    @mock.patch.object(MONITOR.subprocess, "Popen")
    def test_interrupt_during_initial_topology_check_never_starts_child(self, popen):
        def interrupt_then_pass(_serial):
            MONITOR._record_interruption(signal.SIGTERM, None)
            return True

        try:
            with mock.patch.object(
                MONITOR, "_topology_is_direct", side_effect=interrupt_then_pass
            ):
                self.assertEqual(
                    MONITOR.run_monitored(
                        SERIAL, self.guard, self.status_file, ["private"]
                    ),
                    128 + signal.SIGTERM,
                )
            popen.assert_not_called()
        finally:
            MONITOR._interrupted_signal = None

    @mock.patch.object(MONITOR, "_topology_is_direct", return_value=True)
    @mock.patch.object(MONITOR, "_terminate", return_value=True)
    def test_interrupt_during_spawn_immediately_cleans_child(
        self, terminate, _direct
    ):
        child = mock.Mock()

        def spawn_then_interrupt(*_args, **_kwargs):
            MONITOR._record_interruption(signal.SIGHUP, None)
            return child

        try:
            with mock.patch.object(
                MONITOR.subprocess, "Popen", side_effect=spawn_then_interrupt
            ):
                self.assertEqual(
                    MONITOR.run_monitored(
                        SERIAL, self.guard, self.status_file, ["private"]
                    ),
                    128 + signal.SIGHUP,
                )
            terminate.assert_called_once_with(child)
            self.assertFalse(self.status_file.exists())
        finally:
            MONITOR._interrupted_signal = None

    def test_mid_run_refusal_terminates_child_and_marks_failure(self):
        checks = iter((True, False))
        command = [sys.executable, "-c", "import time;time.sleep(30)"]
        with mock.patch.object(MONITOR, "CHECK_INTERVAL_SECONDS", 0.01):
            with mock.patch.object(MONITOR, "_topology_is_direct", side_effect=checks):
                self.assertEqual(
                    MONITOR.run_monitored(SERIAL, self.guard, self.status_file, command),
                    MONITOR.MONITOR_FAILURE_STATUS,
                )
        self.assertTrue(self.guard.is_file())
        self.assertFalse(self.status_file.exists())

    def test_final_refusal_discards_success(self):
        checks = iter((True, False))
        command = [sys.executable, "-c", "pass"]
        with mock.patch.object(MONITOR, "_topology_is_direct", side_effect=checks):
            self.assertEqual(
                MONITOR.run_monitored(SERIAL, self.guard, self.status_file, command),
                MONITOR.MONITOR_FAILURE_STATUS,
            )
        self.assertTrue(self.guard.is_file())
        self.assertFalse(self.status_file.exists())

    def test_missing_guard_fails_closed(self):
        self.guard.unlink()
        with mock.patch.object(MONITOR, "_topology_is_direct", return_value=True):
            self.assertEqual(
                MONITOR.run_monitored(
                    SERIAL, self.guard, self.status_file, ["private"]
                ),
                MONITOR.MONITOR_FAILURE_STATUS,
            )

    @mock.patch.object(MONITOR, "_topology_is_direct", return_value=True)
    def test_child_status_publication_failure_discards_child_success(self, _direct):
        command = [sys.executable, "-c", "pass"]
        with mock.patch.object(MONITOR, "_publish_child_status", side_effect=OSError):
            self.assertEqual(
                MONITOR.run_monitored(
                    SERIAL, self.guard, self.status_file, command
                ),
                MONITOR.MONITOR_FAILURE_STATUS,
            )
        self.assertTrue(self.guard.exists())
        self.assertFalse(self.status_file.exists())

    def test_child_status_publication_retries_short_writes(self):
        real_write = MONITOR.os.write
        calls = 0

        def short_once(descriptor, payload):
            nonlocal calls
            calls += 1
            if calls == 1:
                return real_write(descriptor, payload[:1])
            return real_write(descriptor, payload)

        with mock.patch.object(MONITOR.os, "write", side_effect=short_once):
            MONITOR._publish_child_status(self.status_file, 37)
        self.assertEqual(self.status_file.read_bytes(), b"37\n")
        self.assertEqual(calls, 2)

    @mock.patch.object(MONITOR, "_topology_is_direct", return_value=True)
    @mock.patch.object(MONITOR, "_terminate", return_value=False)
    def test_unverified_process_group_cleanup_discards_child_success(
        self, _terminate, _direct
    ):
        status = MONITOR.run_monitored(
            SERIAL, self.guard, self.status_file, [sys.executable, "-c", "pass"]
        )
        self.assertEqual(status, MONITOR.MONITOR_FAILURE_STATUS)
        _terminate.assert_called_once()
        self.assertFalse(self.status_file.exists())

    @mock.patch.object(MONITOR, "_topology_is_direct", return_value=True)
    def test_replaced_guard_discards_child_success(self, _direct):
        def replace_guard(_child):
            self.guard.unlink()
            self.guard.write_text("replacement\n")
            self.guard.chmod(0o600)
            return True

        with mock.patch.object(MONITOR, "_terminate", side_effect=replace_guard):
            status = MONITOR.run_monitored(
                SERIAL, self.guard, self.status_file, [sys.executable, "-c", "pass"]
            )
        self.assertEqual(status, MONITOR.MONITOR_FAILURE_STATUS)
        self.assertFalse(self.status_file.exists())

    @mock.patch.object(MONITOR, "_topology_is_direct", return_value=True)
    def test_interrupt_after_status_publication_returns_reserved_status(self, _direct):
        real_publish = MONITOR._publish_child_status

        def publish_then_interrupt(path, status):
            real_publish(path, status)
            MONITOR._record_interruption(signal.SIGTERM, None)

        arguments = [
            "--serial",
            SERIAL,
            "--failure-guard",
            str(self.guard),
            "--child-status-file",
            str(self.status_file),
            "--",
            sys.executable,
            "-c",
            "pass",
        ]
        with mock.patch.object(MONITOR, "_publish_child_status", publish_then_interrupt):
            self.assertEqual(MONITOR.main(arguments), 128 + signal.SIGTERM)
        self.assertTrue(self.guard.exists())
        self.assertFalse(self.status_file.exists())

    def test_terminate_kills_descendant_after_session_leader_exits(self):
        descendant_late = self.root / "leaderless-descendant-late"
        started = self.root / "leader-exited"
        program = (
            "import subprocess,sys;from pathlib import Path;"
            "subprocess.Popen([sys.executable,'-c',"
            f"\"import time;from pathlib import Path;time.sleep(.3);Path({str(descendant_late)!r}).write_text('late')\"]);"
            f"Path({str(started)!r}).write_text('started')"
        )
        child = MONITOR.subprocess.Popen(
            [sys.executable, "-c", program], start_new_session=True
        )
        self.assertEqual(child.wait(timeout=3), 0)
        self.assertTrue(started.exists())
        self.assertTrue(MONITOR._terminate(child))
        time.sleep(0.5)
        self.assertFalse(descendant_late.exists())

    def test_terminate_fails_closed_when_process_group_signal_is_denied(self):
        child = mock.Mock(pid=12345)
        child.poll.return_value = 0
        with mock.patch.object(MONITOR.os, "killpg", side_effect=PermissionError):
            self.assertFalse(MONITOR._terminate(child))
        child.wait.assert_called_once()

    def test_term_kills_child_session_including_descendant(self):
        monitor = self.root / "run-with-direct-usb-monitor.py"
        checker = self.root / "check-direct-usb-device.py"
        shutil.copy2(MODULE_PATH, monitor)
        shutil.copy2(Path(__file__).parent / "test-fixtures/pass-direct-usb-check.py", checker)
        started = self.root / "started"
        child_late = self.root / "child-late"
        descendant_late = self.root / "descendant-late"
        program = (
            "import subprocess,sys,time;from pathlib import Path;"
            "subprocess.Popen([sys.executable,'-c',"
            f"\"import time;from pathlib import Path;time.sleep(.5);Path({str(descendant_late)!r}).write_text('late')\"]);"
            f"Path({str(started)!r}).write_text('started');time.sleep(.5);"
            f"Path({str(child_late)!r}).write_text('late')"
        )
        environment = dict(os.environ, FAKE_SERIAL=SERIAL)
        process = MONITOR.subprocess.Popen(
            [
                sys.executable,
                str(monitor),
                "--serial",
                SERIAL,
                "--failure-guard",
                str(self.guard),
                "--child-status-file",
                str(self.status_file),
                "--",
                sys.executable,
                "-c",
                program,
            ],
            stdout=MONITOR.subprocess.DEVNULL,
            stderr=MONITOR.subprocess.DEVNULL,
            env=environment,
        )
        try:
            deadline = time.monotonic() + 3
            while not started.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(started.exists())
            process.send_signal(signal.SIGTERM)
            if process.poll() is None:
                process.send_signal(signal.SIGHUP)
            self.assertIn(
                process.wait(timeout=3),
                (128 + signal.SIGTERM, 128 + signal.SIGHUP),
            )
            time.sleep(0.7)
            self.assertFalse(child_late.exists())
            self.assertFalse(descendant_late.exists())
            self.assertTrue(self.guard.exists())
            self.assertFalse(self.status_file.exists())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


class CommandTests(unittest.TestCase):
    def test_invalid_invocation_never_echoes_argument(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            status = MONITOR.main(["--serial", "private value"])
        self.assertEqual(status, 2)
        self.assertEqual(stdout.getvalue(), "")
        self.assertNotIn("private value", stderr.getvalue())

    def test_valid_invocation_routes_private_values_without_echoing(self):
        with tempfile.TemporaryDirectory() as temporary:
            guard = str(Path(temporary) / "guard")
            status_file = str(Path(temporary) / "status")
            with mock.patch.object(MONITOR, "run_monitored", return_value=0) as run:
                stdout, stderr = io.StringIO(), io.StringIO()
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    status = MONITOR.main(
                        [
                            "--serial",
                            SERIAL,
                            "--failure-guard",
                            guard,
                            "--child-status-file",
                            status_file,
                            "--",
                            "private",
                        ]
                    )
            self.assertEqual(status, 0)
            run.assert_called_once_with(
                SERIAL, Path(guard), Path(status_file), ["private"]
            )
            self.assertEqual(stdout.getvalue(), "")
            self.assertEqual(stderr.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
