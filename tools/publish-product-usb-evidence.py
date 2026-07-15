#!/usr/bin/env python3

"""Publish one validated product-USB fixture from a pinned descriptor."""

import hashlib
import os
import re
import stat
import subprocess
import sys
import tempfile
from typing import Optional, Tuple


Identity = Tuple[int, int]
RESULT_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*[.]md$")
MAX_EVIDENCE_BYTES = 64 * 1024
SUCCESS = 0
PREPUBLICATION_FAILURE = 1
PUBLICATION_UNCERTAIN = 3


def digest_fd(fd: int) -> bytes:
    digest = hashlib.sha256()
    offset = 0
    while True:
        chunk = os.pread(fd, 64 * 1024, offset)
        if not chunk:
            return digest.digest()
        digest.update(chunk)
        offset += len(chunk)


def copy_fd(source_fd: int, destination_fd: int) -> None:
    offset = 0
    while True:
        chunk = os.pread(source_fd, 64 * 1024, offset)
        if not chunk:
            return
        written = 0
        while written < len(chunk):
            count = os.write(destination_fd, chunk[written:])
            if count <= 0:
                raise OSError("evidence copy made no progress")
            written += count
        offset += len(chunk)


def copy_stdin(destination_fd: int) -> int:
    total = 0
    while True:
        chunk = os.read(sys.stdin.fileno(), 64 * 1024)
        if not chunk:
            return total
        total += len(chunk)
        if total > MAX_EVIDENCE_BYTES:
            raise ValueError("evidence exceeds the bounded fixture size")
        written = 0
        while written < len(chunk):
            count = os.write(destination_fd, chunk[written:])
            if count <= 0:
                raise OSError("evidence write made no progress")
            written += count


def identity(info: os.stat_result) -> Identity:
    return (info.st_dev, info.st_ino)


def stat_entry(directory_fd: int, name: str) -> Optional[os.stat_result]:
    try:
        return os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def matching_regular(
    directory_fd: int,
    name: str,
    expected: Identity,
    expected_links: Optional[int] = None,
) -> bool:
    info = stat_entry(directory_fd, name)
    return bool(
        info is not None
        and stat.S_ISREG(info.st_mode)
        and identity(info) == expected
        and (expected_links is None or info.st_nlink == expected_links)
    )


def digest_entry(directory_fd: int, name: str, expected: Identity) -> Optional[bytes]:
    flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        fd = os.open(name, flags, dir_fd=directory_fd)
    except OSError:
        return None
    try:
        if identity(os.fstat(fd)) != expected:
            return None
        return digest_fd(fd)
    finally:
        os.close(fd)


