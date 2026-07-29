#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
# shellcheck source=tools/swift-build-compat.sh
source "${repo_root}/tools/swift-build-compat.sh"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

generator="${repo_root}/tools/generate-swift-proto.sh"
committed_dir="${repo_root}/mac/Sources/DroidMatchCore/Generated"
if [[ -n "${DROIDMATCH_TEST_SWIFT_PROTO_GENERATOR:-}" \
    || -n "${DROIDMATCH_TEST_SWIFT_PROTO_COMMITTED_DIR:-}" ]]; then
  [[ "${DROIDMATCH_SWIFT_PROTO_TEST_MODE:-0}" == "1" ]] \
    || fail 'Swift protobuf test overrides require DROIDMATCH_SWIFT_PROTO_TEST_MODE=1.'
  generator="${DROIDMATCH_TEST_SWIFT_PROTO_GENERATOR:-${generator}}"
  committed_dir="${DROIDMATCH_TEST_SWIFT_PROTO_COMMITTED_DIR:-${committed_dir}}"
fi
[[ -f "${generator}" && ! -L "${generator}" ]] \
  || fail 'Swift protobuf generator is missing or unsafe.'
[[ -d "${committed_dir}" && ! -L "${committed_dir}" ]] \
  || fail 'Committed Swift protobuf tree is missing or unsafe.'

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-swift-proto-freshness.XXXXXX")"
trap 'rm -rf "${temporary_root}"' EXIT
generated_dir="${temporary_root}/Generated"

droidmatch_swift_package_resolved="${repo_root}/mac/Package.resolved"
droidmatch_swift_lock_initial_snapshot="$(
  droidmatch_swift_lock_snapshot "${droidmatch_swift_package_resolved}"
)" || fail 'mac/Package.resolved is missing or unsafe.'

# The authoritative path always forces generate-swift-proto.sh to bootstrap the
# exact Package.resolved pin. Environment overrides remain useful for the
# interactive regeneration command, but cannot select a different CI plugin,
# checkout, or lockfile here.
droidmatch_run_with_immutable_swift_lock \
  env \
    -u PROTOC_GEN_SWIFT \
    -u SWIFT_PROTOBUF_PACKAGE_RESOLVED \
    -u SWIFT_PROTOBUF_CHECKOUT \
    -u SWIFT_PROTO_OUTPUT_DIR \
    SWIFT_PROTO_OUTPUT_DIR="${generated_dir}" \
    bash "${generator}"

python3 - "${repo_root}/proto/v1" "${committed_dir}" "${generated_dir}" <<'PY'
import hashlib
import os
import stat
import sys
from pathlib import Path

proto_root = Path(sys.argv[1])
committed_root = Path(sys.argv[2])
generated_root = Path(sys.argv[3])
expected = {path.stem + ".pb.swift" for path in proto_root.glob("*.proto")}
if not expected:
    raise SystemExit("no v1 protobuf schemas were found")


def snapshot_tree(root, label):
    root_info = os.lstat(root)
    if (not stat.S_ISDIR(root_info.st_mode)
            or root_info.st_uid != os.geteuid()
            or stat.S_IMODE(root_info.st_mode) != 0o755):
        raise RuntimeError(f"{label} root is not an owned directory")
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    file_flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        directory_flags |= os.O_NOFOLLOW
        file_flags |= os.O_NOFOLLOW
    root_fd = os.open(root, directory_flags)
    try:
        opened_root = os.fstat(root_fd)
        if (opened_root.st_dev, opened_root.st_ino) != (
                root_info.st_dev, root_info.st_ino):
            raise RuntimeError(f"{label} root changed while opening")
        if set(os.listdir(root_fd)) != {"v1"}:
            raise RuntimeError(f"{label} root has an unexpected file set")
        v1_info = os.stat("v1", dir_fd=root_fd, follow_symlinks=False)
        if (not stat.S_ISDIR(v1_info.st_mode)
                or v1_info.st_uid != os.geteuid()
                or stat.S_IMODE(v1_info.st_mode) != 0o755):
            raise RuntimeError(f"{label} v1 node is not an owned directory")
        v1_fd = os.open("v1", directory_flags, dir_fd=root_fd)
        try:
            opened_v1 = os.fstat(v1_fd)
            if (opened_v1.st_dev, opened_v1.st_ino) != (
                    v1_info.st_dev, v1_info.st_ino):
                raise RuntimeError(f"{label} v1 directory changed while opening")
            actual = set(os.listdir(v1_fd))
            if actual != expected:
                missing = sorted(expected - actual)
                extra = sorted(actual - expected)
                detail = []
                if missing:
                    detail.append("missing=" + ",".join(missing))
                if extra:
                    detail.append("extra=" + ",".join(extra))
                raise RuntimeError(
                    f"{label} generated file set differs: {' '.join(detail)}"
                )
            snapshots = {}
            for name in expected:
                info = os.stat(name, dir_fd=v1_fd, follow_symlinks=False)
                if (not stat.S_ISREG(info.st_mode)
                        or info.st_uid != os.geteuid()
                        or info.st_nlink != 1
                        or info.st_size <= 0
                        or stat.S_IMODE(info.st_mode) != 0o644):
                    raise RuntimeError(
                        f"{label} file is unsafe or empty: v1/{name}"
                    )
                descriptor = os.open(name, file_flags, dir_fd=v1_fd)
                try:
                    opened = os.fstat(descriptor)
                    identity = (
                        info.st_dev, info.st_ino, info.st_mode, info.st_uid,
                        info.st_nlink, info.st_size, info.st_mtime_ns,
                    )
                    opened_identity = (
                        opened.st_dev, opened.st_ino, opened.st_mode,
                        opened.st_uid, opened.st_nlink, opened.st_size,
                        opened.st_mtime_ns,
                    )
                    if opened_identity != identity:
                        raise RuntimeError(
                            f"{label} file changed while opening: v1/{name}"
                        )
                    digest = hashlib.sha256()
                    while True:
                        chunk = os.read(descriptor, 64 * 1024)
                        if not chunk:
                            break
                        digest.update(chunk)
                    after = os.fstat(descriptor)
                    after_identity = (
                        after.st_dev, after.st_ino, after.st_mode,
                        after.st_uid, after.st_nlink, after.st_size,
                        after.st_mtime_ns,
                    )
                    if after_identity != opened_identity:
                        raise RuntimeError(
                            f"{label} file changed while reading: v1/{name}"
                        )
                    snapshots[name] = digest.hexdigest()
                finally:
                    os.close(descriptor)
            return snapshots
        finally:
            os.close(v1_fd)
    finally:
        os.close(root_fd)


committed = snapshot_tree(committed_root, "committed")
generated = snapshot_tree(generated_root, "fresh")
mismatches = [
    f"v1/{name}"
    for name in sorted(expected)
    if committed[name] != generated[name]
]
if mismatches:
    raise RuntimeError(
        "committed Swift protobuf sources are stale: " + ", ".join(mismatches)
    )
PY

printf 'Swift protobuf generated sources match the lockfile-pinned generator.\n'
printf '中文：Swift protobuf 生成源码与锁文件固定的生成器一致。\n'
