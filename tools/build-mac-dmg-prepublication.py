#!/usr/bin/env python3

"""Safely initialize, validate, or retire private DMG transaction nodes."""

from __future__ import annotations

import json
import os
import stat
import sys
from typing import Any, Optional

from atomic_rename import EXCLUSIVE, rename_at
from process_instance_identity import checked_token, process_identity


REGULAR_NAMES = {
    "owner-pid",
    "owner-instance",
    "state",
    ".state.next",
    "prepublication",
    "identities",
    ".identities.next",
    "previous.dmg",
    "previous.sha256",
    ".restore-dmg",
    ".restore-sha256",
}
ALLOWED_NAMES = REGULAR_NAMES | {"candidate"}


def open_flags(*, directory: bool = False) -> int:
    flags = os.O_RDONLY
    if directory and hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    return flags


def require_private_directory(info: os.stat_result, label: str) -> None:
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.geteuid()
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        raise RuntimeError(f"{label} is not a private owned directory")


def validate_layout(root: str, image_name: str) -> None:
    root_info = os.lstat(root)
    require_private_directory(root_info, "transaction root")
    for name in os.listdir(root):
        if name not in ALLOWED_NAMES:
            raise RuntimeError("unexpected transaction node")
        path = os.path.join(root, name)
        info = os.lstat(path)
        if name != "candidate":
            if not stat.S_ISREG(info.st_mode):
                raise RuntimeError("transaction node is not regular")
            continue
        require_private_directory(info, "candidate")
        for child in os.listdir(path):
            if child not in {image_name, image_name + ".sha256"}:
                raise RuntimeError("unexpected candidate node")
            if not stat.S_ISREG(os.lstat(os.path.join(path, child)).st_mode):
                raise RuntimeError("candidate node is not regular")


def identity(info: os.stat_result) -> dict[str, int]:
    return {"dev": info.st_dev, "ino": info.st_ino}


def checked_identity(value: Any) -> dict[str, int]:
    if not isinstance(value, dict) or set(value) != {"dev", "ino"}:
        raise RuntimeError("invalid pre-publication identity")
    if not all(isinstance(value[key], int) and value[key] >= 0 for key in value):
        raise RuntimeError("invalid pre-publication identity")
    return value


def transaction_parts(root: str, image: str) -> tuple[str, str, str]:
    if not os.path.isabs(root) or not os.path.isabs(image):
        raise RuntimeError("publication paths must be absolute")
    parent = os.path.dirname(image)
    image_name = os.path.basename(image)
    expected_root_name = f".{image_name}.publication-transaction"
    if os.path.dirname(root) != parent or os.path.basename(root) != expected_root_name:
        raise RuntimeError("transaction path does not match the output")
    return parent, expected_root_name, image_name


def read_regular_at(
    directory_fd: int,
    name: str,
    *,
    maximum: int,
    private: bool = False,
) -> tuple[bytes, os.stat_result]:
    fd = os.open(name, open_flags(), dir_fd=directory_fd)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size > maximum:
            raise RuntimeError("unsafe transaction metadata")
        if before.st_nlink != 1:
            raise RuntimeError("transaction metadata is externally linked")
        if private and (
            before.st_uid != os.geteuid() or stat.S_IMODE(before.st_mode) != 0o600
        ):
            raise RuntimeError("transaction metadata is not private")
        contents = bytearray()
        while len(contents) < before.st_size:
            chunk = os.read(fd, before.st_size - len(contents))
            if not chunk:
                raise RuntimeError("transaction metadata was truncated")
            contents.extend(chunk)
        if os.read(fd, 1):
            raise RuntimeError("transaction metadata grew while read")
        after = os.fstat(fd)
        if identity(before) != identity(after) or before.st_size != after.st_size:
            raise RuntimeError("transaction metadata changed while read")
        return bytes(contents), before
    finally:
        os.close(fd)


