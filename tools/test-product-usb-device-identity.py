#!/usr/bin/env python3
"""Focused offline checks for product USB selected-device binding."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import signal
import subprocess
import sys
sys.dont_write_bytecode = True

import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import product_usb_adb_identity as adb_identity


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools" / "product-usb-device-identity.py"
SPEC = importlib.util.spec_from_file_location("product_usb_device_identity", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load product USB identity helper")
identity = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = identity
SPEC.loader.exec_module(identity)


class ProductUsbDeviceIdentityTests(unittest.TestCase):
    selected_serial = "TEST-SERIAL-123"

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.work = Path(self.temporary.name)
        self.devices = self.work / "devices.txt"
        self.adb = self.work / "adb"
        self.adb.write_text(
            """#!/usr/bin/env python3
import os
import pathlib
import sys

arguments = sys.argv[1:]
if len(arguments) >= 4 and arguments[:3] == ["-H", "127.0.0.1", "-P"]:
    if arguments[3] != "47137":
        raise SystemExit(5)
    arguments = arguments[4:]
if arguments == ["version"]:
    print("Android Debug Bridge version 1.0.41")
    print("Version 37.0.0-14910828")
    raise SystemExit(0)
if arguments == ["devices", "-l"]:
    sys.stdout.write(pathlib.Path(os.environ["FAKE_ADB_DEVICES"]).read_text())
    raise SystemExit(0)
if len(arguments) == 5 and arguments[0] == "-s" and arguments[2:4] == ["shell", "getprop"]:
    values = {
        "ro.product.manufacturer": os.environ.get("FAKE_MANUFACTURER", "meizu"),
        "ro.product.model": os.environ.get("FAKE_MODEL", "MEIZU M20"),
        "ro.build.version.sdk": os.environ.get("FAKE_API", "34"),
    }
    value = values.get(arguments[4])
    if value is None:
        raise SystemExit(4)
    print(value)
    raise SystemExit(0)
