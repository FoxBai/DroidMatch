#!/usr/bin/env python3
"""Offline fail-closed regressions for M1 permission and cleanup gates."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
PARSER_PATH = ROOT / "tools" / "m1-media-permission-snapshot.py"
SPEC = importlib.util.spec_from_file_location(
    "m1_media_permission_snapshot",
    PARSER_PATH,
)
SNAPSHOT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SNAPSHOT)
IDENTITY_PATH = ROOT / "tools" / "process_instance_identity.py"
IDENTITY_SPEC = importlib.util.spec_from_file_location(
    "process_instance_identity",
    IDENTITY_PATH,
)
IDENTITY = importlib.util.module_from_spec(IDENTITY_SPEC)
IDENTITY_SPEC.loader.exec_module(IDENTITY)


def user_block(user: int, states: list[tuple[str, bool]]) -> str:
    lines = [f"  User {user}: installed=true"]
    lines.extend(
        f"    {permission}: granted={'true' if granted else 'false'}, flags=[]"
        for permission, granted in states
    )
    return "\n".join(lines)


class MediaPermissionSnapshotTests(unittest.TestCase):
    def test_api34_uses_only_complete_current_user_block(self):
        package_state = "\n".join(
            [
                user_block(
                    0,
                    [
                        (SNAPSHOT.READ_IMAGES, False),
                        (SNAPSHOT.READ_VIDEO, False),
                        (SNAPSHOT.READ_SELECTED, False),
                    ],
                ),
                user_block(
                    10,
                    [
                        (SNAPSHOT.READ_IMAGES, True),
                        (SNAPSHOT.READ_VIDEO, False),
                        (SNAPSHOT.READ_SELECTED, True),
                    ],
                ),
            ]
        )
        self.assertEqual(
            SNAPSHOT.parse_snapshot(package_state, 34, 10),
            (0, 1, 0, 1),
        )

    def test_api33_requires_images_and_video_only(self):
        package_state = user_block(
            0,
            [
                (SNAPSHOT.READ_IMAGES, True),
                (SNAPSHOT.READ_VIDEO, False),
            ],
        )
        self.assertEqual(
            SNAPSHOT.parse_snapshot(package_state, 33, 0),
            (0, 1, 0, 0),
        )
        with self.assertRaises(SNAPSHOT.SnapshotRejected):
            SNAPSHOT.parse_snapshot(
                package_state
                + f"\n    {SNAPSHOT.READ_SELECTED}: granted=false, flags=[]",
                33,
                0,
            )

    def test_api26_requires_external_storage_only(self):
        package_state = user_block(
            0,
            [(SNAPSHOT.READ_EXTERNAL, True)],
        )
        self.assertEqual(
            SNAPSHOT.parse_snapshot(package_state, 26, 0),
            (1, 0, 0, 0),
        )

    def test_partial_current_user_cannot_borrow_another_users_state(self):
        package_state = "\n".join(
            [
                user_block(
                    0,
                    [
                        (SNAPSHOT.READ_IMAGES, False),
                        (SNAPSHOT.READ_VIDEO, False),
                        (SNAPSHOT.READ_SELECTED, False),
                    ],
                ),
                user_block(
                    10,
                    [
                        (SNAPSHOT.READ_IMAGES, True),
                        (SNAPSHOT.READ_VIDEO, False),
                    ],
                ),
            ]
        )
        with self.assertRaises(SNAPSHOT.SnapshotRejected):
            SNAPSHOT.parse_snapshot(package_state, 34, 10)

    def test_duplicate_conflicting_or_ambiguous_user_state_is_rejected(self):
        conflicting = user_block(
            0,
            [
                (SNAPSHOT.READ_IMAGES, True),
                (SNAPSHOT.READ_IMAGES, False),
                (SNAPSHOT.READ_VIDEO, False),
                (SNAPSHOT.READ_SELECTED, False),
            ],
        )
        duplicate_user = "\n".join(
            [
                user_block(
                    0,
                    [
                        (SNAPSHOT.READ_IMAGES, True),
                        (SNAPSHOT.READ_VIDEO, False),
                        (SNAPSHOT.READ_SELECTED, False),
                    ],
                ),
                user_block(
                    0,
                    [
                        (SNAPSHOT.READ_IMAGES, False),
                        (SNAPSHOT.READ_VIDEO, False),
                        (SNAPSHOT.READ_SELECTED, False),
                    ],
                ),
            ]
        )
        for package_state in (conflicting, duplicate_user):
            with self.subTest(package_state=package_state):
                with self.assertRaises(SNAPSHOT.SnapshotRejected):
                    SNAPSHOT.parse_snapshot(package_state, 34, 0)


class ProcessInstanceSignalTests(unittest.TestCase):
    def test_signal_targets_only_the_captured_process_instance(self):
        token = "linux:00000000-0000-0000-0000-000000000000:1:12345"
        with (
            mock.patch.object(IDENTITY, "linux_pidfd_open", return_value=17),
            mock.patch.object(IDENTITY.os, "close") as close,
            mock.patch.object(IDENTITY, "linux_identity", return_value=token),
            mock.patch.object(IDENTITY, "linux_pidfd_send_signal") as send,
        ):
            self.assertFalse(
                IDENTITY.signal_linux_instance(101, f"{token}x", 15)
            )
            send.assert_not_called()
            self.assertTrue(IDENTITY.signal_linux_instance(101, token, 15))
            send.assert_called_once_with(17, 15)
            self.assertEqual(close.call_count, 2)


CLEANUP_PROBE = r"""
set -euo pipefail
repo_root="$1"
scope="$2"
mode="$3"
restore_marker="$4"
original_status="$5"
fault_proxy_scope_root="${scope}"
fault_proxy_registry_file="${scope}/active"
fault_proxy_shutdown_status_file="${scope}/shutdown-status"
fault_proxy_shutdown_request_file="${scope}/shutdown-request"
source "${repo_root}/tools/m1-device-smoke-device-control.sh"
source "${repo_root}/tools/m1-device-smoke-cleanup.sh"
media_permission_revoked_check=1
media_permission_revoked_during_download_check=0
media_permission_restore_baseline_captured=1
media_permission_restored=0
cleanup_upload_destination=0
allocated_local_port=""
restore_media_permissions_after_check() {
  printf 'restore-visible\n'
  printf 'called\n' >"${restore_marker}"
  [[ "${mode}" != restore-failure ]]
}
fault_proxy_instance_matches() {
  [[ "${mode}" != identity-error ]] || return 2
  return 0
}
signal_fault_proxy_instance() {
  return 0
}
sleep() { :; }
if [[ "${mode}" == identity-error || "${mode}" == kill-fallback ]]; then
  printf '101 test-process:101 0123456789abcdef0123456789abcdef\n' \
    >"${fault_proxy_registry_file}"
