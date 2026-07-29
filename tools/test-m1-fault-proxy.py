#!/usr/bin/env python3
"""Offline process-group regressions for the M1 fault-proxy hook."""

import contextlib
import importlib.util
import io
import os
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools" / "m1-fault-proxy.py"
SPEC = importlib.util.spec_from_file_location("m1_fault_proxy", MODULE_PATH)
FAULT_PROXY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FAULT_PROXY)


HELPER_SOURCE = """\
import os
import subprocess
import sys
from pathlib import Path

parent_pid, child_pid, marker = map(Path, sys.argv[1:4])
delay = float(sys.argv[4])
parent_pid.write_text(f"{os.getpid()}\\n", encoding="ascii")
child_source = (
    "import sys,time\\n"
    "from pathlib import Path\\n"
    "time.sleep(float(sys.argv[2]))\\n"
    "Path(sys.argv[1]).write_text('late child survived\\\\n', encoding='utf-8')\\n"
)
child = subprocess.Popen(
    [sys.executable, "-c", child_source, str(marker), str(delay)]
)
child_pid.write_text(f"{child.pid}\\n", encoding="ascii")
child.wait()
"""


ORPHAN_HELPER_SOURCE = """\
import os
import subprocess
import sys
from pathlib import Path

parent_pid, child_pid, marker = map(Path, sys.argv[1:])
parent_pid.write_text(f"{os.getpid()}\\n", encoding="ascii")
child_source = (
    "import sys,time\\n"
    "from pathlib import Path\\n"
    "time.sleep(0.8)\\n"
    "Path(sys.argv[1]).write_text('orphan child survived\\\\n', encoding='utf-8')\\n"
)
child = subprocess.Popen(
    [sys.executable, "-c", child_source, str(marker)],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
child_pid.write_text(f"{child.pid}\\n", encoding="ascii")
"""


RUNNER_SOURCE = """\
import importlib.util
import signal
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("m1_fault_proxy", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.install_termination_signal_handlers()
original_handler = module.handle_termination_signal
signal_marker = Path(sys.argv[3])
def observed_handler(signum, frame):
    signal_marker.write_text(f"{signum}\\n", encoding="ascii")
    original_handler(signum, frame)
signal.signal(signal.SIGTERM, observed_handler)
signal.signal(signal.SIGHUP, observed_handler)
module.run_hook_command([sys.executable, sys.argv[2], *sys.argv[4:]], 30.0)
"""

CLIENT_SOURCE = """\
import socket
import sys

with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3.0) as client:
    client.settimeout(None)
    while client.recv(4096):
        pass
"""

IDENTITY_SOURCE = """\
import os
import signal
import sys
from pathlib import Path

def process_identity(process_id):
    os.kill(process_id, 0)
    return f"test-process:{process_id}"

def main():
    action, pid_text, *rest = sys.argv[1:]
    pid = int(pid_text)
    token = f"test-process:{pid}"
    if action == "capture" and not rest:
        print(process_identity(pid))
        raise SystemExit(0)
    if action == "matches" and rest == [token]:
        stat_path = Path(f"/proc/{pid}/stat")
        if stat_path.exists():
            fields = stat_path.read_text(encoding="ascii").rsplit(")", 1)[1].split()
            if fields[0] == "Z":
                raise SystemExit(1)
        os.kill(pid, 0)
        raise SystemExit(0)
    if action == "signal" and len(rest) == 2 and rest[0] == token:
        os.kill(pid, {"TERM": signal.SIGTERM, "KILL": signal.SIGKILL}[rest[1]])
        raise SystemExit(0)
    raise SystemExit(1)

if __name__ == "__main__":
    main()
"""

