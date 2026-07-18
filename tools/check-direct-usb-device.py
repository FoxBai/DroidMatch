#!/usr/bin/env python3
"""Fail closed unless one selected ADB device is directly attached over USB."""

from __future__ import annotations

import os
import plistlib
import re
import selectors
import subprocess
import sys
import time
from collections.abc import Iterator
from typing import Any


IOREG = "/usr/sbin/ioreg"
MAX_IOREG_BYTES = 16 * 1024 * 1024
SERIAL_KEYS = (
    "USB Serial Number",
    "USB Serial Number String",
    "kUSBSerialNumberString",
)
CHILDREN_KEY = "IORegistryEntryChildren"
DEVICE_CLASS_KEYS = ("bDeviceClass", "USB Device Class")
ENTRY_NAME_KEYS = ("IORegistryEntryName", "IORegistryEntryNameKey")
CONTROLLER_MARKERS = ("xhci", "ehci", "ohci", "uhci", "usbhostcontroller")
SAFE_SERIAL = re.compile(r"[A-Za-z0-9._:-]{6,}")


class DirectUsbError(Exception):
    """An intentionally privacy-bounded topology refusal."""


def _as_text(value: Any) -> str | None:
    if isinstance(value, str):
        return value
    if isinstance(value, bytes):
        try:
            return value.decode("utf-8")
        except UnicodeDecodeError:
            return None
    return None


def _as_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    text = _as_text(value)
    if text is None:
        return None
    try:
        return int(text, 0)
    except ValueError:
        return None


def _node_name(node: dict[str, Any]) -> str:
    for key in ENTRY_NAME_KEYS:
        text = _as_text(node.get(key))
        if text is not None:
            return text
    return ""


def _is_hub(node: dict[str, Any]) -> bool:
    for key in DEVICE_CLASS_KEYS:
        if _as_int(node.get(key)) == 9:
            return True
    return "hub" in _node_name(node).casefold()


def _is_host_controller(node: dict[str, Any]) -> bool:
    normalized = _node_name(node).casefold().replace(" ", "")
    return any(marker in normalized for marker in CONTROLLER_MARKERS)


def _has_serial(node: dict[str, Any], serial: str) -> bool:
    return any(_as_text(node.get(key)) == serial for key in SERIAL_KEYS)


def _walk(
    value: Any, ancestors: tuple[dict[str, Any], ...] = ()
) -> Iterator[tuple[dict[str, Any], tuple[dict[str, Any], ...]]]:
    if isinstance(value, list):
        for item in value:
            yield from _walk(item, ancestors)
        return
    if not isinstance(value, dict):
        return
    yield value, ancestors
    children = value.get(CHILDREN_KEY, [])
    if isinstance(children, list):
        for child in children:
            yield from _walk(child, ancestors + (value,))


def verify_direct_tree(tree: Any, serial: str) -> None:
    matches = [
        (node, ancestors)
        for node, ancestors in _walk(tree)
        if _has_serial(node, serial)
    ]
    if len(matches) != 1:
        raise DirectUsbError("the selected USB device could not be matched uniquely")

    device, ancestors = matches[0]
    if _is_hub(device) or any(_is_hub(node) for node in ancestors):
        raise DirectUsbError("the selected USB device is behind a hub")
    if not any(_is_host_controller(node) for node in ancestors):
        raise DirectUsbError("the selected USB device has no verified host controller")


def _read_bounded(command: list[str], timeout: float = 15) -> bytes:
    process: subprocess.Popen[bytes] | None = None
    selector = selectors.DefaultSelector()
    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        if process.stdout is None:
            raise DirectUsbError("the macOS USB registry could not be read")
        os.set_blocking(process.stdout.fileno(), False)
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        payload = bytearray()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise DirectUsbError("the macOS USB registry read timed out")
            if not selector.select(remaining):
                raise DirectUsbError("the macOS USB registry read timed out")
            chunk = os.read(
                process.stdout.fileno(), min(65536, MAX_IOREG_BYTES + 1 - len(payload))
            )
            if not chunk:
                break
            payload.extend(chunk)
            if len(payload) > MAX_IOREG_BYTES:
                raise DirectUsbError("the macOS USB registry exceeded its size bound")
        if process.wait(timeout=max(0.01, deadline - time.monotonic())) != 0:
            raise DirectUsbError("the macOS USB registry could not be read")
        if not payload:
            raise DirectUsbError("the macOS USB registry could not be read")
        return bytes(payload)
    except (OSError, subprocess.SubprocessError):
        raise DirectUsbError("the macOS USB registry could not be read") from None
    finally:
        selector.close()
        if process is not None:
            if process.poll() is None:
                process.kill()
            process.wait()
            if process.stdout is not None:
                process.stdout.close()


def read_ioreg_tree() -> Any:
    if sys.platform != "darwin" or not os.access(IOREG, os.X_OK):
        raise DirectUsbError("the macOS USB registry is unavailable")
    try:
        return plistlib.loads(_read_bounded([IOREG, "-a", "-p", "IOUSB", "-l", "-w0"]))
    except (plistlib.InvalidFileException, ValueError, TypeError):
        raise DirectUsbError("the macOS USB registry could not be parsed") from None


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] != "--serial" or not SAFE_SERIAL.fullmatch(argv[1]):
        print("direct USB topology refused: invalid invocation", file=sys.stderr)
        return 2
    try:
        verify_direct_tree(read_ioreg_tree(), argv[1])
    except DirectUsbError as error:
        print(f"direct USB topology refused: {error}", file=sys.stderr)
        return 1
    print("direct USB topology verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