fi
cleanup "${original_status}"
"""


class ProductionCleanupTests(unittest.TestCase):
    def run_cleanup(self, mode: str, original_status: int = 0):
        temporary = tempfile.TemporaryDirectory(
            prefix="droidmatch-cleanup-safety."
        )
        root = Path(temporary.name)
        scope = root / "scope"
        scope.mkdir(mode=0o700)
        marker = root / "restore.marker"
        result = subprocess.run(
            [
                "bash",
                "-c",
                textwrap.dedent(CLEANUP_PROBE),
                "cleanup-probe",
                str(ROOT),
                str(scope),
                mode,
                str(marker),
                str(original_status),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        return temporary, scope, marker, result

    def test_identity_probe_error_preserves_scope_and_skips_restore(self):
        temporary, scope, marker, result = self.run_cleanup("identity-error")
        try:
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((scope / "active").exists())
            self.assertFalse(marker.exists())
            self.assertIn("identity probe failed", result.stderr)
            self.assertIn("Skipping media-permission restore", result.stderr)
        finally:
            temporary.cleanup()

    def test_sigkill_fallback_is_never_a_clean_restore_boundary(self):
        temporary, scope, marker, result = self.run_cleanup("kill-fallback")
        try:
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((scope / "active").exists())
            self.assertFalse(marker.exists())
            self.assertIn("required SIGKILL", result.stderr)
            self.assertIn("Preserving fault-proxy registry", result.stderr)
        finally:
            temporary.cleanup()

    def test_restore_failure_is_visible_and_changes_success_to_failure(self):
        temporary, scope, marker, result = self.run_cleanup("restore-failure")
        try:
            self.assertEqual(result.returncode, 1)
            self.assertTrue(marker.exists())
            self.assertIn("restore-visible", result.stdout)
            self.assertIn("cleanup did not complete safely", result.stderr)
            self.assertFalse(scope.exists())
        finally:
            temporary.cleanup()

    def test_existing_runner_failure_status_survives_restore_failure(self):
        temporary, _scope, marker, result = self.run_cleanup(
            "restore-failure",
            23,
        )
        try:
            self.assertEqual(result.returncode, 23)
            self.assertTrue(marker.exists())
            self.assertIn("cleanup did not complete safely", result.stderr)
        finally:
            temporary.cleanup()


class PermissionMutationGuardTests(unittest.TestCase):
    def test_selected_access_with_only_one_full_media_grant_is_refused(self):
        for snapshot in ("0 0 1 0 1", "0 0 0 1 1"):
            with self.subTest(snapshot=snapshot):
                script = r"""