DEVICE_WRAPPER_SOURCE = """\
set -euo pipefail
repo_root="$1"
allocated_local_port="$2"
fault_proxy_scope_root="$3"
fault_proxy_registry_file="${fault_proxy_scope_root}/active"
fault_proxy_shutdown_status_file="${fault_proxy_scope_root}/shutdown-status"
hook_script="$4"
client_script="$5"
identity_script="$6"
DROIDMATCH_FAULT_PROXY_TEST_MODE=1
DROIDMATCH_TEST_FAULT_PROXY_IDENTITY_TOOL="${identity_script}"
export DROIDMATCH_FAULT_PROXY_TEST_MODE DROIDMATCH_TEST_FAULT_PROXY_IDENTITY_TOOL
cd "${repo_root}"
source "${repo_root}/tools/m1-device-smoke-device-control.sh"
source "${repo_root}/tools/m1-device-smoke-cleanup.sh"
print_redacted_output() { :; }
redacted_output() { cat >/dev/null; }
run_swift_harness() {
  local proxy_port=""
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == "--port" ]]; then
      proxy_port="$2"
      shift 2
    else
      shift
    fi
  done
  python3 "${client_script}" "${proxy_port}"
}
media_permission_revoked_check=0
media_permission_revoked_during_download_check=0
media_permission_restore_baseline_captured=0
media_permission_restored=0
cleanup_upload_destination=0
adb_bin=/usr/bin/true
serial=offline-test
trap 'cleanup "$?"' EXIT
trap 'cleanup 143' TERM
FAULT_PROXY_DROP_AFTER_FRAMES=0 \
FAULT_PROXY_HOOK_AFTER_FRAMES=1 \
FAULT_PROXY_HOOK_PROGRAM=bash \
FAULT_PROXY_HOOK_ARGUMENT="${hook_script}" \
  run_swift_harness_with_fault_proxy probe
"""


