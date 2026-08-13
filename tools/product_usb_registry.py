"""Strict bounded registries for attended product USB evidence."""

from __future__ import annotations

import json
import hashlib
import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path


REGISTRY_PATH = Path(__file__).with_name("product-usb-selected-devices-v1.json")
REGISTRY_PROFILE = "m1-product-usb-selected-devices-v1"
ADB_REGISTRY_PATH = Path(__file__).with_name("product-usb-adb-v1.json")
ADB_REGISTRY_PROFILE = "m1-product-usb-adb-v1"
MAX_REGISTRY_BYTES = 16 * 1024
SAFE_ADB_VALUE = re.compile(r"[A-Za-z0-9._-]{1,128}")
SAFE_PROFILE_TEXT = re.compile(r"[A-Za-z0-9 ._-]{1,80}")


class IdentityError(Exception):
    """An intentionally path- and serial-free evidence refusal."""


@dataclass(frozen=True)
class SelectedDevice:
    slot: str
    identity_tag: str
    manufacturer: str
    model: str
    android_api: int
    visible_label: str


@dataclass(frozen=True)
class AdbToolchain:
    profile: str
    platform: str
    sha256: str
    version: str
    build: str
    server_socket: str
    code_directory_hashes: tuple[str, ...]


def read_regular_bounded(path: Path, maximum: int) -> bytes:
    descriptor = -1
    try:
        flags = os.O_RDONLY
        for option in ("O_CLOEXEC", "O_NOFOLLOW", "O_NONBLOCK"):
            flags |= getattr(os, option, 0)
        descriptor = os.open(path, flags)
        status = os.fstat(descriptor)
        if not stat.S_ISREG(status.st_mode) or not 0 < status.st_size <= maximum:
            raise IdentityError("a required identity input is not a bounded regular file")
        payload = bytearray()
        while len(payload) <= maximum:
            chunk = os.read(descriptor, min(65536, maximum + 1 - len(payload)))
            if not chunk:
                break
            payload.extend(chunk)
        if not payload or len(payload) > maximum:
            raise IdentityError("a required identity input is not a bounded regular file")
        return bytes(payload)
    except (OSError, ValueError):
        raise IdentityError("a required identity input could not be read") from None
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def reviewed_adb_payload(
    value: str, toolchain: AdbToolchain, maximum: int
) -> tuple[str, bytes]:
    path = Path(value)
    try:
        status = path.lstat()
        resolved = path.resolve(strict=True)
        initial = resolved.stat()
    except OSError:
        raise IdentityError("the selected ADB executable is unavailable") from None
    if (
        not path.is_absolute() or stat.S_ISLNK(status.st_mode) or path != resolved
        or not stat.S_ISREG(initial.st_mode) or initial.st_nlink != 1
        or not 0 < initial.st_size <= maximum or not os.access(resolved, os.X_OK)
    ):
        raise IdentityError("the selected ADB executable is unavailable")
    payload = read_regular_bounded(resolved, maximum)
    if hashlib.sha256(payload).hexdigest() != toolchain.sha256:
        raise IdentityError("the product ADB executable is not the reviewed build")
    try:
        final = resolved.stat()
    except OSError:
        raise IdentityError("the selected ADB executable is unavailable") from None
    fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_mode")
    if any(getattr(final, field) != getattr(initial, field) for field in fields):
        raise IdentityError("the selected ADB executable changed during verification")
    return str(resolved), payload


def write_private_adb(destination: Path, payload: bytes) -> str:
    descriptor = -1
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        for option in ("O_CLOEXEC", "O_NOFOLLOW"):
            flags |= getattr(os, option, 0)
        descriptor = os.open(destination, flags, 0o700)
        offset = 0
        while offset < len(payload):
            try:
                written = os.write(descriptor, payload[offset:])
            except InterruptedError:
                continue
            if written <= 0:
                raise OSError("short write")
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        status = destination.stat()
        if not stat.S_ISREG(status.st_mode) or status.st_nlink != 1 \
                or stat.S_IMODE(status.st_mode) != 0o700 or status.st_size != len(payload):
            raise OSError("invalid private executable")
        return str(destination)
    except OSError:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            destination.unlink()
        except OSError:
            pass
        raise IdentityError("a private product ADB executable could not be created") from None