set -euo pipefail
repo_root="$1"
snapshot="$2"
source "${repo_root}/tools/m1-device-smoke-device-control.sh"
media_permission_snapshot() { printf '%s\n' "${snapshot}"; }
fail_with_log() { exit 79; }
media_permission_restore_baseline_captured=0
media_permission_restored=0
capture_media_permission_restore_state
"""
                result = subprocess.run(
                    [
                        "bash",
                        "-c",
                        textwrap.dedent(script),
                        "selected-access-guard",
                        str(ROOT),
                        snapshot,
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 79)

    def test_current_user_switch_refuses_direct_revoke(self):
        with tempfile.TemporaryDirectory(
            prefix="droidmatch-user-switch."
        ) as temporary:
            root = Path(temporary)
            adb_log = root / "adb.log"
            fake_adb = root / "adb"
            fake_adb.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$*\" >>\"${DROIDMATCH_TEST_ADB_LOG}\"\n"
                "case \"$*\" in\n"
                "  *getprop*) printf '34\\n';;\n"
                "  *get-current-user*) printf '10\\n';;\n"
                "esac\n",
                encoding="utf-8",
            )
            fake_adb.chmod(0o700)
            script = r"""
set -euo pipefail
repo_root="$1"
adb_bin="$2"
export DROIDMATCH_TEST_ADB_LOG="$3"
source "${repo_root}/tools/m1-device-smoke-device-control.sh"
serial=offline-switch
sdk_int=34
media_permission_restore_user_id=0
revoke_media_permission_for_captured_user \
  android.permission.READ_MEDIA_IMAGES
"""
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    textwrap.dedent(script),
                    "direct-user-switch",
                    str(ROOT),
                    str(fake_adb),
                    str(adb_log),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 2)
            commands = adb_log.read_text(encoding="utf-8")
            self.assertNotIn("pm revoke", commands)

    def test_first_context_probe_failure_stops_the_direct_revoke_batch(self):
        with tempfile.TemporaryDirectory(
            prefix="droidmatch-revoke-batch."
        ) as temporary:
            attempts = Path(temporary) / "attempts"
            script = r"""
set -euo pipefail
repo_root="$1"
attempts="$2"
source "${repo_root}/tools/m1-device-smoke-device-control.sh"
capture_media_permission_restore_state() {
  media_permission_restore_user_id=0
  media_permission_restore_read_external_storage=0
  media_permission_restore_read_media_images=0
  media_permission_restore_read_media_video=0
  media_permission_restore_read_media_visual_user_selected=0
  media_permission_restore_baseline_captured=1
}
media_permission_snapshot() { printf '0 0 0 0 0\n'; }
media_permission_snapshot_matches_restore_state() { return 0; }
media_permission_snapshot_state_line() { printf 'permission-state'; }
revoke_media_permission_for_captured_user() {
  printf 'attempt\n' >>"${attempts}"
  return 2
}
fail_with_log() { exit 79; }
print_redacted_output() { :; }
sdk_int=34
media_permission_revoked_check=1
media_permission_mutation_output=""
revoke_media_permissions_for_check
"""
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    textwrap.dedent(script),
                    "direct-batch",
                    str(ROOT),
                    str(attempts),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 79)
            self.assertEqual(
                attempts.read_text(encoding="ascii").splitlines(),
                ["attempt"],
            )


PRE_REGISTRATION_IDENTITY = r"""
import os
import signal
import sys
import time
from pathlib import Path

def process_identity(process_id):
    token = f"test-process:{process_id}"
    Path(os.environ["DROIDMATCH_CAPTURE_MARKER"]).write_text(
        "capture-entered\n",
        encoding="ascii",
    )
    os.kill(os.getppid(), signal.SIGTERM)
    time.sleep(0.2)
    os.kill(process_id, 0)
    return token

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
    raise SystemExit(2)

if __name__ == "__main__":
    main()