def validate(checker: str, path: str) -> bool:
    return subprocess.run(
        ["bash", checker, "--log", path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0


def validate_snapshot(fd: int, expected_digest: bytes, checker: str) -> bool:
    with tempfile.TemporaryDirectory(prefix="droidmatch-product-usb-validation.") as work:
        os.chmod(work, 0o700)
        snapshot = os.path.join(work, "evidence.md")
        snapshot_fd = os.open(
            snapshot,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
            0o600,
        )
        try:
            copy_fd(fd, snapshot_fd)
            os.fsync(snapshot_fd)
        finally:
            os.close(snapshot_fd)
        snapshot_fd = os.open(snapshot, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            if digest_fd(snapshot_fd) != expected_digest:
                return False
        finally:
            os.close(snapshot_fd)
        return validate(checker, snapshot)


def supported() -> bool:
    return bool(
        hasattr(os, "O_DIRECTORY")
        and hasattr(os, "O_NOFOLLOW")
        and hasattr(os, "O_CLOEXEC")
        and hasattr(os, "O_NONBLOCK")
        and hasattr(os, "pread")
        and os.open in os.supports_dir_fd
        and os.stat in os.supports_dir_fd
        and os.stat in os.supports_follow_symlinks
    )


def create_companion(result: str, checker: str) -> int:
    if not supported():
        return PREPUBLICATION_FAILURE

    result_path = os.path.abspath(result)
    parent = os.path.dirname(result_path)
    result_name = os.path.basename(result_path)
    if not RESULT_NAME.fullmatch(result_name) or result_name == "README.md":
        return PREPUBLICATION_FAILURE
    staged_name = result_name + ".commit"

    directory_fd = -1
    staged_fd = -1
    try:
        # Keep unvalidated bytes in an unlinked private file. Privacy/schema
        # rejection must not leave sensitive text under the fixture directory.
        with tempfile.TemporaryFile(prefix="droidmatch-product-usb-input.") as source:
            source_fd = source.fileno()
            os.fchmod(source_fd, 0o600)
            size = copy_stdin(source_fd)
            if size == 0:
                return PREPUBLICATION_FAILURE
            os.fsync(source_fd)
            source_info = os.fstat(source_fd)
            expected_digest = digest_fd(source_fd)
            if (
                not stat.S_ISREG(source_info.st_mode)
                or source_info.st_size != size
                or not validate_snapshot(source_fd, expected_digest, checker)
                or digest_fd(source_fd) != expected_digest
            ):
                return PREPUBLICATION_FAILURE

            directory_flags = (
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
            )
            directory_fd = os.open(parent, directory_flags)
            if (
                stat_entry(directory_fd, result_name) is not None
                or stat_entry(directory_fd, staged_name) is not None
            ):
                return PREPUBLICATION_FAILURE
            staged_flags = (
                os.O_RDWR
                | os.O_CREAT
                | os.O_EXCL
                | os.O_NOFOLLOW
                | os.O_CLOEXEC
            )
            staged_fd = os.open(
                staged_name, staged_flags, 0o600, dir_fd=directory_fd
            )
            copy_fd(source_fd, staged_fd)
            os.fsync(staged_fd)
            os.fsync(directory_fd)

        staged_info = os.fstat(staged_fd)
        expected = identity(staged_info)
        if (
            not stat.S_ISREG(staged_info.st_mode)
            or staged_info.st_size != size
            or staged_info.st_nlink != 1
            or not matching_regular(directory_fd, staged_name, expected, expected_links=1)
            or digest_fd(staged_fd) != expected_digest
            or digest_entry(directory_fd, staged_name, expected) != expected_digest
            or stat_entry(directory_fd, result_name) is not None
        ):
            return PREPUBLICATION_FAILURE
        sys.stdout.write(expected_digest.hex() + "\n")
        return SUCCESS
    except (OSError, ValueError):
        return PREPUBLICATION_FAILURE
    finally:
        if staged_fd >= 0:
            try:
                os.close(staged_fd)
            except OSError:
                pass
        if directory_fd >= 0:
            try:
                os.close(directory_fd)
            except OSError:
                pass


def publish(
    staged: str,
    result: str,
    checker: str,
    required_digest_hex: str,
) -> int:
    if not supported():
        return PREPUBLICATION_FAILURE

    try:
        required_digest = bytes.fromhex(required_digest_hex)
    except ValueError:
        return PREPUBLICATION_FAILURE
    if len(required_digest) != hashlib.sha256().digest_size:
        return PREPUBLICATION_FAILURE

    staged_path = os.path.abspath(staged)
    result_path = os.path.abspath(result)
    parent = os.path.dirname(staged_path)
    if parent != os.path.dirname(result_path):
        return PREPUBLICATION_FAILURE

    staged_name = os.path.basename(staged_path)
    result_name = os.path.basename(result_path)
    if (
        not RESULT_NAME.fullmatch(result_name)
        or result_name == "README.md"
        or staged_name != result_name + ".commit"
    ):
        return PREPUBLICATION_FAILURE

    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        directory_fd = os.open(parent, directory_flags)
    except OSError:
        return PREPUBLICATION_FAILURE

    staged_fd = -1
    result_fd = -1
    result_created = False
    try:
        if stat_entry(directory_fd, result_name) is not None:
            return PREPUBLICATION_FAILURE
        staged_flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC
        try:
            staged_fd = os.open(staged_name, staged_flags, dir_fd=directory_fd)
        except OSError:
            return PREPUBLICATION_FAILURE
        staged_info = os.fstat(staged_fd)
        if (
            not stat.S_ISREG(staged_info.st_mode)
            or staged_info.st_size == 0
            or staged_info.st_size > MAX_EVIDENCE_BYTES
            or staged_info.st_nlink != 1
        ):
            return PREPUBLICATION_FAILURE

        expected = identity(staged_info)
        expected_digest = digest_fd(staged_fd)
        if (
            expected_digest != required_digest
            or not validate_snapshot(staged_fd, expected_digest, checker)
        ):
            return PREPUBLICATION_FAILURE
        if (
            not matching_regular(directory_fd, staged_name, expected, expected_links=1)
            or digest_fd(staged_fd) != expected_digest
            or digest_entry(directory_fd, staged_name, expected) != expected_digest
            or stat_entry(directory_fd, result_name) is not None
        ):
            return PREPUBLICATION_FAILURE

        result_flags = (
            os.O_RDWR
            | os.O_CREAT
            | os.O_EXCL
            | os.O_NOFOLLOW
            | os.O_CLOEXEC
        )
        try:
            result_fd = os.open(result_name, result_flags, 0o600, dir_fd=directory_fd)
            result_created = True
            copy_fd(staged_fd, result_fd)
            os.fsync(result_fd)
            os.fsync(directory_fd)
        except OSError:
            return PUBLICATION_UNCERTAIN

        result_info = os.fstat(result_fd)
        result_expected = identity(result_info)
        if (
            not stat.S_ISREG(result_info.st_mode)
            or result_info.st_size != staged_info.st_size
            or result_info.st_nlink != 1
            or not matching_regular(directory_fd, staged_name, expected, expected_links=1)
            or not matching_regular(
                directory_fd, result_name, result_expected, expected_links=1
            )
            or digest_fd(staged_fd) != expected_digest
            or digest_fd(result_fd) != expected_digest
            or digest_entry(directory_fd, staged_name, expected) != expected_digest
            or digest_entry(directory_fd, result_name, result_expected) != expected_digest
            or not validate_snapshot(result_fd, expected_digest, checker)
            or not matching_regular(directory_fd, staged_name, expected, expected_links=1)
            or not matching_regular(
                directory_fd, result_name, result_expected, expected_links=1
            )
            or digest_fd(staged_fd) != expected_digest
            or digest_fd(result_fd) != expected_digest
            or digest_entry(directory_fd, staged_name, expected) != expected_digest
            or digest_entry(directory_fd, result_name, result_expected) != expected_digest
        ):
            return PUBLICATION_UNCERTAIN
        return SUCCESS
    except (OSError, ValueError):
        return PUBLICATION_UNCERTAIN if result_created else PREPUBLICATION_FAILURE
    finally:
        if result_fd >= 0:
            try:
                os.close(result_fd)
            except OSError:
                pass
        if staged_fd >= 0:
            try:
                os.close(staged_fd)
            except OSError:
                pass
        try:
            os.close(directory_fd)
        except OSError:
            pass


def main() -> int:
    if len(sys.argv) == 4 and sys.argv[1] == "--create-companion":
        return create_companion(sys.argv[2], sys.argv[3])
    if len(sys.argv) != 5:
        return 2
    return publish(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])


if __name__ == "__main__":
    sys.exit(main())