def load_registry(path: Path = REGISTRY_PATH) -> dict[str, SelectedDevice]:
    try:
        decoded = json.loads(read_regular_bounded(path, MAX_REGISTRY_BYTES))
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError):
        raise IdentityError("the selected-device registry is malformed") from None
    if not isinstance(decoded, dict) or set(decoded) != {"schemaVersion", "profile", "devices"}:
        raise IdentityError("the selected-device registry schema is invalid")
    if decoded["schemaVersion"] != 1 or decoded["profile"] != REGISTRY_PROFILE:
        raise IdentityError("the selected-device registry profile is unsupported")
    records = decoded["devices"]
    if not isinstance(records, list) or len(records) != 3:
        raise IdentityError("the selected-device registry must contain Slots A/C/D")

    devices: dict[str, SelectedDevice] = {}
    tags: set[str] = set()
    identities: set[tuple[str, str, int]] = set()
    required_keys = {
        "slot", "identityTag", "manufacturer", "model", "androidApi", "visibleLabel"
    }
    for raw in records:
        if not isinstance(raw, dict) or set(raw) != required_keys:
            raise IdentityError("a selected-device registry record is malformed")
        slot = raw["slot"]
        tag = raw["identityTag"]
        manufacturer = raw["manufacturer"]
        model = raw["model"]
        android_api = raw["androidApi"]
        label = raw["visibleLabel"]
        if (
            not isinstance(slot, str)
            or slot not in {"A", "C", "D"}
            or slot in devices
            or not isinstance(tag, str)
            or re.fullmatch(r"[0-9a-f]{32}", tag) is None
            or tag in tags
            or not isinstance(manufacturer, str)
            or SAFE_PROFILE_TEXT.fullmatch(manufacturer) is None
            or not isinstance(model, str)
            or SAFE_PROFILE_TEXT.fullmatch(model) is None
            or not isinstance(android_api, int)
            or isinstance(android_api, bool)
            or not 26 <= android_api <= 99
            or not isinstance(label, str)
            or SAFE_PROFILE_TEXT.fullmatch(label) is None
            or label != model
        ):
            raise IdentityError("a selected-device registry record is invalid")
        identity = (manufacturer, model, android_api)
        if identity in identities:
            raise IdentityError("selected-device registry identities must be unique")
        devices[slot] = SelectedDevice(slot, tag, manufacturer, model, android_api, label)
        tags.add(tag)
        identities.add(identity)
    if set(devices) != {"A", "C", "D"}:
        raise IdentityError("the selected-device registry must contain Slots A/C/D")
    return devices


def load_adb_registry(path: Path = ADB_REGISTRY_PATH) -> AdbToolchain:
    try:
        decoded = json.loads(read_regular_bounded(path, MAX_REGISTRY_BYTES))
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError):
        raise IdentityError("the product ADB registry is malformed") from None
    required = {
        "schemaVersion", "profile", "platform", "signedExecutableSha256",
        "version", "build", "serverSocket",
        "codeDirectoryHashes",
    }
    if not isinstance(decoded, dict) or set(decoded) != required:
        raise IdentityError("the product ADB registry schema is invalid")
    values = [decoded["platform"], decoded["version"], decoded["build"]]
    if (
        decoded["schemaVersion"] != 1
        or decoded["profile"] != ADB_REGISTRY_PROFILE
        or any(not isinstance(value, str) or SAFE_ADB_VALUE.fullmatch(value) is None for value in values)
        or not isinstance(decoded["signedExecutableSha256"], str)
        or re.fullmatch(r"[0-9a-f]{64}", decoded["signedExecutableSha256"]) is None
        or decoded["serverSocket"] != "tcp:localhost:47137"
        or not isinstance(decoded["codeDirectoryHashes"], list)
        or len(decoded["codeDirectoryHashes"]) != 2
        or any(
            not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{40}", value) is None
            for value in decoded["codeDirectoryHashes"]
        )
        or len(set(decoded["codeDirectoryHashes"])) != 2
    ):
        raise IdentityError("the product ADB registry is invalid")
    return AdbToolchain(
        decoded["profile"], decoded["platform"], decoded["signedExecutableSha256"],
        decoded["version"], decoded["build"], decoded["serverSocket"],
        tuple(decoded["codeDirectoryHashes"]),
    )
