#!/usr/bin/env python3
"""Build a deterministic modern ICNS container from a strict iconset."""

from __future__ import annotations

import os
from pathlib import Path
import stat
import struct
import sys


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MAX_PNG_BYTES = 16 * 1024 * 1024
ICON_ENTRIES = (
    (b"icp4", "icon_16x16.png", 16),
    (b"ic11", "icon_16x16@2x.png", 32),
    (b"icp5", "icon_32x32.png", 32),
    (b"ic12", "icon_32x32@2x.png", 64),
    (b"ic07", "icon_128x128.png", 128),
    (b"ic13", "icon_128x128@2x.png", 256),
    (b"ic08", "icon_256x256.png", 256),
    (b"ic14", "icon_256x256@2x.png", 512),
    (b"ic09", "icon_512x512.png", 512),
    (b"ic10", "icon_512x512@2x.png", 1024),
)


def fail(message: str) -> None:
    raise ValueError(message)


def validate_owned_directory(path: Path, label: str) -> None:
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        fail(f"{label} must be an owned directory")


def read_png(path: Path, expected_pixels: int) -> bytes:
    info = path.lstat()
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_nlink != 1
        or info.st_size > MAX_PNG_BYTES
    ):
        fail(f"unsafe icon source: {path.name}")
    data = path.read_bytes()
    if (
        len(data) < 33
        or not data.startswith(PNG_SIGNATURE)
        or struct.unpack(">I", data[8:12])[0] != 13
        or data[12:16] != b"IHDR"
    ):
        fail(f"invalid PNG header: {path.name}")
    width, height = struct.unpack(">II", data[16:24])
    if width != expected_pixels or height != expected_pixels:
        fail(f"unexpected PNG dimensions: {path.name}")
    if data[24:29] != bytes((8, 6, 0, 0, 0)):
        fail(f"icon PNG must be non-interlaced 8-bit RGBA: {path.name}")
    return data


def build_container(iconset: Path) -> bytes:
    validate_owned_directory(iconset, "iconset")
    expected_names = {entry[1] for entry in ICON_ENTRIES}
    if {entry.name for entry in iconset.iterdir()} != expected_names:
        fail("iconset must contain exactly the required ten PNG renditions")

    chunks: list[bytes] = []
    for kind, name, pixels in ICON_ENTRIES:
        payload = read_png(iconset / name, pixels)
        chunks.append(kind + struct.pack(">I", len(payload) + 8) + payload)
    body = b"".join(chunks)
    return b"icns" + struct.pack(">I", len(body) + 8) + body


def write_exclusive(path: Path, data: bytes) -> None:
    validate_owned_directory(path.parent, "output parent")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o644)
    try:
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                fail("short ICNS write")
            view = view[written:]
        os.fsync(descriptor)
    except BaseException:
        os.close(descriptor)
        path.unlink(missing_ok=True)
        raise
    os.close(descriptor)


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: package-mac-icon.py <input.iconset> <output.icns>", file=sys.stderr)
        return 2
    try:
        output = Path(sys.argv[2])
        if output.suffix != ".icns":
            fail("output must use the .icns extension")
        write_exclusive(output, build_container(Path(sys.argv[1])))
    except (OSError, ValueError) as error:
        print(f"Mac icon packaging failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