raise SystemExit(3)
""",
            encoding="utf-8",
        )
        self.adb.chmod(0o700)
        self.environment = {
            "FAKE_ADB_DEVICES": str(self.devices),
            "FAKE_MANUFACTURER": "meizu",
            "FAKE_MODEL": "MEIZU M20",
            "FAKE_API": "34",
        }
        self.previous_tool_environment = identity.CREDENTIAL_FREE_TOOL_ENVIRONMENT
        self.tool_environment = {
            **identity.CREDENTIAL_FREE_TOOL_ENVIRONMENT,
            **self.environment,
        }
        identity.CREDENTIAL_FREE_TOOL_ENVIRONMENT = self.tool_environment
        self.profile = identity.SelectedDevice(
            "C",
            identity.serial_tag(self.selected_serial),
            "meizu",
            "MEIZU M20",
            34,
            "MEIZU M20",
        )
        self.baseline = self.work / "baseline.json"

    def tearDown(self) -> None:
        identity.CREDENTIAL_FREE_TOOL_ENVIRONMENT = self.previous_tool_environment
        self.temporary.cleanup()

    def write_devices(self, *lines: str) -> None:
        self.devices.write_text(
            "List of devices attached\n" + "\n".join(lines) + "\n",
            encoding="utf-8",
        )

    def capture_baseline(self) -> None:
        self.write_devices(
            "OTHER-DEVICE device product:other model:Other device:other transport_id:1"
        )
        identity.capture_snapshot(str(self.adb), self.selected_serial, self.baseline, None)
        self.assertNotIn("OTHER-DEVICE", self.baseline.read_text(encoding="utf-8"))

    def insert_selected(self, *extra: str) -> None:
        self.write_devices(
            "OTHER-DEVICE device product:other model:Other device:other transport_id:1",
            f"{self.selected_serial} device product:m20 model:MEIZU_M20 device:m20 transport_id:2",
            *extra,
        )

    def test_reviewed_registry_is_exact_and_unique(self) -> None:
        profiles = identity.load_registry()
        self.assertEqual(set(profiles), {"A", "C", "D"})
        self.assertEqual(
            [
                (
                    value.slot,
                    value.identity_tag,
                    value.manufacturer,
                    value.model,
                    value.android_api,
                    value.visible_label,
                )
                for value in profiles.values()
            ],
            [
                ("A", "06585bc3bf1b828c34d82c8fde7004dd", "SHARP", "704SH", 26, "704SH"),
                ("C", "afcb4a28955e2f3d258e9ca0665d69d7", "meizu", "MEIZU M20", 34, "MEIZU M20"),
                ("D", "58e1aad179084f5488c58ed4c0e911db", "NIO", "N2301", 34, "N2301"),
            ],
        )
        toolchain = identity.load_adb_registry()
        self.assertEqual(toolchain.profile, "m1-product-usb-adb-v2")
        self.assertEqual(toolchain.platform, "darwin-universal")
        self.assertEqual(
            toolchain.sha256,
            "590c2ccff50469d04a94bab72a842c2c81ae4e21d66a9253696d32debb702c0e",
        )
        self.assertEqual((toolchain.version, toolchain.build), ("37.0.0", "14910828"))
        self.assertEqual(toolchain.server_socket, "tcp:localhost:47137")
        self.assertEqual(
            toolchain.code_directory_hashes,
            (
                "4dfbeed75348f21bd026c3ea5d9f03c5348fb558",
                "6af23bdf2d379f6bc270363e780c2f56f6c8d50a",
            ),
        )
        self.assertEqual(
            toolchain.source_archive_url,
            "https://dl.google.com/android/repository/platform-tools_r37.0.0-darwin.zip",
        )
        self.assertEqual(
            toolchain.source_archive_sha256,
            "094a1395683c509fd4d48667da0d8b5ef4d42b2abfcd29f2e8149e2f989357c7",
        )
        self.assertEqual(
            toolchain.source_executable_sha256,
            "9fdf861259dc807937b13afdd5f053c7fda9f3b7726933fe0e0f45130ecb8dc7",
        )
        legacy = json.loads(
            (ROOT / "tools" / "product-usb-adb-v1.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            legacy,
            {
                "schemaVersion": 1,
                "profile": "m1-product-usb-adb-v1",
                "platform": "darwin-universal",
                "signedExecutableSha256":
                    "2fd1ef8d9be308d3979e11a415e2a4eab3a91102e911932a45ce552d645aaa30",
                "version": "37.0.0",
                "build": "14910828",
                "serverSocket": "tcp:localhost:47137",
                "codeDirectoryHashes": [
                    "4dfbeed75348f21bd026c3ea5d9f03c5348fb558",
                    "6af23bdf2d379f6bc270363e780c2f56f6c8d50a",
                ],
            },
        )
        workflow = (ROOT / ".github" / "workflows" / "m0.yml").read_text(
            encoding="utf-8"
        )
        for reviewed_value in (
            toolchain.source_archive_url,
            toolchain.source_archive_sha256,
            toolchain.source_executable_sha256,
        ):
            self.assertIn(reviewed_value, workflow)
        self.assertNotIn('sdkmanager "platform-tools"', workflow)
        self.assertEqual(
            identity._remote_server_arguments(toolchain.server_socket),
            ["-H", "127.0.0.1", "-P", "47137"],
        )
        with self.assertRaises(identity.IdentityError):
            identity._remote_server_arguments("tcp:localhost:5037")
        malformed_registry = self.work / "malformed-registry.json"
        malformed_payload = json.loads(identity.REGISTRY_PATH.read_text(encoding="utf-8"))
        malformed_payload["devices"][0]["slot"] = []
        malformed_registry.write_text(json.dumps(malformed_payload), encoding="utf-8")
        with self.assertRaises(identity.IdentityError):
            identity.load_registry(malformed_registry)

        fake_toolchain = identity.AdbToolchain(
            toolchain.profile,
            toolchain.platform,
            hashlib.sha256(self.adb.read_bytes()).hexdigest(),
            toolchain.version,
            toolchain.build,
            toolchain.server_socket,
            toolchain.code_directory_hashes,
            toolchain.source_archive_url,
            toolchain.source_archive_sha256,
            toolchain.source_executable_sha256,
        )
        private_workspace = self.work / "private-adb"
        private_workspace.mkdir(mode=0o700)
        with mock.patch.object(identity, "_verify_adb_code_directories"):
            source_adb, private_adb = identity._prepare_private_adb(
                str(self.adb.resolve()), fake_toolchain, private_workspace,
                private_workspace,
            )
        self.assertEqual(source_adb, str(self.adb.resolve()))
        self.assertNotEqual(private_adb, source_adb)
        self.assertEqual(Path(private_adb).read_bytes(), self.adb.read_bytes())
        self.assertEqual(Path(private_adb).stat().st_mode & 0o777, 0o700)
        static_options = identity.argparse.Namespace(
            command="toolchain",
            adb=None,
            adb_executable=str(self.adb.resolve()),
            static_only=True,
        )
        static_output = io.StringIO()
        with mock.patch.object(identity, "load_adb_registry", return_value=fake_toolchain), \
             mock.patch.object(identity, "_verify_adb_code_directories"), \
             contextlib.redirect_stdout(static_output):
            identity._run_adb_operation(static_options, {})
        self.assertIn(
            f"adb_registry_profile={fake_toolchain.profile}", static_output.getvalue()
        )

        lsof_output = b"p12345\ncadb\nf17\nn127.0.0.1:47137\n"
        self.assertEqual(adb_identity._listener_pid(toolchain, lambda *args, **kwargs: lsof_output), 12345)
        ambiguous = lsof_output + b"p12346\ncadb\nf18\nn127.0.0.1:47137\n"
        with self.assertRaises(identity.IdentityError):
            adb_identity._listener_pid(toolchain, lambda *args, **kwargs: ambiguous)

        source_status = self.adb.stat()
        instance = (
            "darwin:00000000-0000-0000-0000-000000000000:"
            f"{os.geteuid()}:1:2"
        )
        code_identity = (
            adb_identity.CS_VALID | adb_identity.CS_RUNTIME,
            toolchain.code_directory_hashes[0],
        )
        with mock.patch.object(adb_identity, "_listener_pid", return_value=12345), \
             mock.patch.object(adb_identity, "_process_instance_identity", return_value=instance), \
             mock.patch.object(adb_identity, "_listener_process_path", return_value=self.adb.resolve()), \
             mock.patch.object(
                 adb_identity,
                 "_listener_mapped_executable_identity",
                 return_value=(source_status.st_dev, source_status.st_ino),
             ), \
             mock.patch.object(adb_identity, "_process_code_identity", return_value=code_identity):
            server = adb_identity.verify_product_adb_server(
                str(self.adb.resolve()), fake_toolchain, lambda *args, **kwargs: b""
            )
        self.assertEqual(
            server,
            adb_identity.VerifiedAdbServer(
                str(self.adb.resolve()), fake_toolchain, 12345, instance, code_identity[1]
            ),
        )

        with mock.patch.object(adb_identity, "_listener_pid", return_value=12345), \
             mock.patch.object(adb_identity, "_process_instance_identity", return_value=instance), \
             mock.patch.object(adb_identity, "_listener_process_path", return_value=self.adb.resolve()), \
             mock.patch.object(
                 adb_identity,
                 "_listener_mapped_executable_identity",
                 return_value=(source_status.st_dev, source_status.st_ino + 1),
             ), \
             mock.patch.object(adb_identity, "_process_code_identity", return_value=code_identity):
            with self.assertRaises(identity.IdentityError):
                adb_identity.verify_product_adb_server(
                    str(self.adb.resolve()), fake_toolchain, lambda *args, **kwargs: b""
                )

        refusal_cases = (
            (
                "changed process instance",
                [12345, 12345],
                [instance, f"{instance}:changed"],
                [code_identity, code_identity],
            ),
            (
                "different effective user",
                [12345, 12345],
                [
                    "darwin:00000000-0000-0000-0000-000000000000:"
                    f"{os.geteuid() + 1}:1:2"
                ] * 2,
                [code_identity, code_identity],
            ),
            (
                "changed listener pid",
                [12345, 12346],
                [instance, instance],
                [code_identity, code_identity],
            ),
            (
                "unknown code directory",
                [12345, 12345],
                [instance, instance],
                [(code_identity[0], "0" * 40)] * 2,
            ),
            (
                "missing runtime flag",
                [12345, 12345],
                [instance, instance],
                [(adb_identity.CS_VALID, code_identity[1])] * 2,
            ),
            (
                "debugged process",
                [12345, 12345],
                [instance, instance],
                [(code_identity[0] | adb_identity.CS_DEBUGGED, code_identity[1])] * 2,
            ),
        )
        for name, process_ids, instances, code_identities in refusal_cases:
            with self.subTest(name=name), \
                 mock.patch.object(adb_identity, "_listener_pid", side_effect=process_ids), \
                 mock.patch.object(
                     adb_identity, "_process_instance_identity", side_effect=instances
                 ), \
                 mock.patch.object(
                     adb_identity, "_listener_process_path", return_value=self.adb.resolve()
                 ), \
                 mock.patch.object(
                     adb_identity,
                     "_listener_mapped_executable_identity",
                     return_value=(source_status.st_dev, source_status.st_ino),
                 ), \
                 mock.patch.object(
                     adb_identity, "_process_code_identity", side_effect=code_identities
                 ):
                with self.assertRaises(identity.IdentityError):
                    adb_identity.verify_product_adb_server(
                        str(self.adb.resolve()),
                        fake_toolchain,
                        lambda *args, **kwargs: b"",
                    )

        with mock.patch.object(identity, "load_adb_registry", return_value=fake_toolchain):
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout), \
                 mock.patch.object(identity, "_verify_adb_code_directories"):
                status = identity.main(
                    ["toolchain", "--adb-executable", str(self.adb.resolve())]
                )
        self.assertEqual(status, 0)
        self.assertNotIn("adb_server_pid=", stdout.getvalue())
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(identity.main(["toolchain", "--static-only"]), 1)
            self.assertEqual(
                identity.main(["toolchain", "--adb", str(self.adb), "--static-only"]),
                1,
            )

        private_home = self.work / "credential-free-home"
        private_home.mkdir(mode=0o700)
        with mock.patch.dict(os.environ, {"DROIDMATCH_TEST_SECRET": "must-not-pass"}):
            child_environment = identity._run_bounded(
                [
                    sys.executable,
                    "-c",
                    (
                        "import os,stat;"
                        "home=os.environ['HOME'];"
                        "print('present' if 'DROIDMATCH_TEST_SECRET' in os.environ else 'absent',"
                        "stat.S_IMODE(os.stat(home).st_mode)==0o700,"
                        "home==os.environ['TMPDIR'],home.startswith('/Users/'))"
                    ),
                ],
                home_directory=private_home,
            )
        self.assertEqual(child_environment, b"absent True True False\n")


    def test_capture_requires_absence_and_unchanged_pre_signal_inventory(self) -> None:
        self.capture_baseline()
        second = self.work / "pre-signal.json"
        identity.capture_snapshot(
            str(self.adb), self.selected_serial, second, self.baseline
        )
        self.assertEqual(identity.read_snapshot(second), identity.read_snapshot(self.baseline))

        self.write_devices(
            "OTHER-DEVICE device product:other model:Other device:other transport_id:9"
        )
        with self.assertRaises(identity.IdentityError):
            identity.capture_snapshot(
                str(self.adb),
                self.selected_serial,
                self.work / "reconnected.json",
                self.baseline,
            )

        self.write_devices(
            "OTHER-DEVICE device product:other model:Other device:other transport_id:1",
            "UNRELATED device product:new model:New device:new transport_id:3",
        )
        with self.assertRaises(identity.IdentityError):
            identity.capture_snapshot(
                str(self.adb), self.selected_serial, self.work / "changed.json", self.baseline
            )

        self.insert_selected()
        with self.assertRaises(identity.IdentityError):
            identity.capture_snapshot(
                str(self.adb), self.selected_serial, self.work / "present.json", None
            )

    def test_verify_binds_unique_delta_model_properties_and_redacted_tag(self) -> None:
        self.capture_baseline()
        self.insert_selected()
        values = identity.verify_insertion(
            str(self.adb), self.profile, self.selected_serial, self.baseline
        )
        self.assertEqual(values["identity_tag"], self.profile.identity_tag)
        self.assertEqual(values["visible_label"], "MEIZU M20")
        self.assertEqual(values["adb_identity_verified"], "true")
        self.assertEqual(values["adb_insertion_delta_verified"], "true")
        self.assertNotIn(self.selected_serial, "\n".join(values.values()))

    def test_verify_rejects_relabelled_slot_wrong_api_and_unrelated_delta(self) -> None:
        self.capture_baseline()
        self.insert_selected()
        wrong_slot = identity.SelectedDevice(
            "A", "0" * 32, "SHARP", "704SH", 26, "704SH"
        )
        with self.assertRaises(identity.IdentityError):
            identity.verify_insertion(
                str(self.adb), wrong_slot, self.selected_serial, self.baseline
            )

        self.tool_environment["FAKE_API"] = "26"
        with self.assertRaises(identity.IdentityError):
            identity.verify_insertion(
                str(self.adb), self.profile, self.selected_serial, self.baseline
            )
        self.tool_environment["FAKE_API"] = "34"

        self.insert_selected(
            "UNRELATED device product:new model:New device:new transport_id:3"
        )
        with self.assertRaises(identity.IdentityError):
            identity.verify_insertion(
                str(self.adb), self.profile, self.selected_serial, self.baseline
            )

    def test_bounded_inventory_and_snapshot_inputs_fail_closed(self) -> None:
        oversized_snapshot = self.work / "oversized.json"
        oversized_snapshot.write_bytes(b"[" + b" " * identity.MAX_SNAPSHOT_BYTES + b"]")
        with self.assertRaises(identity.IdentityError):
            identity.read_snapshot(oversized_snapshot)

        malformed_snapshot = self.work / "malformed.json"
        malformed_snapshot.write_text(
            '[{"serial":"abcdef","state":[],"product":null,"model":null,'
            '"device":null,"transport_id":null}]',
            encoding="utf-8",
        )
        with self.assertRaises(identity.IdentityError):
            identity.read_snapshot(malformed_snapshot)

        self.devices.write_bytes(b"x" * (identity.MAX_ADB_OUTPUT_BYTES + 1))
        with self.assertRaises(identity.IdentityError):
            identity.read_adb_devices(str(self.adb))

        too_many = "List of devices attached\n" + "\n".join(
            f"DEV-{index:03d} device" for index in range(identity.MAX_DEVICES + 1)
        )
        with self.assertRaises(identity.IdentityError):
            identity.parse_adb_devices(too_many.encode("utf-8"))

        fifo = self.work / "snapshot.fifo"
        os.mkfifo(fifo)
        probe = subprocess.run(
            [
                sys.executable,
                "-c",
                (
                    "import importlib.util,sys;"
                    "sys.path.insert(0,str(__import__('pathlib').Path(sys.argv[1]).parent));"
                    "spec=importlib.util.spec_from_file_location('identity',sys.argv[1]);"
                    "module=importlib.util.module_from_spec(spec);"
                    "sys.modules[spec.name]=module;spec.loader.exec_module(module);"
                    "module.read_snapshot(module.Path(sys.argv[2]))"
                ),
                str(MODULE_PATH),
                str(fifo),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=2,
        )
        self.assertNotEqual(probe.returncode, 0)

    def test_timeout_cleans_descendant_that_outlives_command_leader(self) -> None:
        marker = self.work / "descendant.pid"
        previous_timeout = identity.ADB_TIMEOUT_SECONDS
        identity.ADB_TIMEOUT_SECONDS = 0.3
        try:
            with self.assertRaises(identity.IdentityError):
                identity._run_bounded(
                    [
                        "/bin/sh",
                        "-c",
                        "(trap '' TERM; exec /bin/sleep 30) & "
                        "printf '%s\\n' $! >\"$DESCENDANT_MARKER\"",
                    ],
                    environment={
                        **identity.CREDENTIAL_FREE_TOOL_ENVIRONMENT,
                        "DESCENDANT_MARKER": str(marker),
                    },
                )
        finally:
            identity.ADB_TIMEOUT_SECONDS = previous_timeout

        descendant_pid = int(marker.read_text(encoding="utf-8"))
        deadline = time.monotonic() + 2.0
        while True:
            try:
                os.kill(descendant_pid, 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= deadline:
                os.kill(descendant_pid, signal.SIGKILL)
                self.fail("ADB identity timeout left a descendant running")
            time.sleep(0.02)

    def test_nonzero_command_cleans_descendant_with_closed_output(self) -> None:
        marker = self.work / "nonzero-descendant.pid"
        with self.assertRaises(identity.IdentityError):
            identity._run_bounded(
                [
                    "/bin/sh",
                    "-c",
                    "(trap '' TERM; exec /bin/sleep 30) >/dev/null 2>&1 & "
                    "printf '%s\\n' $! >\"$DESCENDANT_MARKER\"; exit 7",
                ],
                environment={
                    **identity.CREDENTIAL_FREE_TOOL_ENVIRONMENT,
                    "DESCENDANT_MARKER": str(marker),
                },
            )

        descendant_pid = int(marker.read_text(encoding="utf-8"))
        with self.assertRaises(ProcessLookupError):
            os.kill(descendant_pid, 0)

    def test_supervisor_anchors_process_group_between_term_and_kill(self) -> None:
        marker = self.work / "supervised-command-ready"
        status_read, status_write = os.pipe()
        liveness_read, liveness_write = os.pipe()
        supervisor = subprocess.Popen(
            [
                sys.executable,
                str(MODULE_PATH),
                "__supervise",
                str(status_write),
                str(liveness_read),
                "discard",
                "/bin/sh",
                "-c",
                'printf ready >"$READY_MARKER"; exec /bin/sleep 30',
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            pass_fds=(status_write, liveness_read),
            env={
                **identity._credential_free_environment(self.work),
                "READY_MARKER": str(marker),
            },
        )
        os.close(status_write)
        os.close(liveness_read)
        os.set_blocking(status_read, False)
        survived_term = False
        try:
            deadline = time.monotonic() + 2.0
            while not marker.is_file():
                if supervisor.poll() is not None:
                    self.fail("ADB identity supervisor exited before its command was ready")
                if time.monotonic() >= deadline:
                    self.fail("ADB identity supervised command did not become ready")
                time.sleep(0.02)

            os.killpg(supervisor.pid, signal.SIGTERM)
            status_payload = bytearray()
            deadline = time.monotonic() + 2.0
            while b"\n" not in status_payload:
                try:
                    status_payload.extend(os.read(status_read, 32))
                except BlockingIOError:
                    pass
                if time.monotonic() >= deadline:
                    self.fail("ADB identity supervisor did not report TERM completion")
                time.sleep(0.02)
            survived_term = supervisor.poll() is None
            self.assertEqual(bytes(status_payload), b"-15\n")
            self.assertTrue(survived_term)
        finally:
            os.close(status_read)
            if survived_term and supervisor.poll() is None:
                try:
                    os.killpg(supervisor.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if supervisor.poll() is None:
                supervisor.kill()
            supervisor.wait(timeout=2.0)
            os.close(liveness_write)

    def test_parent_hard_kill_cleans_supervised_process_group(self) -> None:
        marker = self.work / "hard-kill-group.txt"
        child_code = (
            "import os,pathlib,sys,time;"
            "pathlib.Path(sys.argv[1]).write_text("
            "f'{os.getpid()} {os.getpgrp()}\\n',encoding='utf-8');"
            "time.sleep(30)"
        )
        probe_code = (
            "import importlib.util,sys;"
            "sys.path.insert(0,str(__import__('pathlib').Path(sys.argv[1]).parent));"
            "spec=importlib.util.spec_from_file_location('identity',sys.argv[1]);"
            "module=importlib.util.module_from_spec(spec);"
            "sys.modules[spec.name]=module;spec.loader.exec_module(module);"
            "module._run_bounded([sys.executable,'-c',sys.argv[3],sys.argv[2]])"
        )
        probe = subprocess.Popen(
            [
                sys.executable,
                "-c",
                probe_code,
                str(MODULE_PATH),
                str(marker),
                child_code,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        group_id: int | None = None
        try:
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline:
                if marker.is_file() and marker.stat().st_size > 0:
                    break
                if probe.poll() is not None:
                    self.fail("ADB identity parent exited before the hard-kill probe was ready")
                time.sleep(0.02)
            else:
                self.fail("ADB identity hard-kill probe did not become ready")

            child_pid, group_id = [
                int(value) for value in marker.read_text(encoding="utf-8").split()
            ]
            self.assertNotEqual(group_id, os.getpgrp())
            self.assertNotEqual(child_pid, group_id)
            os.kill(probe.pid, signal.SIGKILL)
            probe.wait(timeout=2.0)

            deadline = time.monotonic() + 2.0
            while True:
                try:
                    os.killpg(group_id, 0)
                except ProcessLookupError:
                    break
                except PermissionError:
                    process_table = subprocess.run(
                        ["/bin/ps", "-axo", "pgid=,stat="],
                        check=True,
                        capture_output=True,
                        text=True,
                    ).stdout.splitlines()
                    states = [
                        fields[1]
                        for line in process_table
                        if len(fields := line.split()) == 2
                        and fields[0] == str(group_id)
                    ]
                    if not states or all(value.startswith("Z") for value in states):
                        break
                if time.monotonic() >= deadline:
                    self.fail("hard-killed ADB identity parent left its process group running")
                time.sleep(0.02)
        finally:
            if probe.poll() is None:
                probe.kill()
                probe.wait(timeout=2.0)
            if group_id is not None:
                try:
                    os.killpg(group_id, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass

    def test_cli_refusal_does_not_echo_raw_serial(self) -> None:
        self.capture_baseline()
        self.insert_selected()
        registry = self.work / "registry.json"
        registry.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "profile": identity.REGISTRY_PROFILE,
                    "devices": [
                        {
                            "slot": "A",
                            "identityTag": "00000000000000000000000000000000",
                            "manufacturer": "SHARP",
                            "model": "704SH",
                            "androidApi": 26,
                            "visibleLabel": "704SH",
                        },
                        {
                            "slot": "C",
                            "identityTag": "11111111111111111111111111111111",
                            "manufacturer": "meizu",
                            "model": "MEIZU M20",
                            "androidApi": 34,
                            "visibleLabel": "MEIZU M20",
                        },
                        {
                            "slot": "D",
                            "identityTag": "22222222222222222222222222222222",
                            "manufacturer": "NIO",
                            "model": "N2301",
                            "androidApi": 34,
                            "visibleLabel": "N2301",
                        },
                    ],
                }
            ),
            encoding="utf-8",
        )
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            status = identity.main(
                [
                    "verify",
                    "--adb",
                    str(self.adb),
                    "--slot",
                    "C",
                    "--selected-serial",
                    self.selected_serial,
                    "--before",
                    str(self.baseline),
                ],
                registry_path=registry,
            )
        self.assertEqual(status, 1)
        self.assertNotIn(self.selected_serial, stderr.getvalue())

        parser_probe = subprocess.run(
            [sys.executable, str(MODULE_PATH), "--unexpected", self.selected_serial],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(parser_probe.returncode, 0)
        self.assertNotIn(self.selected_serial, parser_probe.stderr)


if __name__ == "__main__":
    unittest.main()
