"""Darwin process identity checks for the dedicated product ADB server."""

from __future__ import annotations

import ctypes
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from product_usb_registry import AdbToolchain, IdentityError


CS_OPS_STATUS = 0
CS_OPS_CDHASH = 5
CS_VALID = 0x00000001
CS_RUNTIME = 0x00010000
CS_DEBUGGED = 0x10000000
RunBounded = Callable[..., bytes]
INSTANCE_PATTERN = re.compile(
    r"^darwin:[0-9a-f-]{36}:(?P<user_id>[0-9]+):[0-9]+:[0-9]+$"
)


@dataclass(frozen=True)
class VerifiedAdbServer:
    adb: str
    toolchain: AdbToolchain
    process_id: int
    instance_identity: str
    code_directory_hash: str


def _listener_process_path(process_id: int) -> Path:
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    function = library.proc_pidpath
    function.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    function.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    length = function(process_id, buffer, len(buffer))
    if length <= 0:
        raise IdentityError("the product ADB server process could not be verified")
    try:
        return Path(os.fsdecode(buffer.value)).resolve(strict=True)
    except (OSError, UnicodeDecodeError):
        raise IdentityError("the product ADB server process could not be verified") from None


def _process_instance_identity(process_id: int, run_bounded: RunBounded) -> str:
    try:
        result = run_bounded(
            [
                sys.executable,
                str(Path(__file__).with_name("process_instance_identity.py")),
                "capture",
                str(process_id),
            ],
            maximum=512,
        )
        value = result.decode("ascii").strip()
    except (IdentityError, UnicodeDecodeError):
        raise IdentityError("the product ADB server process could not be verified") from None
    if INSTANCE_PATTERN.fullmatch(value) is None:
        raise IdentityError("the product ADB server process could not be verified")
    return value


def _process_instance_user_id(identity: str) -> int:
    match = INSTANCE_PATTERN.fullmatch(identity)
    if match is None:
        raise IdentityError("the product ADB server process could not be verified")
    return int(match.group("user_id"))


def _process_code_identity(process_id: int) -> tuple[int, str]:
    library = ctypes.CDLL(None, use_errno=True)
    function = library.csops
    function.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.c_void_p, ctypes.c_size_t]
    function.restype = ctypes.c_int
    flags = ctypes.c_uint32()
    digest = ctypes.create_string_buffer(20)
    if (
        function(process_id, CS_OPS_STATUS, ctypes.byref(flags), ctypes.sizeof(flags)) != 0
        or function(process_id, CS_OPS_CDHASH, digest, len(digest)) != 0
    ):
        raise IdentityError("the product ADB server process could not be verified")
    return flags.value, digest.raw.hex()


def _listener_mapped_executable_identity(
    process_id: int,
    expected_path: Path,
    run_bounded: RunBounded,
) -> tuple[int, int]:
    try:
        payload = run_bounded(
            [
                "/usr/sbin/lsof",
                "-nP",
                "-a",
                "-p",
                str(process_id),
                "-d",
                "txt",
                "-F",
                "pDfint",
            ],
            maximum=65536,
        ).decode("utf-8")
    except (IdentityError, UnicodeDecodeError):
        raise IdentityError("the product ADB server process could not be verified") from None
    current: dict[str, str] = {}
    records: list[dict[str, str]] = []
    for line in payload.splitlines():
        if not line:
            continue
        key, value = line[0], line[1:]
        if key == "f":
            if current:
                records.append(current)
            current = {"f": value}
        elif current and key in {"D", "i", "n", "t"} and key not in current:
            current[key] = value
    if current:
        records.append(current)
    matches = [
        record
        for record in records
        if record.get("f") == "txt"
        and record.get("t") == "REG"
        and record.get("n") == str(expected_path)
        and re.fullmatch(r"0x[0-9a-fA-F]+", record.get("D", ""))
        and re.fullmatch(r"[0-9]+", record.get("i", ""))
    ]
    if len(matches) != 1:
        raise IdentityError("the product ADB server process could not be verified")
    return int(matches[0]["D"], 16), int(matches[0]["i"])


def _listener_pid(toolchain: AdbToolchain, run_bounded: RunBounded) -> int:
    port = toolchain.server_socket.rsplit(":", 1)[1]
    try:
        payload = run_bounded(
            [
                "/usr/sbin/lsof",
                "-nP",
                "-a",
                f"-iTCP:{port}",
                "-sTCP:LISTEN",
                "-Fpcn",
            ],
            maximum=8192,
        )
        lines = payload.decode("utf-8").splitlines()
    except (IdentityError, UnicodeDecodeError):
        raise IdentityError("the product ADB server is not already listening") from None
    process_ids = {line[1:] for line in lines if line.startswith("p")}
    commands = [line[1:] for line in lines if line.startswith("c")]
    endpoints = [line[1:] for line in lines if line.startswith("n")]
    if (
        len(process_ids) != 1
        or commands != ["adb"]
        or endpoints != [f"127.0.0.1:{port}"]
        or re.fullmatch(r"[1-9][0-9]{0,9}", next(iter(process_ids))) is None
    ):
        raise IdentityError("the product ADB server listener is ambiguous")
    return int(next(iter(process_ids)))


def verify_product_adb_server(
    adb: str,
    toolchain: AdbToolchain,
    run_bounded: RunBounded,
) -> VerifiedAdbServer:
    adb_path = Path(adb)
    process_id = _listener_pid(toolchain, run_bounded)
    instance_identity = _process_instance_identity(process_id, run_bounded)
    listener_path = _listener_process_path(process_id)
    try:
        adb_status = adb_path.stat()
    except OSError:
        raise IdentityError("the product ADB server process could not be verified") from None
    mapped_identity = _listener_mapped_executable_identity(
        process_id,
        listener_path,
        run_bounded,
    )
    code_identity = _process_code_identity(process_id)
    final_process_id = _listener_pid(toolchain, run_bounded)
    final_instance_identity = _process_instance_identity(process_id, run_bounded)
    final_code_identity = _process_code_identity(process_id)
    if (
        listener_path != adb_path
        or mapped_identity != (adb_status.st_dev, adb_status.st_ino)
        or _process_instance_user_id(instance_identity) != os.geteuid()
        or final_process_id != process_id
        or final_instance_identity != instance_identity
        or code_identity != final_code_identity
        or code_identity[1] not in toolchain.code_directory_hashes
        or code_identity[0] & (CS_VALID | CS_RUNTIME) != (CS_VALID | CS_RUNTIME)
        or code_identity[0] & CS_DEBUGGED != 0
    ):
        raise IdentityError("the product ADB server does not use the reviewed executable")
    return VerifiedAdbServer(
        str(adb_path),
        toolchain,
        process_id,
        instance_identity,
        code_identity[1],
    )