def process_is_alive(pid):
    result = subprocess.run(
        ["ps", "-o", "stat=", "-p", str(pid)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return False
    state = result.stdout.strip()
    return bool(state) and not state.startswith("Z")


def wait_for_path(path, timeout=2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists() and path.stat().st_size > 0:
            return
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for {path.name}")


def wait_for_process_exit(pid, timeout=2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not process_is_alive(pid):
            return
        time.sleep(0.01)
    raise AssertionError(f"process {pid} remained alive")


class FaultProxyHookTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="droidmatch-fault-proxy-test.")
        self.root = Path(self.temporary.name)
        self.helper = self.root / "hook-helper.py"
        self.orphan_helper = self.root / "orphan-hook-helper.py"
        self.runner = self.root / "hook-runner.py"
        self.helper.write_text(HELPER_SOURCE, encoding="utf-8")
        self.orphan_helper.write_text(ORPHAN_HELPER_SOURCE, encoding="utf-8")
        self.runner.write_text(RUNNER_SOURCE, encoding="utf-8")
        self.parent_pid = self.root / "parent.pid"
        self.child_pid = self.root / "child.pid"
        self.marker = self.root / "late.marker"
        self.signal_marker = self.root / "signal.marker"
        with FAULT_PROXY._active_hook_lock:
            self.assertIsNone(FAULT_PROXY._active_hook_process)
            FAULT_PROXY._shutdown_requested = False
            FAULT_PROXY._shutdown_signum = None
            FAULT_PROXY._hook_cleanup_confirmed = True
            FAULT_PROXY._hook_start_decision = {}

    def tearDown(self):
        if self.parent_pid.exists():
            process_group = int(self.parent_pid.read_text(encoding="ascii"))
            try:
                os.killpg(process_group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.temporary.cleanup()

    def hook_argv(self, delay=0.8):
        return [
            sys.executable,
            str(self.helper),
            str(self.parent_pid),
            str(self.child_pid),
            str(self.marker),
            str(delay),
        ]

    def assert_hook_tree_gone(self):
        wait_for_path(self.child_pid)
        parent_pid = int(self.parent_pid.read_text(encoding="ascii"))
        child_pid = int(self.child_pid.read_text(encoding="ascii"))
        wait_for_process_exit(parent_pid)
        wait_for_process_exit(child_pid)
        time.sleep(0.9)
        self.assertFalse(self.marker.exists(), "a timed-out hook descendant ran late")

    def test_timeout_terminates_complete_hook_process_group(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            FAULT_PROXY.run_hook_command(self.hook_argv(3.0), 1.0)
        self.assertIn("timed out after 1.0s", stderr.getvalue())
        self.assert_hook_tree_gone()

    def test_consecutive_proxy_signals_terminate_active_hook_process_group(self):
        wrapper = subprocess.Popen(
            [
                sys.executable,
                str(self.runner),
                str(MODULE_PATH),
                str(self.helper),
                str(self.signal_marker),
                str(self.parent_pid),
                str(self.child_pid),
                str(self.marker),
                "0.8",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            wait_for_path(self.child_pid)
            os.kill(wrapper.pid, signal.SIGTERM)
            wait_for_path(self.signal_marker)
            self.assertEqual(
                self.signal_marker.read_text(encoding="ascii").strip(),
                str(signal.SIGTERM),
            )
            os.kill(wrapper.pid, signal.SIGHUP)
            wrapper.communicate(timeout=3.0)
            self.assertEqual(wrapper.returncode, 128 + signal.SIGTERM)
            self.assert_hook_tree_gone()
        finally:
            if wrapper.poll() is None:
                wrapper.kill()
                wrapper.wait(timeout=2.0)

    def test_shutdown_requested_before_spawn_prevents_late_hook(self):
        FAULT_PROXY.handle_termination_signal(signal.SIGTERM, None)
        self.assertTrue(FAULT_PROXY._shutdown_requested)
        self.assertEqual(FAULT_PROXY._shutdown_signum, signal.SIGTERM)
        stderr = io.StringIO()
        with mock.patch.object(FAULT_PROXY.subprocess, "Popen") as popen:
            with contextlib.redirect_stderr(stderr):
                FAULT_PROXY.run_hook_command(self.hook_argv(), 30.0)
        popen.assert_not_called()
        self.assertIn("skipped because shutdown was requested", stderr.getvalue())
        time.sleep(0.9)
        self.assertFalse(self.marker.exists(), "a hook spawned after shutdown")

    def test_shutdown_claim_before_start_commit_keeps_gate_closed(self):
        process = mock.Mock(pid=12345)

        def shutdown_before_commit():
            FAULT_PROXY.handle_termination_signal(signal.SIGTERM, None)
            return FAULT_PROXY._hook_start_decision.setdefault(
                "decision",
                "start",
            ) == "start"

        with (
            mock.patch.object(
                FAULT_PROXY.subprocess,
                "Popen",
                return_value=process,
            ),
            mock.patch.object(
                FAULT_PROXY,
                "claim_hook_start",
                side_effect=shutdown_before_commit,
            ),
            mock.patch.object(
                FAULT_PROXY,
                "terminate_process_group",
                return_value=True,
            ),
        ):
            with self.assertRaises(FAULT_PROXY.HookShutdownRequested):
                FAULT_PROXY.start_hook_process(["/bin/true"], self.marker)
        process.stdin.write.assert_not_called()
        self.assertIsNone(FAULT_PROXY._active_hook_process)

    def test_failed_prestart_cleanup_blocks_clean_shutdown_marker(self):
        process = mock.Mock(pid=12345)

        def shutdown_before_commit():
            FAULT_PROXY.handle_termination_signal(signal.SIGTERM, None)
            return False

        with (
            mock.patch.object(
                FAULT_PROXY.subprocess,
                "Popen",
                return_value=process,
            ),
            mock.patch.object(
                FAULT_PROXY,
                "claim_hook_start",
                side_effect=shutdown_before_commit,
            ),
            mock.patch.object(
                FAULT_PROXY,
                "terminate_process_group",
                return_value=False,
            ),
        ):
            with self.assertRaises(FAULT_PROXY.HookCleanupUnconfirmed):
                FAULT_PROXY.start_hook_process(["/bin/true"], self.marker)
        self.assertFalse(FAULT_PROXY._hook_cleanup_confirmed)
        self.assertFalse(FAULT_PROXY.request_hook_shutdown())

    def test_shutdown_closed_start_pipe_is_classified_without_thread_error(self):
        process = mock.Mock(pid=12345)

        def close_start_pipe(_value):
            FAULT_PROXY.handle_termination_signal(signal.SIGTERM, None)
            raise ValueError("write to closed file")

        process.stdin.write.side_effect = close_start_pipe
        with (
            mock.patch.object(
                FAULT_PROXY.subprocess,
                "Popen",
                return_value=process,
            ),
            mock.patch.object(
                FAULT_PROXY,
                "terminate_process_group",
                return_value=True,
            ),
        ):
            with self.assertRaises(FAULT_PROXY.HookShutdownRequested):
                FAULT_PROXY.start_hook_process(["/bin/true"], self.marker)
        self.assertTrue(FAULT_PROXY._hook_cleanup_confirmed)
        self.assertIsNone(FAULT_PROXY._active_hook_process)

    def test_token_bound_cooperative_shutdown_writes_clean_marker(self):
        port_file = self.root / "cooperative.port"
        request_file = self.root / "cooperative.request"
        status_file = self.root / "cooperative.status"
        identity_file = self.root / "cooperative.identity"
        identity_tool = self.root / "cooperative-identity.py"
        identity_tool.write_text(IDENTITY_SOURCE, encoding="utf-8")
        token = "0123456789abcdef0123456789abcdef"
        proxy = subprocess.Popen(
            [
                sys.executable,
                str(MODULE_PATH),
                "--target-port",
                "9",
                "--port-file",
                str(port_file),
                "--shutdown-status-file",
                str(status_file),
                "--shutdown-request-file",
                str(request_file),
                "--identity-file",
                str(identity_file),
                "--identity-tool",
                str(identity_tool),
                "--shutdown-token",
                token,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            try:
                wait_for_path(port_file, timeout=5.0)
            except AssertionError as error:
                stdout, stderr = proxy.communicate(timeout=2.0)
                self.fail(
                    f"{error}; returncode={proxy.returncode} "
                    f"stdout={stdout!r} stderr={stderr!r}"
                )
            request_file.write_text(
                "shutdown ffffffffffffffffffffffffffffffff\n",
                encoding="ascii",
            )
            time.sleep(0.2)
            self.assertIsNone(proxy.poll())
            request_file.write_text(f"shutdown {token}\n", encoding="ascii")
            proxy.communicate(timeout=3.0)
            self.assertEqual(proxy.returncode, 128 + signal.SIGTERM)
            self.assertEqual(
                status_file.read_text(encoding="ascii"),
                f"clean {token}\n",
            )
        finally:
            if proxy.poll() is None:
                proxy.kill()
                proxy.wait(timeout=2.0)

    def test_completed_parent_cannot_leave_hook_descendant_running(self):
        command = [
            sys.executable,
            str(self.orphan_helper),
            str(self.parent_pid),
            str(self.child_pid),
            str(self.marker),
        ]
        FAULT_PROXY.run_hook_command(command, 30.0)
        self.assert_hook_tree_gone()

    def test_termination_waits_for_spawn_registration_boundary(self):
        real_popen = subprocess.Popen
        spawned = threading.Event()
        release_spawn = threading.Event()

        def delayed_registration_popen(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            spawned.set()
            self.assertTrue(release_spawn.wait(timeout=2.0))
            return process

        def run_hook_until_shutdown():
            with contextlib.suppress(FAULT_PROXY.ProxyTerminationRequested):
                FAULT_PROXY.run_hook_command(self.hook_argv(), 30.0)

        hook_thread = threading.Thread(target=run_hook_until_shutdown)
        with mock.patch.object(FAULT_PROXY.subprocess, "Popen", delayed_registration_popen):
            hook_thread.start()
            self.assertTrue(spawned.wait(timeout=2.0))
            cleanup_thread = threading.Thread(
                target=FAULT_PROXY.request_hook_shutdown
            )
            cleanup_thread.start()
            time.sleep(0.05)
            self.assertTrue(
                cleanup_thread.is_alive(),
                "cleanup crossed the spawn boundary before registration",
            )
            release_spawn.set()
            cleanup_thread.join(timeout=3.0)
            hook_thread.join(timeout=3.0)
        self.assertFalse(cleanup_thread.is_alive())
        self.assertFalse(hook_thread.is_alive())
        if self.child_pid.exists():
            self.assert_hook_tree_gone()
        else:
            time.sleep(0.9)
            self.assertFalse(self.marker.exists(), "a hook crossed the start gate")

    def test_terminating_parent_wrapper_cleans_proxy_and_hook_tree(self):
        wrapper_scope = self.root / "wrapper-scope"
        wrapper_scope.mkdir(mode=0o700)
        registry = wrapper_scope / "active"
        hook_script = self.root / "wrapper-hook.sh"
        client_script = self.root / "wrapper-client.py"
        identity_script = self.root / "wrapper-identity.py"
        wrapper_script = self.root / "device-wrapper.sh"
        hook_script.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f"exec {sys.executable} {self.helper} "
            f"{self.parent_pid} {self.child_pid} {self.marker} 0.8\n",
            encoding="utf-8",
        )
        client_script.write_text(CLIENT_SOURCE, encoding="utf-8")
        identity_script.write_text(IDENTITY_SOURCE, encoding="utf-8")
        wrapper_script.write_text(DEVICE_WRAPPER_SOURCE, encoding="utf-8")
        hook_script.chmod(0o700)

        target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        target.bind(("127.0.0.1", 0))
        target.listen(1)
        target_port = target.getsockname()[1]

        def serve_frame():
            try:
                connection, _ = target.accept()
                with connection:
                    connection.sendall(struct.pack(">I", 1) + b"x")
                    while connection.recv(4096):
                        pass
            except OSError:
                pass

        server_thread = threading.Thread(target=serve_frame, daemon=True)
        server_thread.start()
        wrapper = subprocess.Popen(
            [
                "bash",
                str(wrapper_script),
                str(ROOT),
                str(target_port),
                str(wrapper_scope),
                str(hook_script),
                str(client_script),
                str(identity_script),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        proxy_pid = None
        try:
            try:
                wait_for_path(self.child_pid, timeout=5.0)
            except AssertionError as error:
                os.killpg(wrapper.pid, signal.SIGTERM)
                stdout, stderr = wrapper.communicate(timeout=12.0)
                self.fail(f"{error}; stdout={stdout!r} stderr={stderr!r}")
            wait_for_path(registry)
            proxy_pid = int(
                registry.read_text(encoding="ascii").split(maxsplit=1)[0]
            )
            os.killpg(wrapper.pid, signal.SIGTERM)
            wrapper_stdout, wrapper_stderr = wrapper.communicate(timeout=12.0)
            self.assertNotEqual(wrapper.returncode, 0)
            wait_for_process_exit(proxy_pid)
            self.assertFalse(
                registry.exists(),
                f"stdout={wrapper_stdout!r} stderr={wrapper_stderr!r}",
            )
            self.assert_hook_tree_gone()
        finally:
            target.close()
            if wrapper.poll() is None:
                wrapper.kill()
                wrapper.wait(timeout=2.0)
            if proxy_pid is None and registry.exists():
                proxy_pid = int(
                    registry.read_text(encoding="ascii").split(maxsplit=1)[0]
                )
            if proxy_pid is not None and process_is_alive(proxy_pid):
                os.kill(proxy_pid, signal.SIGKILL)
            server_thread.join(timeout=2.0)

    def test_hook_cli_preserves_explicit_argv(self):
        argv = [
            "m1-fault-proxy.py",
            "--target-port",
            "39001",
            "--after-first-server-frames-command",
            "/bin/echo",
            "--literal-hook-argument",
        ]
        with mock.patch.object(sys, "argv", argv):
            args = FAULT_PROXY.parse_args()
        self.assertEqual(
            args.after_first_server_frames_command,
            ["/bin/echo", "--literal-hook-argument"],
        )

    def test_hook_timeout_rejects_nonfinite_or_nonpositive_values(self):
        for value in ("0", "-1", "nan", "inf"):
            argv = [
                "m1-fault-proxy.py",
                "--target-port",
                "39001",
                "--after-first-server-frames-command-timeout",
                value,
            ]
            with self.subTest(value=value), mock.patch.object(sys, "argv", argv):
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit):
                        FAULT_PROXY.parse_args()
        with self.assertRaises(ValueError):
            FAULT_PROXY.run_hook_command(["/bin/true"], float("nan"))


if __name__ == "__main__":
    unittest.main()