"""


PRE_REGISTRATION_WRAPPER = r"""
set -euo pipefail
repo_root="$1"
fault_proxy_scope_root="$2"
identity_tool="$3"
fault_proxy_registry_file="${fault_proxy_scope_root}/active"
fault_proxy_shutdown_status_file="${fault_proxy_scope_root}/shutdown-status"
DROIDMATCH_FAULT_PROXY_TEST_MODE=1
DROIDMATCH_TEST_FAULT_PROXY_IDENTITY_TOOL="${identity_tool}"
export DROIDMATCH_FAULT_PROXY_TEST_MODE DROIDMATCH_TEST_FAULT_PROXY_IDENTITY_TOOL
source "${repo_root}/tools/m1-device-smoke-device-control.sh"
source "${repo_root}/tools/m1-device-smoke-cleanup.sh"
print_redacted_output() { :; }
redacted_output() { cat >&2; }
run_swift_harness() { return 0; }
media_permission_revoked_check=0
media_permission_revoked_during_download_check=0
media_permission_restore_baseline_captured=0
media_permission_restored=0
cleanup_upload_destination=0
allocated_local_port=9
adb_bin=/usr/bin/true
serial=offline-test
trap 'cleanup "$?"' EXIT
run_swift_harness_with_fault_proxy pre-registration-probe
"""


class RegistrationBoundaryTests(unittest.TestCase):
    def test_pre_registration_cleanup_has_no_bare_pid_signal_fallback(self):
        source = (
            ROOT / "tools" / "m1-device-smoke-device-control.sh"
        ).read_text(encoding="utf-8")
        unregistered_branch = source.split(
            'elif [[ "${proxy_direct_child_owned}" -eq 1 ]]; then',
            maxsplit=1,
        )[1].split("\n    fi", maxsplit=1)[0]
        self.assertNotIn("kill -", unregistered_branch)

    def test_term_before_registration_is_deferred_until_owned_cleanup(self):
        with tempfile.TemporaryDirectory(
            prefix="droidmatch-pre-registration."
        ) as temporary:
            root = Path(temporary)
            scope = root / "scope"
            scope.mkdir(mode=0o700)
            identity = root / "identity.py"
            marker = root / "capture.marker"
            identity.write_text(
                textwrap.dedent(PRE_REGISTRATION_IDENTITY),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    textwrap.dedent(PRE_REGISTRATION_WRAPPER),
                    "pre-registration-wrapper",
                    str(ROOT),
                    str(scope),
                    str(identity),
                ],
                check=False,
                capture_output=True,
                text=True,
                env={
                    "PATH": "/usr/bin:/bin",
                    "DROIDMATCH_CAPTURE_MARKER": str(marker),
                },
                timeout=10.0,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(marker.exists())
            self.assertFalse(scope.exists(), result.stderr)

    def test_scoped_cleanup_failure_preserves_harness_status(self):
        with tempfile.TemporaryDirectory(
            prefix="droidmatch-scoped-status."
        ) as temporary:
            root = Path(temporary)
            scope = root / "scope"
            scope.mkdir(mode=0o700)
            identity = root / "identity.py"
            identity.write_text(
                r"""
import os
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
        if stat_path.exists() and stat_path.read_text().rsplit(")", 1)[1].split()[0] == "Z":
            raise SystemExit(1)
        os.kill(pid, 0)
        raise SystemExit(0)
    raise SystemExit(2)

if __name__ == "__main__":
    main()
""",
                encoding="utf-8",
            )
            script = r"""
set -euo pipefail
repo_root="$1"
fault_proxy_scope_root="$2"
identity_tool="$3"
fault_proxy_registry_file="${fault_proxy_scope_root}/active"
fault_proxy_shutdown_status_file="${fault_proxy_scope_root}/shutdown-status"
fault_proxy_shutdown_request_file="${fault_proxy_scope_root}/shutdown-request"
DROIDMATCH_FAULT_PROXY_TEST_MODE=1
DROIDMATCH_TEST_FAULT_PROXY_IDENTITY_TOOL="${identity_tool}"
export DROIDMATCH_FAULT_PROXY_TEST_MODE DROIDMATCH_TEST_FAULT_PROXY_IDENTITY_TOOL
source "${repo_root}/tools/m1-device-smoke-device-control.sh"
print_redacted_output() { :; }
redacted_output() { cat >/dev/null; }
run_swift_harness() { return 23; }
request_fault_proxy_shutdown() { return 1; }
allocated_local_port=9
set +e
run_swift_harness_with_fault_proxy scoped-status
status=$?
set -e
exit "${status}"
"""
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    textwrap.dedent(script),
                    "scoped-status",
                    str(ROOT),
                    str(scope),
                    str(identity),
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=10.0,
            )
            self.assertEqual(result.returncode, 23, result.stderr)
            registry = scope / "active"
            self.assertTrue(registry.exists())
            proxy_pid = int(
                registry.read_text(encoding="ascii").split(maxsplit=1)[0]
            )
            try:
                os.kill(proxy_pid, 9)
            except ProcessLookupError:
                pass


class GeneratedPermissionHookTests(unittest.TestCase):
    def test_api33_hook_never_operates_visual_selected_permission(self):
        with tempfile.TemporaryDirectory(
            prefix="droidmatch-api33-hook."
        ) as temporary:
            root = Path(temporary)
            adb_log = root / "adb.log"
            fake_adb = root / "adb"
            fake_adb.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$*\" >>\"${DROIDMATCH_TEST_ADB_LOG}\"\n"
                "case \"$*\" in\n"
                "  *getprop*) printf '%s\\n' \"${DROIDMATCH_TEST_SDK:-33}\";;\n"
                "  *get-current-user*) printf '%s\\n' \"${DROIDMATCH_TEST_USER:-0}\";;\n"
                "esac\n",
                encoding="utf-8",
            )
            fake_adb.chmod(0o700)
            script = r"""
