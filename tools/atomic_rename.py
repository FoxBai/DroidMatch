#!/usr/bin/env python3

"""Cross-platform atomic rename primitives used by release publication."""

from __future__ import annotations

import ctypes
import os
import sys


EXCHANGE = "exchange"
EXCLUSIVE = "exclusive"


def rename_configuration(platform: str, mode: str) -> tuple[str, int]:
    if mode not in {EXCHANGE, EXCLUSIVE}:
        raise RuntimeError("unsupported atomic rename mode")
    if platform == "darwin":
        return "renameatx_np", 2 if mode == EXCHANGE else 4
    if platform.startswith("linux"):
        return "renameat2", 2 if mode == EXCHANGE else 1
    raise RuntimeError("atomic rename is unsupported on this platform")


def current_directory_fd(platform: str) -> int:
    if platform == "darwin":
        return -2
    if platform.startswith("linux"):
        return -100
    raise RuntimeError("atomic rename is unsupported on this platform")


def rename_at(
    source_directory_fd: int,
    source: str,
    destination_directory_fd: int,
    destination: str,
    mode: str,
) -> None:
    function_name, flag = rename_configuration(sys.platform, mode)
    library = ctypes.CDLL(None, use_errno=True)
    try:
        function = getattr(library, function_name)
    except AttributeError as error:
        raise RuntimeError("atomic rename primitive is unavailable") from error
    function.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    function.restype = ctypes.c_int
    if function(
        source_directory_fd,
        os.fsencode(source),
        destination_directory_fd,
        os.fsencode(destination),
        flag,
    ):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination)


def rename_paths(source: str, destination: str, mode: str) -> None:
    directory_fd = current_directory_fd(sys.platform)
    rename_at(directory_fd, source, directory_fd, destination, mode)