def write_private_at(directory_fd: int, name: str, contents: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(name, flags, 0o600, dir_fd=directory_fd)
    try:
        written = 0
        while written < len(contents):
            count = os.write(fd, contents[written:])
            if count <= 0:
                raise RuntimeError("transaction metadata write made no progress")
            written += count
        os.fsync(fd)
    finally:
        os.close(fd)


def marker_contents(
    root_info: os.stat_result,
    parent_info: os.stat_result,
    owner_pid: int,
    owner_instance: str,
    image_name: str,
) -> bytes:
    payload = {
        "version": 2,
        "root": identity(root_info),
        "parent": identity(parent_info),
        "ownerPid": owner_pid,
        "ownerInstance": owner_instance,
        "imageName": image_name,
    }
    return (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "ascii"
    )


def write_prepublication(
    root: str, image: str, owner_pid: int, owner_instance: str
) -> None:
    owner_instance = checked_token(owner_instance)
    parent, root_name, image_name = transaction_parts(root, image)
    parent_fd = os.open(parent, open_flags(directory=True))
    try:
        root_fd = os.open(root_name, open_flags(directory=True), dir_fd=parent_fd)
        try:
            root_info = os.fstat(root_fd)
            require_private_directory(root_info, "transaction root")
            if set(os.listdir(root_fd)) != {"owner-pid", "owner-instance"}:
                raise RuntimeError("unexpected transaction initialization layout")
            owner_contents, _ = read_regular_at(
                root_fd, "owner-pid", maximum=64, private=True
            )
            if owner_contents.decode("ascii").strip() != str(owner_pid):
                raise RuntimeError("transaction owner does not match")
            instance_contents, _ = read_regular_at(
                root_fd, "owner-instance", maximum=256, private=True
            )
            if checked_token(instance_contents.decode("ascii").strip()) != owner_instance:
                raise RuntimeError("transaction owner instance does not match")
            write_private_at(
                root_fd,
                "prepublication",
                marker_contents(
                    root_info,
                    os.fstat(parent_fd),
                    owner_pid,
                    owner_instance,
                    image_name,
                ),
            )
            os.fsync(root_fd)
        finally:
            os.close(root_fd)
    finally:
        os.close(parent_fd)


def backup_regular(source_path: str, backup_path: str) -> None:
    before = os.lstat(source_path)
    if not stat.S_ISREG(before.st_mode):
        raise RuntimeError("source is not a regular file")
    os.link(source_path, backup_path, follow_symlinks=False)
    after = os.lstat(backup_path)
    if not stat.S_ISREG(after.st_mode) or not same_node(before, after):
        os.unlink(backup_path)
        raise RuntimeError("source changed while it was backed up")


def same_node(left: os.stat_result, right: os.stat_result) -> bool:
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def require_regular_path_at(directory_fd: int, name: str) -> os.stat_result:
    fd = os.open(name, open_flags(), dir_fd=directory_fd)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise RuntimeError("publication node is not regular")
        return info
    finally:
        os.close(fd)


def open_candidate(
    root_fd: int, image_name: str, *, private_files: bool
) -> tuple[Optional[int], Optional[os.stat_result], dict[str, os.stat_result]]:
    try:
        candidate_fd = os.open(
            "candidate", open_flags(directory=True), dir_fd=root_fd
        )
    except FileNotFoundError:
        return None, None, {}
    try:
        candidate_info = os.fstat(candidate_fd)
        require_private_directory(candidate_info, "candidate")
        names = set(os.listdir(candidate_fd))
        if not names <= {image_name, image_name + ".sha256"}:
            raise RuntimeError("unexpected candidate node")
        children = {}
        for name in names:
            info = require_regular_path_at(candidate_fd, name)
            if private_files and (info.st_uid != os.geteuid() or info.st_nlink != 1):
                raise RuntimeError("candidate node is not privately owned")
            children[name] = info
        return candidate_fd, candidate_info, children
    except BaseException:
        os.close(candidate_fd)
        raise


def same_identity(left: os.stat_result, right: os.stat_result) -> bool:
    return (
        left.st_dev,
        left.st_ino,
        left.st_mode,
    ) == (
        right.st_dev,
        right.st_ino,
        right.st_mode,
    )


def remove_opened_transaction(
    parent_fd: int,
    root_fd: int,
    root_name: str,
    image_name: str,
    expected_names: set[str],
    *,
    private_candidate_files: bool = False,
) -> None:
    if set(os.listdir(root_fd)) != expected_names:
        raise RuntimeError("transaction layout changed before cleanup")
    root_info = os.fstat(root_fd)
    root_nodes = {}
    for name in expected_names - {"candidate"}:
        info = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
        if not stat.S_ISREG(info.st_mode):
            raise RuntimeError("transaction node is not regular")
        root_nodes[name] = info
    candidate_fd, candidate_info, candidate_nodes = open_candidate(
        root_fd, image_name, private_files=private_candidate_files
    )
    if (candidate_fd is None) != ("candidate" not in expected_names):
        if candidate_fd is not None:
            os.close(candidate_fd)
        raise RuntimeError("candidate layout changed before cleanup")
    if candidate_fd is not None and candidate_info is not None:
        try:
            current_candidate = os.stat(
                "candidate", dir_fd=root_fd, follow_symlinks=False
            )
            if not same_identity(current_candidate, candidate_info):
                raise RuntimeError("candidate changed before cleanup")
            if set(os.listdir(candidate_fd)) != set(candidate_nodes):
                raise RuntimeError("candidate changed before cleanup")
            for name in sorted(candidate_nodes):
                current = os.stat(name, dir_fd=candidate_fd, follow_symlinks=False)
                if not same_identity(current, candidate_nodes[name]):
                    raise RuntimeError("candidate node changed before cleanup")
                os.unlink(name, dir_fd=candidate_fd)
            os.rmdir("candidate", dir_fd=root_fd)
        finally:
            os.close(candidate_fd)
    for name in sorted(root_nodes):
        current = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
        if not same_identity(current, root_nodes[name]):
            raise RuntimeError("transaction node changed before cleanup")
        os.unlink(name, dir_fd=root_fd)
    if os.listdir(root_fd):
        raise RuntimeError("transaction was not empty after cleanup")
    current_root = os.stat(root_name, dir_fd=parent_fd, follow_symlinks=False)
    if not same_identity(current_root, root_info):
        raise RuntimeError("transaction root changed before cleanup")
    os.rmdir(root_name, dir_fd=parent_fd)
    os.fsync(parent_fd)


def remove_validated(root: str, image_name: str) -> None:
    if not os.path.isabs(root) or os.path.basename(image_name) != image_name:
        raise RuntimeError("invalid transaction path")
    root_name = os.path.basename(root)
    if root_name != f".{image_name}.publication-transaction":
        raise RuntimeError("transaction path does not match the output")
    parent_fd = os.open(os.path.dirname(root), open_flags(directory=True))
    try:
        root_fd = os.open(root_name, open_flags(directory=True), dir_fd=parent_fd)
        try:
            require_private_directory(os.fstat(root_fd), "transaction root")
            names = set(os.listdir(root_fd))
            if not names <= ALLOWED_NAMES:
                raise RuntimeError("unexpected transaction node")
            remove_opened_transaction(
                parent_fd, root_fd, root_name, image_name, names
            )
        finally:
            os.close(root_fd)
    finally:
        os.close(parent_fd)


def path_exists_at(directory_fd: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def rename_exclusive_at(directory_fd: int, source: str, destination: str) -> None:
    rename_at(directory_fd, source, directory_fd, destination, EXCLUSIVE)


def remove_stale_initializer(
    parent_fd: int, initializer_name: str, image_name: str
) -> None:
    root_fd = os.open(
        initializer_name, open_flags(directory=True), dir_fd=parent_fd
    )
    try:
        require_private_directory(os.fstat(root_fd), "transaction initializer")
        names = set(os.listdir(root_fd))
        if not names <= {"owner-pid", "owner-instance", "prepublication", "state"}:
            raise RuntimeError("unexpected transaction initializer node")
        for name in names:
            info = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.geteuid()
                or info.st_nlink != 1
                or stat.S_IMODE(info.st_mode) != 0o600
            ):
                raise RuntimeError("unsafe transaction initializer node")
        remove_opened_transaction(
            parent_fd, root_fd, initializer_name, image_name, names
        )
    finally:
        os.close(root_fd)


def initialize_transaction(
    root: str, image: str, owner_pid: int, owner_instance: str
) -> None:
    owner_instance = checked_token(owner_instance)
    parent, root_name, image_name = transaction_parts(root, image)
    initializer_prefix = root_name + ".initializing."
    initializer_name = initializer_prefix + str(owner_pid)
    parent_fd = os.open(parent, open_flags(directory=True))
    try:
        if path_exists_at(parent_fd, root_name):
            raise RuntimeError("publication transaction already exists")
        for name in os.listdir(parent_fd):
            if not name.startswith(initializer_prefix):
                continue
            pid_text = name[len(initializer_prefix) :]
            if not pid_text.isdigit() or int(pid_text) <= 0:
                raise RuntimeError("invalid transaction initializer name")
            initializer_pid = int(pid_text)
            initializer_fd = os.open(
                name, open_flags(directory=True), dir_fd=parent_fd
            )
            try:
                names = set(os.listdir(initializer_fd))
                if "owner-instance" in names:
                    encoded_instance, _ = read_regular_at(
                        initializer_fd,
                        "owner-instance",
                        maximum=256,
                        private=True,
                    )
                    initializer_instance = checked_token(
                        encoded_instance.decode("ascii").strip()
                    )
                    if process_identity(initializer_pid) == initializer_instance:
                        raise RuntimeError("another transaction initializer is active")
                else:
                    try:
                        os.kill(initializer_pid, 0)
                    except ProcessLookupError:
                        pass
                    else:
                        raise RuntimeError(
                            "legacy transaction initializer owner may be active"
                        )
            finally:
                os.close(initializer_fd)
            remove_stale_initializer(parent_fd, name, image_name)
        os.mkdir(initializer_name, 0o700, dir_fd=parent_fd)
        initializer_fd = os.open(
            initializer_name, open_flags(directory=True), dir_fd=parent_fd
        )
        try:
            initializer_info = os.fstat(initializer_fd)
            require_private_directory(initializer_info, "transaction initializer")
            write_private_at(
                initializer_fd, "owner-pid", (str(owner_pid) + "\n").encode("ascii")
            )
            write_private_at(
                initializer_fd,
                "owner-instance",
                (owner_instance + "\n").encode("ascii"),
            )
            write_private_at(
                initializer_fd,
                "prepublication",
                marker_contents(
                    initializer_info,
                    os.fstat(parent_fd),
                    owner_pid,
                    owner_instance,
                    image_name,
                ),
            )
            write_private_at(initializer_fd, "state", b"building\n")
            os.fsync(initializer_fd)
            rename_exclusive_at(parent_fd, initializer_name, root_name)
            published_info = os.stat(
                root_name, dir_fd=parent_fd, follow_symlinks=False
            )
            if not same_identity(published_info, initializer_info):
                raise RuntimeError("transaction initializer publication changed")
            os.fsync(parent_fd)
        finally:
            os.close(initializer_fd)
    finally:
        os.close(parent_fd)


def remove_unidentified(root: str, image: str) -> None:
    parent, root_name, image_name = transaction_parts(root, image)
    parent_fd = os.open(parent, open_flags(directory=True))
    try:
        root_fd = os.open(root_name, open_flags(directory=True), dir_fd=parent_fd)
        try:
            root_info = os.fstat(root_fd)
            require_private_directory(root_info, "transaction root")
            names = set(os.listdir(root_fd))
            if not names:
                remove_opened_transaction(
                    parent_fd, root_fd, root_name, image_name, names
                )
                return
            if "owner-pid" not in names:
                raise RuntimeError("unowned transaction fragment is not empty")
            owner_contents, _ = read_regular_at(
                root_fd, "owner-pid", maximum=64, private=True
            )
            owner_text = owner_contents.decode("ascii").strip()
            if not owner_text.isdigit() or int(owner_text) <= 0:
                raise RuntimeError("transaction owner is invalid")
            owner_pid = int(owner_text)
            owner_instance: Optional[str] = None
            if "owner-instance" in names:
                instance_contents, _ = read_regular_at(
                    root_fd, "owner-instance", maximum=256, private=True
                )
                owner_instance = checked_token(
                    instance_contents.decode("ascii").strip()
                )
                if process_identity(owner_pid) == owner_instance:
                    raise RuntimeError("transaction owner is active")
            else:
                try:
                    os.kill(owner_pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise RuntimeError("legacy transaction owner may be active")

            if names in ({"owner-pid"}, {"owner-pid", "owner-instance"}):
                remove_opened_transaction(
                    parent_fd, root_fd, root_name, image_name, names
                )
                return
            has_marker = "prepublication" in names
            has_state = "state" in names
            if not has_marker and not has_state:
                raise RuntimeError("transaction fragment metadata is incomplete")
            allowed_building = {
                "owner-pid",
                "owner-instance",
                "state",
                "prepublication",
            } | {
                "candidate",
                ".identities.next",
                "previous.dmg",
                "previous.sha256",
            }
            if has_state:
                if not names <= allowed_building:
                    raise RuntimeError("unexpected pre-publication transaction node")
                state_contents, _ = read_regular_at(
                    root_fd, "state", maximum=128, private=True
                )
                if state_contents.decode("ascii").strip() != "building":
                    raise RuntimeError("transaction is not pre-publication")
            else:
                allowed_initial = {
                    "owner-pid",
                    "owner-instance",
                    "prepublication",
                    ".state.next",
                }
                if not has_marker or not names <= allowed_initial:
                    raise RuntimeError("unexpected initialization transaction node")
                if ".state.next" in names:
                    state_next, _ = read_regular_at(
                        root_fd, ".state.next", maximum=128, private=True
                    )
                    if state_next not in (b"", b"building\n"):
                        raise RuntimeError("invalid temporary initial state")

            if has_marker:
                encoded_marker, _ = read_regular_at(
                    root_fd, "prepublication", maximum=4096, private=True
                )
                payload = json.loads(encoded_marker.decode("ascii"))
                v1_fields = {
                    "version",
                    "root",
                    "parent",
                    "ownerPid",
                    "imageName",
                }
                v2_fields = v1_fields | {"ownerInstance"}
                if not isinstance(payload, dict):
                    raise RuntimeError("invalid pre-publication marker")
                if set(payload) == v1_fields:
                    if payload["version"] != 1 or owner_instance is not None:
                        raise RuntimeError("legacy pre-publication marker is inconsistent")
                    marker_owner_instance = None
                elif set(payload) == v2_fields:
                    if payload["version"] != 2 or owner_instance is None:
                        raise RuntimeError("v2 pre-publication marker is inconsistent")
                    marker_owner_instance = checked_token(payload["ownerInstance"])
                else:
                    raise RuntimeError("invalid pre-publication marker")
                if (
                    checked_identity(payload["root"]) != identity(root_info)
                    or checked_identity(payload["parent"])
                    != identity(os.fstat(parent_fd))
                    or payload["ownerPid"] != owner_pid
                    or marker_owner_instance != owner_instance
                    or payload["imageName"] != image_name
                ):
                    raise RuntimeError("pre-publication marker does not match")
            elif not has_state:
                raise RuntimeError("transaction fragment lacks a state and marker")

            if ".identities.next" in names:
                next_info = require_regular_path_at(root_fd, ".identities.next")
                if (
                    next_info.st_uid != os.geteuid()
                    or next_info.st_nlink != 1
                    or next_info.st_size > 16384
                ):
                    raise RuntimeError("unsafe temporary identities")
            canonical_names = {
                "previous.dmg": image_name,
                "previous.sha256": image_name + ".sha256",
            }
            for backup_name, canonical_name in canonical_names.items():
                if backup_name in names:
                    backup_info = require_regular_path_at(root_fd, backup_name)
                    canonical_info = require_regular_path_at(parent_fd, canonical_name)
                    if not same_node(backup_info, canonical_info):
                        raise RuntimeError(
                            "pre-publication backup is no longer canonical"
                        )

            if "identities" in names:
                raise RuntimeError("unexpected pre-publication transaction node")
            remove_opened_transaction(
                parent_fd,
                root_fd,
                root_name,
                image_name,
                names,
                private_candidate_files=True,
            )
        finally:
            os.close(root_fd)
    finally:
        os.close(parent_fd)


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(2)
    action = sys.argv[1]
    if action == "validate-layout" and len(sys.argv) == 4:
        validate_layout(sys.argv[2], sys.argv[3])
    elif action == "record" and len(sys.argv) == 6:
        write_prepublication(sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5])
    elif action == "recover-unidentified" and len(sys.argv) == 4:
        remove_unidentified(sys.argv[2], sys.argv[3])
    elif action == "initialize" and len(sys.argv) == 6:
        initialize_transaction(sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5])
    elif action == "remove-validated" and len(sys.argv) == 4:
        remove_validated(sys.argv[2], sys.argv[3])
    elif action == "backup" and len(sys.argv) == 4:
        backup_regular(sys.argv[2], sys.argv[3])
    else:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