set -euo pipefail
repo_root="$1"
adb_bin="$2"
export DROIDMATCH_TEST_ADB_LOG="$3"
source "${repo_root}/tools/m1-device-smoke-device-control.sh"
capture_media_permission_restore_state() { media_permission_restore_user_id=0; }
media_permission_snapshot() { printf '0 0 0 0 0\n'; }
media_permission_snapshot_matches_restore_state() { return 0; }
media_permission_snapshot_state_line() { printf 'permission-state'; }
media_permission_revoked_during_download_check=1
media_permission_revoke_hook_script=""
serial=offline-api33
sdk_int=33
prepare_media_permission_revoke_during_download_check
bash "${media_permission_revoke_hook_script}"
rm -f "${media_permission_revoke_hook_script}"
"""
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    textwrap.dedent(script),
                    "api33-hook",
                    str(ROOT),
                    str(fake_adb),
                    str(adb_log),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            commands = adb_log.read_text(encoding="utf-8")
            self.assertIn("READ_MEDIA_IMAGES", commands)
            self.assertIn("READ_MEDIA_VIDEO", commands)
            self.assertNotIn("READ_MEDIA_VISUAL_USER_SELECTED", commands)

    def test_hook_context_drift_refuses_every_permission_mutation(self):
        for sdk, user in (("garbage", "0"), ("33", "10")):
            with self.subTest(sdk=sdk, user=user), tempfile.TemporaryDirectory(
                prefix="droidmatch-hook-context."
            ) as temporary:
                root = Path(temporary)
                adb_log = root / "adb.log"
                fake_adb = root / "adb"
                fake_adb.write_text(
                    "#!/usr/bin/env bash\n"
                    "printf '%s\\n' \"$*\" >>\"${DROIDMATCH_TEST_ADB_LOG}\"\n"
                    "case \"$*\" in\n"
                    "  *getprop*) printf '%s\\n' \"${DROIDMATCH_TEST_SDK}\";;\n"
                    "  *get-current-user*) printf '%s\\n' \"${DROIDMATCH_TEST_USER}\";;\n"
                    "esac\n",
                    encoding="utf-8",
                )
                fake_adb.chmod(0o700)
                script = r"""
set -euo pipefail
repo_root="$1"
adb_bin="$2"
export DROIDMATCH_TEST_ADB_LOG="$3"
source "${repo_root}/tools/m1-device-smoke-device-control.sh"
capture_media_permission_restore_state() { media_permission_restore_user_id=0; }
media_permission_snapshot() { printf '0 0 0 0 0\n'; }
media_permission_snapshot_matches_restore_state() { return 0; }
media_permission_snapshot_state_line() { printf 'permission-state'; }
media_permission_revoked_during_download_check=1
media_permission_revoke_hook_script=""
serial=offline-context
sdk_int=33
prepare_media_permission_revoke_during_download_check
: >"${DROIDMATCH_TEST_ADB_LOG}"
bash "${media_permission_revoke_hook_script}"
"""
                result = subprocess.run(
                    [
                        "bash",
                        "-c",
                        textwrap.dedent(script),
                        "hook-context",
                        str(ROOT),
                        str(fake_adb),
                        str(adb_log),
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                    env={
                        "PATH": "/usr/bin:/bin",
                        "DROIDMATCH_TEST_ADB_LOG": str(adb_log),
                        "DROIDMATCH_TEST_SDK": sdk,
                        "DROIDMATCH_TEST_USER": user,
                    },
                )
                self.assertNotEqual(result.returncode, 0)
                commands = adb_log.read_text(encoding="utf-8")
                self.assertNotIn("pm revoke", commands)


if __name__ == "__main__":
    unittest.main()
