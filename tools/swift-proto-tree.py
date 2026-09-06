#!/usr/bin/env python3
"""Validate owned generated trees; admit a byte-exact committed predecessor.

中文：仅旧目录迁移可使用当前 HEAD 的完整已提交内容；候选仍必须符合新 schema。
"""

import hashlib
import os
import re
import stat
import subprocess
import sys


def committed_predecessor(repo, output, current_names):
    canonical = os.path.join(os.path.realpath(repo), "mac/Sources/DroidMatchCore/Generated")
    if output != canonical:
        raise RuntimeError("predecessor admission is only for canonical generated sources")
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_NO_REPLACE_OBJECTS="1", GIT_CONFIG_NOSYSTEM="1",
               GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0",
               GIT_GRAFT_FILE=os.devnull, GIT_NO_LAZY_FETCH="1")

    def git(*args):
        return subprocess.check_output(
            ["git", "-C", repo, "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
             *args], env=env, stderr=subprocess.DEVNULL, timeout=10)

    prefix = "mac/Sources/DroidMatchCore/Generated/v1/"
    rows = git("ls-tree", "-r", "-z", "HEAD", "--", "proto/v1", prefix).split(b"\0")
    schemas, blobs = set(), {}
    for row in filter(None, rows):
        metadata, raw_path = row.split(b"\t", 1)
        mode, kind, oid = metadata.decode("ascii").split()
        path = raw_path.decode("utf-8")
        if path.startswith("proto/v1/") and not path.endswith(".proto"):
            continue  # Compatibility manifests/documentation are not protoc inputs.
        if mode != "100644" or kind != "blob":
            raise RuntimeError("committed predecessor contains a non-source node")
        if path.startswith("proto/v1/"):
            name = path[len("proto/v1/"):]
            if not re.fullmatch(r"[a-z][a-z0-9_]*\.proto", name):
                raise RuntimeError("committed schema layout is not recognized")
            schemas.add(name[:-6] + ".pb.swift")
        elif path.startswith(prefix):
            name = path[len(prefix):]
            if not re.fullmatch(r"[a-z][a-z0-9_]*\.pb\.swift", name):
                raise RuntimeError("committed generated layout is not recognized")
            blobs[name] = oid
    if not schemas or schemas != set(blobs) or schemas == current_names:
        raise RuntimeError("no complete differently shaped committed predecessor exists")
    # Object IDs pin one tree lookup even if HEAD later moves. No worktree filters,
    # credentials, network requests or user-controlled shell strings are involved.
    return {name: hashlib.sha256(git("cat-file", "blob", oid)).digest()
            for name, oid in blobs.items()}


def validate(root, synchronize, normalize, allow_previous, repo, output, expected_names):
    expected = set(expected_names)
    root_info = os.lstat(root)
    if not stat.S_ISDIR(root_info.st_mode) or root_info.st_uid != os.geteuid():
        raise RuntimeError("generated root is not an owned directory")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    file_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    root_fd = os.open(root, flags)
    try:
        opened_root = os.fstat(root_fd)
        if (opened_root.st_dev, opened_root.st_ino) != (root_info.st_dev, root_info.st_ino):
            raise RuntimeError("generated root changed while opening")
        if normalize:
            os.fchmod(root_fd, 0o755)
        elif stat.S_IMODE(opened_root.st_mode) != 0o755:
            raise RuntimeError("generated root mode is not canonical")
        if set(os.listdir(root_fd)) != {"v1"}:
            raise RuntimeError("generated root has an unexpected layout")
        v1_info = os.stat("v1", dir_fd=root_fd, follow_symlinks=False)
        if not stat.S_ISDIR(v1_info.st_mode) or v1_info.st_uid != os.geteuid():
            raise RuntimeError("generated v1 node is not an owned directory")
        v1_fd = os.open("v1", flags, dir_fd=root_fd)
        try:
            opened_v1 = os.fstat(v1_fd)
            if (opened_v1.st_dev, opened_v1.st_ino) != (v1_info.st_dev, v1_info.st_ino):
                raise RuntimeError("generated v1 directory changed while opening")
            if normalize:
                os.fchmod(v1_fd, 0o755)
            elif stat.S_IMODE(opened_v1.st_mode) != 0o755:
                raise RuntimeError("generated v1 mode is not canonical")
            actual = set(os.listdir(v1_fd))
            previous_hashes = {}
            if actual != expected and allow_previous and not normalize and not synchronize:
                previous_hashes = committed_predecessor(repo, output, expected)
                expected = set(previous_hashes)
            if actual != expected:
                raise RuntimeError("generated v1 file set is incomplete or unexpected")
            for name in expected:
                info = os.stat(name, dir_fd=v1_fd, follow_symlinks=False)
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                        or info.st_nlink != 1 or info.st_size <= 0):
                    raise RuntimeError("generated source is not a non-empty owned single-link file")
                fd = os.open(name, file_flags, dir_fd=v1_fd)
                try:
                    opened = os.fstat(fd)
                    identity = lambda value: (value.st_dev, value.st_ino, value.st_mode,
                                              value.st_nlink, value.st_uid, value.st_size)
                    if identity(opened) != identity(info):
                        raise RuntimeError("generated source changed while opening")
                    if normalize:
                        os.fchmod(fd, 0o644)
                    elif stat.S_IMODE(opened.st_mode) != 0o644:
                        raise RuntimeError("generated source mode is not canonical")
                    if previous_hashes:
                        digest = hashlib.sha256()
                        while True:
                            block = os.read(fd, 1024 * 1024)
                            if not block:
                                break
                            digest.update(block)
                        after = os.fstat(fd)
                        if (digest.digest() != previous_hashes[name]
                                or identity(after) != identity(opened)
                                or after.st_mtime_ns != opened.st_mtime_ns
                                or after.st_ctime_ns != opened.st_ctime_ns):
                            raise RuntimeError("predecessor differs from committed generated bytes")
                    if synchronize:
                        os.fsync(fd)
                finally:
                    os.close(fd)
            if synchronize:
                os.fsync(v1_fd)
        finally:
            os.close(v1_fd)
        if synchronize:
            os.fsync(root_fd)
    finally:
        os.close(root_fd)


if __name__ == "__main__":
    root, sync, normalize, previous, repo, output, *names = sys.argv[1:]
    validate(root, sync == "true", normalize == "true", previous == "true", repo, output, names)
