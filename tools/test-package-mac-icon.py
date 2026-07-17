#!/usr/bin/env python3
"""Offline regression tests for the strict modern ICNS packer."""

from __future__ import annotations

import binascii
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import zlib


ROOT = Path(__file__).resolve().parent.parent
PACKER = ROOT / "tools" / "package-mac-icon.py"
RENDITIONS = (
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
)
EXPECTED_TYPES = (
    b"icp4", b"ic11", b"icp5", b"ic12", b"ic07",
    b"ic13", b"ic08", b"ic14", b"ic09", b"ic10",
)


def chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)
    )


def png(width: int, height: int) -> bytes:
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    row = b"\x00" + (b"\x19\x73\x61\xff" * width)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(row * height))
        + chunk(b"IEND", b"")
    )


def run(iconset: Path, output: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(PACKER), str(iconset), str(output)],
        text=True,
        capture_output=True,
        check=False,
    )


def parse_types(container: bytes) -> tuple[bytes, ...]:
    assert container[:4] == b"icns"
    assert struct.unpack(">I", container[4:8])[0] == len(container)
    position = 8
    types: list[bytes] = []
    while position < len(container):
        size = struct.unpack(">I", container[position + 4:position + 8])[0]
        assert size > 8 and position + size <= len(container)
        types.append(container[position:position + 4])
        position += size
    assert position == len(container)
    return tuple(types)


with tempfile.TemporaryDirectory(prefix="droidmatch-icon-packer-") as temp:
    root = Path(temp)
    iconset = root / "DroidMatch.iconset"
    iconset.mkdir()
    for name, pixels in RENDITIONS:
        (iconset / name).write_bytes(png(pixels, pixels))

    output = root / "DroidMatch.icns"
    result = run(iconset, output)
    assert result.returncode == 0, result.stderr
    assert parse_types(output.read_bytes()) == EXPECTED_TYPES
    assert stat.S_IMODE(output.stat().st_mode) == 0o644

    bad_output = root / "bad.icns"
    (iconset / RENDITIONS[0][0]).write_bytes(png(15, 16))
    result = run(iconset, bad_output)
    assert result.returncode == 1 and not bad_output.exists()
    assert "unexpected PNG dimensions" in result.stderr
    (iconset / RENDITIONS[0][0]).write_bytes(png(16, 16))

    extra_output = root / "extra.icns"
    (iconset / "unexpected.png").write_bytes(png(16, 16))
    result = run(iconset, extra_output)
    assert result.returncode == 1 and not extra_output.exists()
    assert "exactly the required ten" in result.stderr
    (iconset / "unexpected.png").unlink()

    preserved = root / "preserved.icns"
    preserved.write_bytes(b"do-not-replace")
    result = run(iconset, preserved)
    assert result.returncode == 1
    assert preserved.read_bytes() == b"do-not-replace"

print("Mac icon packer offline tests passed.")
print("中文：Mac 图标打包器离线测试通过。")
