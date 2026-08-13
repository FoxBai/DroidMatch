#!/usr/bin/env python3
"""Bind attended product-USB evidence to one reviewed physical device."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import re
import selectors
import shutil
import signal
import subprocess
import sys
sys.dont_write_bytecode = True

import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from product_usb_adb_identity import VerifiedAdbServer, verify_product_adb_server
from product_usb_registry import (
    REGISTRY_PATH,
    REGISTRY_PROFILE,
    SAFE_ADB_VALUE,
    AdbToolchain,
    IdentityError,
    SelectedDevice,
    load_adb_registry,
    load_registry,
    read_regular_bounded,
    reviewed_adb_payload,
    write_private_adb,
)

MAX_ADB_OUTPUT_BYTES = 1024 * 1024
MAX_SNAPSHOT_BYTES = 1024 * 1024
MAX_DEVICES = 32
MAX_ADB_EXECUTABLE_BYTES = 64 * 1024 * 1024
ADB_TIMEOUT_SECONDS = 5.0
CREDENTIAL_FREE_TOOL_ENVIRONMENT = {
    "PATH": "/usr/bin:/bin",
    "LANG": "C",
    "LC_ALL": "C",
}
SAFE_SERIAL = re.compile(r"[A-Za-z0-9._:-]{6,256}")
KNOWN_STATES = {
    "device",
    "offline",
    "unauthorized",
    "recovery",
    "sideload",
    "bootloader",
    "host",
}


@dataclass(frozen=True)
class AdbDevice:
    serial: str
    state: str
    product: str | None
    model: str | None
    device: str | None
    transport_id: str | None

    def as_json(self) -> dict[str, Any]:
        return {
            "serial": self.serial,
            "state": self.state,
            "product": self.product,
            "model": self.model,
            "device": self.device,
            "transport_id": self.transport_id,
        }


def serial_tag(serial: str) -> str:
    return hashlib.sha256(serial.encode("utf-8")).hexdigest()[:32]


def _terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    group_id = process.pid
    try:
        os.killpg(group_id, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        process.wait(timeout=0.2)
    except subprocess.TimeoutExpired:
        # The still-waitable supervisor remains the instance anchor for PGID.
        try:
            os.killpg(group_id, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    try:
        process.wait(timeout=1.0)
    except subprocess.TimeoutExpired:
        raise IdentityError("an ADB identity query process group could not be cleaned up") from None

    deadline = time.monotonic() + 1.0
    while True:
        try:
            os.killpg(group_id, 0)
        except ProcessLookupError:
            return
        except PermissionError:
            pass
        if time.monotonic() >= deadline:
            raise IdentityError("an ADB identity query process group could not be cleaned up")
        time.sleep(0.02)


def _kill_group_when_parent_exits(liveness_descriptor: int) -> None:
    try:
        while True:
            try:
                payload = os.read(liveness_descriptor, 1)
            except InterruptedError:
                continue
            if not payload:
                break
    except OSError:
        pass
    finally:
        try:
            os.close(liveness_descriptor)
        except OSError:
            pass
    try:
        os.killpg(os.getpgrp(), signal.SIGKILL)
    except OSError:
        os._exit(125)


def _supervise_command(
    status_descriptor: int,
    liveness_descriptor: int,
    merge_standard_error: bool,
    command: list[str],
) -> int:
    # Keep the owned PGID anchored until the parent sends its final SIGKILL.
    # An execed command resets this caught disposition and still receives TERM.
    signal.signal(signal.SIGTERM, lambda _number, _frame: None)
    threading.Thread(
        target=_kill_group_when_parent_exits,
        args=(liveness_descriptor,),
        daemon=True,
    ).start()
    try:
        child = subprocess.Popen(
            command,
            stderr=subprocess.STDOUT if merge_standard_error else None,
        )
        os.close(sys.stdout.fileno())
        status = child.wait()
    except (OSError, subprocess.SubprocessError):
        try:
            os.close(sys.stdout.fileno())
        except OSError:
            pass
        status = 127
    try:
        os.write(status_descriptor, f"{status}\n".encode("ascii"))
    except OSError:
        return 125
    finally:
        try:
            os.close(status_descriptor)
        except OSError:
            pass
    while True:
        signal.pause()


def _credential_free_environment(
    home_directory: Path | None = None,
    extra: dict[str, str] | None = None,
) -> dict[str, str]:
    values = dict(CREDENTIAL_FREE_TOOL_ENVIRONMENT)
    if extra:
        values.update(extra)
    credential_free_home = home_directory or Path("/var/empty")
    values["HOME"] = str(credential_free_home)
    values["TMPDIR"] = str(credential_free_home)
    return values


def _create_private_workspace() -> Path:
    parent = "/private/tmp" if sys.platform == "darwin" else "/tmp"
    try:
        workspace = Path(tempfile.mkdtemp(prefix="droidmatch-usb-identity-", dir=parent))
        workspace.chmod(0o700)
        return workspace
    except OSError:
        raise IdentityError("a private ADB identity workspace could not be created") from None


def _run_bounded(
    command: list[str],
    maximum: int = MAX_ADB_OUTPUT_BYTES,
    environment: dict[str, str] | None = None,
    merge_standard_error: bool = False,
    home_directory: Path | None = None,
) -> bytes:
    process: subprocess.Popen[bytes] | None = None
    status_read = -1
    status_write = -1
    liveness_read = -1
    liveness_write = -1
    failure: IdentityError | None = None
    cleanup_failure: IdentityError | None = None
    payload = bytearray()
    status_payload = bytearray()
    selector = selectors.DefaultSelector()
    try:
        status_read, status_write = os.pipe()
        liveness_read, liveness_write = os.pipe()
        process = subprocess.Popen(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "__supervise",
                str(status_write),
                str(liveness_read),
                "merge" if merge_standard_error else "discard",
                *command,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            pass_fds=(status_write, liveness_read),
            env=_credential_free_environment(home_directory, environment),
        )
        os.close(status_write)
        status_write = -1
        os.close(liveness_read)
        liveness_read = -1
        if process.stdout is None:
            raise IdentityError("an ADB identity query could not be read")
        os.set_blocking(process.stdout.fileno(), False)
        os.set_blocking(status_read, False)
        selector.register(process.stdout, selectors.EVENT_READ, "output")
        selector.register(status_read, selectors.EVENT_READ, "status")
        deadline = time.monotonic() + ADB_TIMEOUT_SECONDS
        output_complete = False
        status_complete = False
        while not output_complete or not status_complete:
            remaining = deadline - time.monotonic()
            events = selector.select(max(0.0, remaining))
            if remaining <= 0 or not events:
                raise IdentityError("an ADB identity query timed out")
            for key, _ in events:
                if key.data == "output":
                    chunk = os.read(
                        process.stdout.fileno(),
                        min(65536, maximum + 1 - len(payload)),
                    )
                    if chunk:
                        payload.extend(chunk)
                        if len(payload) > maximum:
                            raise IdentityError("an ADB identity query exceeded its size bound")
                    else:
                        selector.unregister(process.stdout)
                        output_complete = True
                else:
                    chunk = os.read(status_read, 33 - len(status_payload))
                    if chunk:
                        status_payload.extend(chunk)
                        if len(status_payload) > 32:
                            raise IdentityError("an ADB identity query returned invalid status")
                    else:
                        selector.unregister(status_read)
                        status_complete = True
            if time.monotonic() >= deadline and (not output_complete or not status_complete):
                raise IdentityError("an ADB identity query timed out")
        if re.fullmatch(rb"-?[0-9]{1,10}\n", bytes(status_payload)) is None:
            raise IdentityError("an ADB identity query returned invalid status")
        if int(status_payload) != 0:
            raise IdentityError("an ADB identity query failed")
    except IdentityError as error:
        failure = error
    except (OSError, subprocess.SubprocessError):
        failure = IdentityError("an ADB identity query failed")
    finally:
        selector.close()
        if status_write >= 0:
            os.close(status_write)
        if status_read >= 0:
            os.close(status_read)
        if liveness_read >= 0:
            os.close(liveness_read)
        if process is not None:
            if process.stdout is not None:
                process.stdout.close()
            try:
                _terminate_process_group(process)
            except IdentityError as error:
                cleanup_failure = error
        if liveness_write >= 0:
            os.close(liveness_write)
    if cleanup_failure is not None:
        raise cleanup_failure from failure
    if failure is not None:
        raise failure
    return bytes(payload)


def parse_adb_devices(payload: bytes) -> dict[str, AdbDevice]:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError:
        raise IdentityError("the ADB device inventory is not UTF-8") from None
    devices: dict[str, AdbDevice] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line == "List of devices attached":
            continue
        fields = line.split()
        if len(fields) < 2 or SAFE_SERIAL.fullmatch(fields[0]) is None or fields[1] not in KNOWN_STATES:
            raise IdentityError("the ADB device inventory is malformed")
        serial = fields[0]
        if serial in devices or len(devices) >= MAX_DEVICES:
            raise IdentityError("the ADB device inventory is ambiguous")
        metadata: dict[str, str] = {}
        for field in fields[2:]:
            if ":" not in field:
                continue
            key, value = field.split(":", 1)
            if key not in {"product", "model", "device", "transport_id"}:
                continue
            if SAFE_ADB_VALUE.fullmatch(value) is None or key in metadata:
                raise IdentityError("the ADB device inventory metadata is malformed")
            metadata[key] = value
        devices[serial] = AdbDevice(
            serial,
            fields[1],
            metadata.get("product"),
            metadata.get("model"),
            metadata.get("device"),
            metadata.get("transport_id"),
        )
    return devices


def read_adb_devices(
    adb: str,
    server_socket: str = "tcp:localhost:47137",
    home_directory: Path | None = None,
) -> dict[str, AdbDevice]:
    return parse_adb_devices(
        _run_bounded(
            [adb, *_remote_server_arguments(server_socket), "devices", "-l"],
            home_directory=home_directory,
        )
    )


def _remote_server_arguments(server_socket: str) -> list[str]:
    if server_socket != "tcp:localhost:47137":
        raise IdentityError("the product ADB server socket is unsupported")
    # Numeric loopback is deliberately remote to adb's launcher logic: if the
    # reviewed server disappears, the evidence client must fail instead of
    # daemonizing a replacement from its temporary executable.
    return ["-H", "127.0.0.1", "-P", "47137"]


def _snapshot_payload(devices: dict[str, AdbDevice]) -> bytes:
    records = [devices[serial].as_json() for serial in sorted(devices)]
    return (json.dumps(records, ensure_ascii=True, separators=(",", ":")) + "\n").encode()


def _private_snapshot_devices(
    devices: dict[str, AdbDevice], selected_serial: str
) -> dict[str, AdbDevice]:
    key = hashlib.sha256(b"DroidMatch product USB private snapshot\0" + selected_serial.encode()).digest()
    redacted: dict[str, AdbDevice] = {}
    for device in devices.values():
        identity = hmac.new(key, device.serial.encode(), hashlib.sha256).hexdigest()
        redacted[identity] = AdbDevice(identity, device.state, device.product, device.model,
                                       device.device, device.transport_id)
    return redacted


def read_snapshot(path: Path) -> dict[str, AdbDevice]:
    try:
        decoded = json.loads(read_regular_bounded(path, MAX_SNAPSHOT_BYTES))
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError):
        raise IdentityError("the private ADB snapshot is malformed") from None
    if not isinstance(decoded, list) or len(decoded) > MAX_DEVICES:
        raise IdentityError("the private ADB snapshot is malformed")
    devices: dict[str, AdbDevice] = {}
    for raw in decoded:
        if not isinstance(raw, dict) or set(raw) != {
            "serial",
            "state",
            "product",
            "model",
            "device",
            "transport_id",
        }:
            raise IdentityError("the private ADB snapshot is malformed")
        serial = raw["serial"]
        state_value = raw["state"]
        values = [raw["product"], raw["model"], raw["device"], raw["transport_id"]]
        if (
            not isinstance(serial, str)
            or SAFE_SERIAL.fullmatch(serial) is None
            or serial in devices
            or not isinstance(state_value, str)
            or state_value not in KNOWN_STATES
            or any(value is not None and (not isinstance(value, str) or SAFE_ADB_VALUE.fullmatch(value) is None) for value in values)
        ):
            raise IdentityError("the private ADB snapshot is malformed")
        devices[serial] = AdbDevice(serial, state_value, *values)
    return devices


def write_snapshot(path: Path, devices: dict[str, AdbDevice]) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = -1
    try:
        descriptor = os.open(path, flags, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as output:
            descriptor = -1
            output.write(_snapshot_payload(devices))
            output.flush()
            os.fsync(output.fileno())
    except OSError:
        if descriptor >= 0:
            os.close(descriptor)
        raise IdentityError("the private ADB snapshot could not be created") from None


def capture_snapshot(
    adb: str,
    selected_serial: str,
    output: Path,
    same_as: Path | None,
    server_socket: str = "tcp:localhost:47137",
    home_directory: Path | None = None,
) -> None:
    devices = read_adb_devices(adb, server_socket, home_directory)
    if selected_serial in devices:
        raise IdentityError("the selected device was present before the insertion signal")
    private_devices = _private_snapshot_devices(devices, selected_serial)
    if same_as is not None and private_devices != read_snapshot(same_as):
        raise IdentityError("the ADB inventory changed before the insertion signal")
    write_snapshot(output, private_devices)


def _getprop(
    adb: str,
    server_socket: str,
    serial: str,
    name: str,
    home_directory: Path | None = None,
) -> str:
    payload = _run_bounded(
        [
            adb,
            *_remote_server_arguments(server_socket),
            "-s",
            serial,
            "shell",
            "getprop",
            name,
        ],
        maximum=1024,
        home_directory=home_directory,
    )
    try:
        value = payload.decode("utf-8").strip("\r\n")
    except UnicodeDecodeError:
        raise IdentityError("a selected-device property is not UTF-8") from None
    if not value or "\n" in value or "\r" in value or len(value) > 80:
        raise IdentityError("a selected-device property is malformed")
    return value


def verify_insertion(
    adb: str,
    profile: SelectedDevice,
    selected_serial: str,
    before: Path,
    server_socket: str = "tcp:localhost:47137",
    home_directory: Path | None = None,
) -> dict[str, str]:
    if serial_tag(selected_serial) != profile.identity_tag:
        raise IdentityError("the selected device does not match the reviewed slot identity")
    previous = read_snapshot(before)
    current = read_adb_devices(adb, server_socket, home_directory)
    selected = current.get(selected_serial)
    remaining = dict(current)
    remaining.pop(selected_serial, None)
    if selected is None or selected.state != "device" \
            or _private_snapshot_devices(remaining, selected_serial) != previous:
        raise IdentityError("the selected device was not the unique ready ADB insertion")
    normalized_model = selected.model.replace("_", " ") if selected.model is not None else None
    if normalized_model != profile.visible_label:
        raise IdentityError("the product-visible label does not match the selected ADB device")
    manufacturer = _getprop(
        adb, server_socket, selected_serial, "ro.product.manufacturer", home_directory,
    )
    model = _getprop(
        adb, server_socket, selected_serial, "ro.product.model", home_directory
    )
    android_api = _getprop(
        adb, server_socket, selected_serial, "ro.build.version.sdk", home_directory,
    )
    if (
        manufacturer != profile.manufacturer
        or model != profile.model
        or android_api != str(profile.android_api)
    ):
        raise IdentityError("the selected device does not match the reviewed slot profile")
    return {
        "registry_profile": REGISTRY_PROFILE,
        "identity_tag": profile.identity_tag,
        "manufacturer": profile.manufacturer,
        "model": profile.model,
        "android_api": str(profile.android_api),
        "visible_label": profile.visible_label,
        "adb_identity_verified": "true",
        "adb_insertion_delta_verified": "true",
    }


def _safe_serial(value: str) -> str:
    if SAFE_SERIAL.fullmatch(value) is None:
        raise IdentityError("the selected device argument is invalid")
    return value


def _verify_adb_version(
    adb: str,
    toolchain: AdbToolchain,
    home_directory: Path | None = None,
) -> None:
    version_output = _run_bounded(
        [adb, "version"], maximum=4096, home_directory=home_directory,
    )
    try:
        version_lines = version_output.decode("utf-8").splitlines()
    except UnicodeDecodeError:
        raise IdentityError("the product ADB version is malformed") from None
    if (
        len(version_lines) < 2
        or version_lines[0] != "Android Debug Bridge version 1.0.41"
        or version_lines[1] != f"Version {toolchain.version}-{toolchain.build}"
    ):
        raise IdentityError("the product ADB version is not the reviewed build")


def _verify_adb_code_directories(adb: str, toolchain: AdbToolchain) -> None:
    if sys.platform != "darwin":
        return
    observed: list[str] = []
    for architecture in ("arm64", "x86_64"):
        payload = _run_bounded(
            [
                "/usr/bin/codesign",
                "-d",
                "--verbose=4",
                "--arch",
                architecture,
                adb,
            ],
            maximum=16384,
            merge_standard_error=True,
        )
        try:
            text = payload.decode("utf-8")
        except UnicodeDecodeError:
            raise IdentityError("the product ADB code identity is malformed") from None
        hashes = re.findall(r"(?m)^CDHash=([0-9a-f]{40})$", text)
        flag_sets = re.findall(r"(?m)^CodeDirectory .* flags=0x[0-9a-f]+\(([^)]+)\)", text)
        if len(hashes) != 1 or len(flag_sets) != 1 \
                or "runtime" not in flag_sets[0].split(","):
            raise IdentityError("the product ADB code identity is malformed")
        observed.append(hashes[0])
    if tuple(observed) != toolchain.code_directory_hashes:
        raise IdentityError("the product ADB code identity is not the reviewed build")


def _prepare_private_adb(
    value: str,
    toolchain: AdbToolchain,
    workspace: Path,
    home_directory: Path,
) -> tuple[str, str]:
    reviewed_path, payload = reviewed_adb_payload(
        value, toolchain, MAX_ADB_EXECUTABLE_BYTES
    )
    private_adb = write_private_adb(workspace / "adb", payload)
    _verify_adb_version(private_adb, toolchain, home_directory=home_directory)
    _verify_adb_code_directories(private_adb, toolchain)
    return reviewed_path, private_adb


def emit_profile(profile: SelectedDevice) -> None:
    values = {
        "registry_profile": REGISTRY_PROFILE,
        "identity_tag": profile.identity_tag,
        "manufacturer": profile.manufacturer,
        "model": profile.model,
        "android_api": str(profile.android_api),
        "visible_label": profile.visible_label,
    }
    for key, value in values.items():
        print(f"{key}={value}")


def emit_toolchain(server: VerifiedAdbServer | None, toolchain: AdbToolchain) -> None:
    values = {
        "adb_registry_profile": toolchain.profile,
        "adb_executable_sha256": toolchain.sha256,
        "adb_version": toolchain.version,
        "adb_build": toolchain.build,
        "adb_server_socket": toolchain.server_socket,
    }
    if server is not None:
        values["adb_server_pid"] = str(server.process_id)
        values["adb_server_instance"] = server.instance_identity
        values["adb_server_cdhash"] = server.code_directory_hash
    for key, value in values.items():
        print(f"{key}={value}")


class _PrivateArgumentParser(argparse.ArgumentParser):
    def error(self, _message: str) -> None:
        raise IdentityError("invalid invocation")


def build_parser() -> argparse.ArgumentParser:
    parser = _PrivateArgumentParser(add_help=False)
    subparsers = parser.add_subparsers(dest="command", required=True)
    profile = subparsers.add_parser("profile", add_help=False)
    profile.add_argument("--slot", required=True)
    profile.add_argument("--selected-serial")
    toolchain = subparsers.add_parser("toolchain", add_help=False)
    toolchain.add_argument("--adb")
    toolchain.add_argument("--adb-executable")
    toolchain.add_argument("--static-only", action="store_true")
    capture = subparsers.add_parser("capture", add_help=False)
    capture.add_argument("--adb", required=True)
    capture.add_argument("--selected-serial", required=True)
    capture.add_argument("--output", required=True)
    capture.add_argument("--same-as")
    verify = subparsers.add_parser("verify", add_help=False)
    verify.add_argument("--adb", required=True)
    verify.add_argument("--slot", required=True)
    verify.add_argument("--selected-serial", required=True)
    verify.add_argument("--before", required=True)
    return parser


def _run_adb_operation(options: argparse.Namespace, devices: dict[str, SelectedDevice]) -> None:
    toolchain = load_adb_registry()
    if options.command == "toolchain" and options.adb is not None \
            and options.adb_executable is not None:
        raise IdentityError("the product ADB toolchain invocation is ambiguous")
    if options.command == "toolchain" and options.static_only \
            and options.adb_executable is None:
        raise IdentityError("static product ADB verification requires an executable")
    requested_adb = (
        options.adb_executable
        if options.command == "toolchain" and options.adb_executable is not None
        else options.adb
    )
    if requested_adb is None:
        emit_toolchain(None, toolchain)
        return

    workspace = _create_private_workspace()
    try:
        home_directory = workspace / "home"
        home_directory.mkdir(mode=0o700)
        if options.command == "toolchain" and options.static_only:
            reviewed_adb, payload = reviewed_adb_payload(
                requested_adb, toolchain, MAX_ADB_EXECUTABLE_BYTES
            )
            private_adb = write_private_adb(workspace / "adb", payload)
            _verify_adb_code_directories(private_adb, toolchain)
        else:
            reviewed_adb, private_adb = _prepare_private_adb(
                requested_adb, toolchain, workspace, home_directory,
            )
        if options.command == "toolchain" and options.adb_executable is not None:
            emit_toolchain(None, toolchain)
            return
        server = verify_product_adb_server(reviewed_adb, toolchain, _run_bounded)
        if options.command == "toolchain":
            emit_toolchain(server, toolchain)
            return
        if options.command == "capture":
            capture_snapshot(
                private_adb,
                _safe_serial(options.selected_serial),
                Path(options.output),
                Path(options.same_as) if options.same_as else None,
                toolchain.server_socket,
                home_directory=home_directory,
            )
            failure = "the product ADB server changed during the inventory query"
        else:
            if options.slot not in devices:
                raise IdentityError("the selected slot is not in the reviewed device registry")
            values = verify_insertion(
                private_adb,
                devices[options.slot],
                _safe_serial(options.selected_serial),
                Path(options.before),
                toolchain.server_socket,
                home_directory=home_directory,
            )
            failure = "the product ADB server changed during identity verification"
        if verify_product_adb_server(reviewed_adb, toolchain, _run_bounded) != server:
            raise IdentityError(failure)
        if options.command == "verify":
            for key, value in values.items():
                print(f"{key}={value}")
    finally:
        try:
            shutil.rmtree(workspace)
        except OSError:
            raise IdentityError("a private ADB identity workspace could not be cleaned up") from None


def main(arguments: list[str], registry_path: Path = REGISTRY_PATH) -> int:
    try:
        options = build_parser().parse_args(arguments)
        devices = load_registry(registry_path)
        if options.command == "profile":
            if options.slot not in devices:
                raise IdentityError("the selected slot is not in the reviewed device registry")
            if options.selected_serial is not None and serial_tag(
                _safe_serial(options.selected_serial)
            ) != devices[options.slot].identity_tag:
                raise IdentityError("the selected device does not match the reviewed slot identity")
            emit_profile(devices[options.slot])
        else:
            _run_adb_operation(options, devices)
        return 0
    except IdentityError as error:
        print(f"product USB device identity refused: {error}", file=sys.stderr)
        return 1
    except SystemExit:
        print("product USB device identity refused: invalid invocation", file=sys.stderr)
        return 2


if __name__ == "__main__":
    if len(sys.argv) >= 6 and sys.argv[1] == "__supervise":
        try:
            supervisor_status_descriptor = int(sys.argv[2])
            supervisor_liveness_descriptor = int(sys.argv[3])
        except ValueError:
            raise SystemExit(125)
        if sys.argv[4] not in {"merge", "discard"}:
            raise SystemExit(125)
        raise SystemExit(
            _supervise_command(
                supervisor_status_descriptor,
                supervisor_liveness_descriptor,
                sys.argv[4] == "merge",
                sys.argv[5:],
            )
        )
    raise SystemExit(main(sys.argv[1:]))
