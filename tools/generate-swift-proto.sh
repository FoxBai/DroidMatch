#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

protoc_bin="${PROTOC:-$(command -v protoc || true)}"
if [[ -z "${protoc_bin}" || ! -x "${protoc_bin}" ]]; then
  printf 'protoc is required. Install it with: brew install protobuf\n' >&2
  exit 1
fi

if [[ "${PROTOC_GEN_SWIFT+x}" == "x" ]]; then
  protoc_gen_swift="${PROTOC_GEN_SWIFT}"
else
  "${BASH}" "${repo_root}/tools/bootstrap-swift-protobuf.sh"
  protoc_gen_swift="${repo_root}/.tools/bin/protoc-gen-swift"
fi
if [[ ! -x "${protoc_gen_swift}" ]]; then
  printf 'protoc-gen-swift not found or not executable: %s\n' \
    "${protoc_gen_swift:-<empty>}" >&2
  exit 1
fi

output_input="${SWIFT_PROTO_OUTPUT_DIR:-mac/Sources/DroidMatchCore/Generated}"
output_parent_input="$(dirname "${output_input}")"
output_basename="$(basename "${output_input}")"
if [[ -z "${output_basename}" || "${output_basename}" == "." \
    || "${output_basename}" == ".." || "${output_basename}" == "/" ]]; then
  printf 'Swift protobuf output must name a concrete directory.\n' >&2
  exit 1
fi
mkdir -p "${output_parent_input}"
output_parent="$(cd "${output_parent_input}" && pwd -P)"
output_dir="${output_parent}/${output_basename}"
transaction_dir="${output_parent}/.${output_basename}.transaction"
transaction_owned=false
umask 077

expected_generated_names=()
for proto_path in proto/v1/*.proto; do
  expected_generated_names+=("$(basename "${proto_path}" .proto).pb.swift")
done

generated_tree_safe() {
  local tree_path="$1"
  local synchronize="${2:-false}"
  local normalize="${3:-false}"
  python3 -c '
import os
import stat
import sys

root, synchronize, normalize, *expected_names = sys.argv[1:]
expected = set(expected_names)
root_info = os.lstat(root)
if not stat.S_ISDIR(root_info.st_mode) or root_info.st_uid != os.geteuid():
    raise RuntimeError("generated root is not an owned directory")
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
file_flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    file_flags |= os.O_NOFOLLOW
root_fd = os.open(root, flags)
try:
    opened_root = os.fstat(root_fd)
    if (opened_root.st_dev, opened_root.st_ino) != (root_info.st_dev, root_info.st_ino):
        raise RuntimeError("generated root changed while opening")
    if normalize == "true":
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
        if normalize == "true":
            os.fchmod(v1_fd, 0o755)
        elif stat.S_IMODE(opened_v1.st_mode) != 0o755:
            raise RuntimeError("generated v1 mode is not canonical")
        if set(os.listdir(v1_fd)) != expected:
            raise RuntimeError("generated v1 file set is incomplete or unexpected")
        for name in expected:
            info = os.stat(name, dir_fd=v1_fd, follow_symlinks=False)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or info.st_nlink != 1 or info.st_size <= 0):
                raise RuntimeError("generated source is not a non-empty owned single-link file")
            fd = os.open(name, file_flags, dir_fd=v1_fd)
            try:
                opened = os.fstat(fd)
                stable = (opened.st_dev, opened.st_ino, opened.st_mode,
                          opened.st_nlink, opened.st_uid, opened.st_size)
                expected_info = (info.st_dev, info.st_ino, info.st_mode,
                                 info.st_nlink, info.st_uid, info.st_size)
                if stable != expected_info:
                    raise RuntimeError("generated source changed while opening")
                if normalize == "true":
                    os.fchmod(fd, 0o644)
                elif stat.S_IMODE(opened.st_mode) != 0o644:
                    raise RuntimeError("generated source mode is not canonical")
                if synchronize == "true":
                    os.fsync(fd)
            finally:
                os.close(fd)
        if synchronize == "true":
            os.fsync(v1_fd)
    finally:
        os.close(v1_fd)
    if synchronize == "true":
        os.fsync(root_fd)
finally:
    os.close(root_fd)
' "${tree_path}" "${synchronize}" "${normalize}" \
    "${expected_generated_names[@]}" \
    >/dev/null 2>&1
}

node_identity() {
  python3 -c '
import os, stat, sys
info = os.lstat(sys.argv[1])
if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
    raise RuntimeError("publication node is not an owned directory")
print(f"{info.st_dev}:{info.st_ino}")
' "$1" 2>/dev/null
}

node_matches_identity() {
  local node_path="$1"
  local expected_identity="$2"
  [[ -e "${node_path}" && ! -L "${node_path}" ]] || return 1
  [[ "$(node_identity "${node_path}")" == "${expected_identity}" ]]
}

transaction_snapshot() {
  local expected_identity="${1:-}"
  python3 -c '
import os
import stat
import sys

operation = "snapshot-proto-transaction"
root, expected_identity = sys.argv[1:]
parent = os.path.dirname(root)
root_name = os.path.basename(root)
directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
file_flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    directory_flags |= os.O_NOFOLLOW
    file_flags |= os.O_NOFOLLOW

def identity(info):
    return f"{info.st_dev}:{info.st_ino}"

def read_marker(root_fd, name, required):
    try:
        info = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
    except FileNotFoundError:
        if required:
            raise RuntimeError("transaction marker is missing")
        return "-"
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
            or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_size <= 0 or info.st_size > 256):
        raise RuntimeError("unsafe transaction marker")
    fd = os.open(name, file_flags, dir_fd=root_fd)
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino, opened.st_mode, opened.st_nlink,
                opened.st_uid, opened.st_size) != (info.st_dev, info.st_ino,
                info.st_mode, info.st_nlink, info.st_uid, info.st_size):
            raise RuntimeError("transaction marker changed while opening")
        data = os.read(fd, 257)
    finally:
        os.close(fd)
    if len(data) != info.st_size or not data.endswith(b"\n") or b"\n" in data[:-1]:
        raise RuntimeError("transaction marker is malformed")
    value = data[:-1].decode("ascii")
    if not value or "|" in value:
        raise RuntimeError("transaction marker has an invalid value")
    return value

parent_fd = os.open(parent, directory_flags)
try:
    root_info = os.stat(root_name, dir_fd=parent_fd, follow_symlinks=False)
    if (not stat.S_ISDIR(root_info.st_mode) or root_info.st_uid != os.geteuid()
            or stat.S_IMODE(root_info.st_mode) != 0o700):
        raise RuntimeError("transaction root is not a private owned directory")
    root_fd = os.open(root_name, directory_flags, dir_fd=parent_fd)
    try:
        opened_root = os.fstat(root_fd)
        root_identity = identity(opened_root)
        if root_identity != identity(root_info):
            raise RuntimeError("transaction root changed while opening")
        if expected_identity and root_identity != expected_identity:
            raise RuntimeError("transaction root identity changed")
        regular = {
            "format", "owner-pid", "state", ".state.next",
            "candidate-id", ".candidate-id.next",
            "output-id", ".output-id.next",
        }
        names = set(os.listdir(root_fd))
        if not {"format", "owner-pid", "state"}.issubset(names):
            raise RuntimeError("transaction ownership markers are missing")
        for name in names:
            info = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
            if name in regular:
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                        or info.st_nlink != 1
                        or stat.S_IMODE(info.st_mode) != 0o600):
                    raise RuntimeError("unsafe transaction marker")
            elif name == "staging":
                if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
                    raise RuntimeError("unsafe transaction staging directory")
            else:
                raise RuntimeError("unexpected transaction node")
        format_value = read_marker(root_fd, "format", True)
        if format_value != "droidmatch-swift-proto-publication-v2":
            raise RuntimeError("transaction format marker is invalid")
        owner = read_marker(root_fd, "owner-pid", True)
        state = read_marker(root_fd, "state", True)
        candidate = read_marker(root_fd, "candidate-id", False)
        output = read_marker(root_fd, "output-id", False)
        print("|".join((root_identity, owner, state, candidate, output)))
    finally:
        os.close(root_fd)
finally:
    os.close(parent_fd)
' "${transaction_dir}" "${expected_identity}" 2>/dev/null
}

remove_transaction_tree() {
  local expected_identity="$1"
  if ! python3 -c '
import os
import stat
import sys

operation = "remove-proto-transaction"
root, expected_identity = sys.argv[1:]
parent = os.path.dirname(root)
root_name = os.path.basename(root)
directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
file_flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    directory_flags |= os.O_NOFOLLOW
    file_flags |= os.O_NOFOLLOW

def identity(info):
    return f"{info.st_dev}:{info.st_ino}"

def remove_contents(directory_fd):
    for name in os.listdir(directory_fd):
        info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            child_fd = os.open(name, directory_flags, dir_fd=directory_fd)
            try:
                opened = os.fstat(child_fd)
                if identity(opened) != identity(info):
                    raise RuntimeError("transaction directory changed")
                remove_contents(child_fd)
            finally:
                os.close(child_fd)
            os.rmdir(name, dir_fd=directory_fd)
        else:
            os.unlink(name, dir_fd=directory_fd)

parent_fd = os.open(parent, directory_flags)
try:
    root_info = os.stat(root_name, dir_fd=parent_fd, follow_symlinks=False)
    if (not stat.S_ISDIR(root_info.st_mode) or root_info.st_uid != os.geteuid()
            or stat.S_IMODE(root_info.st_mode) != 0o700
            or identity(root_info) != expected_identity):
        raise RuntimeError("transaction root identity changed before cleanup")
    root_fd = os.open(root_name, directory_flags, dir_fd=parent_fd)
    try:
        opened_root = os.fstat(root_fd)
        if identity(opened_root) != expected_identity:
            raise RuntimeError("transaction root changed while opening for cleanup")
        regular = {
            "format", "owner-pid", "state", ".state.next",
            "candidate-id", ".candidate-id.next",
            "output-id", ".output-id.next",
        }
        names = set(os.listdir(root_fd))
        if not {"format", "owner-pid", "state"}.issubset(names):
            raise RuntimeError("transaction ownership markers are missing")
        for name in names:
            info = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
            if name in regular:
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                        or info.st_nlink != 1
                        or stat.S_IMODE(info.st_mode) != 0o600):
                    raise RuntimeError("unsafe transaction marker during cleanup")
            elif name == "staging":
                if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
                    raise RuntimeError("unsafe transaction staging directory")
            else:
                raise RuntimeError("unexpected transaction node during cleanup")
        format_fd = os.open("format", file_flags, dir_fd=root_fd)
        try:
            if os.read(format_fd, 257) != b"droidmatch-swift-proto-publication-v2\n":
                raise RuntimeError("transaction format marker changed")
        finally:
            os.close(format_fd)
        remove_contents(root_fd)
        os.fsync(root_fd)
    finally:
        os.close(root_fd)
    current = os.stat(root_name, dir_fd=parent_fd, follow_symlinks=False)
    if identity(current) != expected_identity:
        raise RuntimeError("transaction root was rebound before final removal")
    os.rmdir(root_name, dir_fd=parent_fd)
    os.fsync(parent_fd)
finally:
    os.close(parent_fd)
' "${transaction_dir}" "${expected_identity}" >/dev/null 2>&1; then
    printf 'Refusing to remove an unsafe or rebound Swift protobuf transaction.\n' >&2
    printf '中文：拒绝删除不安全或已重新绑定的 Swift protobuf 事务。\n' >&2
    return 1
  fi
}

create_transaction() {
  local created_identity=""
  if ! created_identity="$(python3 -c '
import ctypes
import os
import tempfile
import sys

operation = "create-proto-transaction"
root, owner = sys.argv[1:]
parent = os.path.dirname(root)
root_name = os.path.basename(root)
directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
if hasattr(os, "O_NOFOLLOW"):
    directory_flags |= os.O_NOFOLLOW
parent_fd = os.open(parent, directory_flags)
temporary = tempfile.mkdtemp(prefix=root_name + ".new.", dir=parent)
temporary_name = os.path.basename(temporary)
os.chmod(temporary, 0o700)
renamed = False
temporary_fd = None
try:
    temporary_fd = os.open(temporary_name, directory_flags, dir_fd=parent_fd)
    for name, value in (("format", "droidmatch-swift-proto-publication-v2\n"),
                        ("owner-pid", owner + "\n"), ("state", "preparing\n")):
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(name, flags, 0o600, dir_fd=temporary_fd)
        try:
            os.write(fd, value.encode("ascii"))
            os.fsync(fd)
        finally:
            os.close(fd)
    os.fsync(temporary_fd)
    temporary_info = os.fstat(temporary_fd)
    library = ctypes.CDLL(None, use_errno=True)
    renameatx_np = library.renameatx_np
    renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p,
                             ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameatx_np.restype = ctypes.c_int
    if renameatx_np(parent_fd, os.fsencode(temporary_name),
                    parent_fd, os.fsencode(root_name), 0x4) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    renamed = True
    published = os.stat(root_name, dir_fd=parent_fd, follow_symlinks=False)
    if (published.st_dev, published.st_ino) != (temporary_info.st_dev, temporary_info.st_ino):
        raise RuntimeError("transaction install postcondition failed")
    os.fsync(parent_fd)
    print(f"{published.st_dev}:{published.st_ino}")
except BaseException:
    if not renamed:
        try:
            if temporary_fd is not None:
                for name in os.listdir(temporary_fd):
                    os.unlink(name, dir_fd=temporary_fd)
            os.rmdir(temporary_name, dir_fd=parent_fd)
        except FileNotFoundError:
            pass
    raise
finally:
    try:
        if temporary_fd is not None:
            os.close(temporary_fd)
    except OSError:
        pass
    os.close(parent_fd)
' "${transaction_dir}" "$$" 2>/dev/null)"; then
    printf 'Could not create an exclusive Swift protobuf transaction.\n' >&2
    return 1
  fi
  transaction_identity="${created_identity}"
}

write_marker() {
  local marker_name="$1"
  local marker_value="$2"
  local expected_identity="$3"
  python3 -c '
import os, stat, sys
operation = "write-proto-marker"
root, name, value, expected_identity = sys.argv[1:]
parent = os.path.dirname(root)
root_name = os.path.basename(root)
directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
if hasattr(os, "O_NOFOLLOW"):
    directory_flags |= os.O_NOFOLLOW
parent_fd = os.open(parent, directory_flags)
root_fd = os.open(root_name, directory_flags, dir_fd=parent_fd)
opened_root = os.fstat(root_fd)
if (not stat.S_ISDIR(opened_root.st_mode) or opened_root.st_uid != os.geteuid()
        or stat.S_IMODE(opened_root.st_mode) != 0o700
        or f"{opened_root.st_dev}:{opened_root.st_ino}" != expected_identity):
    raise RuntimeError("transaction root changed before marker write")
temporary = "." + name + ".next"
destination = name
try:
    info = os.stat(temporary, dir_fd=root_fd, follow_symlinks=False)
except FileNotFoundError:
    pass
else:
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
        raise RuntimeError("unsafe temporary marker")
    os.unlink(temporary, dir_fd=root_fd)
try:
    destination_info = os.stat(destination, dir_fd=root_fd, follow_symlinks=False)
except FileNotFoundError:
    destination_info = None
if destination_info is not None and (not stat.S_ISREG(destination_info.st_mode)
        or destination_info.st_uid != os.geteuid()
        or destination_info.st_nlink != 1
        or stat.S_IMODE(destination_info.st_mode) != 0o600):
    raise RuntimeError("unsafe destination marker")
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(temporary, flags, 0o600, dir_fd=root_fd)
try:
    os.write(fd, (value + "\n").encode("ascii"))
    os.fsync(fd)
finally:
    os.close(fd)
os.replace(temporary, destination, src_dir_fd=root_fd, dst_dir_fd=root_fd)
try:
    os.fsync(root_fd)
finally:
    os.close(root_fd)
    os.close(parent_fd)
' "${transaction_dir}" "${marker_name}" "${marker_value}" \
    "${expected_identity}" >/dev/null 2>&1
}

swap_exact_directories() {
  local source_path="$1" destination_path="$2" source_identity="$3"
  local destination_identity="$4" root_identity="$5"
  python3 -c '
import ctypes, os, stat, sys
operation = "swap-generated-directories"
source, destination, source_id, destination_id, root_id = sys.argv[1:]
source_root = os.path.dirname(source)
source_name = os.path.basename(source)
source_parent = os.path.dirname(source_root)
source_root_name = os.path.basename(source_root)
destination_parent = os.path.dirname(destination)
destination_name = os.path.basename(destination)
directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
if hasattr(os, "O_NOFOLLOW"):
    directory_flags |= os.O_NOFOLLOW
def identity(info):
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        raise RuntimeError("publication node is not an owned directory")
    return f"{info.st_dev}:{info.st_ino}"
source_parent_fd = os.open(source_parent, directory_flags)
source_root_fd = os.open(source_root_name, directory_flags, dir_fd=source_parent_fd)
destination_parent_fd = os.open(destination_parent, directory_flags)
if identity(os.fstat(source_root_fd)) != root_id:
    raise RuntimeError("transaction root changed before swap")
source_info = os.stat(source_name, dir_fd=source_root_fd, follow_symlinks=False)
destination_info = os.stat(destination_name, dir_fd=destination_parent_fd,
                           follow_symlinks=False)
if identity(source_info) != source_id or identity(destination_info) != destination_id:
    raise RuntimeError("publication node changed before swap")
library = ctypes.CDLL(None, use_errno=True)
renameatx_np = library.renameatx_np
renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p,
                         ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameatx_np.restype = ctypes.c_int
if renameatx_np(source_root_fd, os.fsencode(source_name),
                destination_parent_fd, os.fsencode(destination_name), 0x2) != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error))
new_source = os.stat(source_name, dir_fd=source_root_fd, follow_symlinks=False)
new_destination = os.stat(destination_name, dir_fd=destination_parent_fd,
                          follow_symlinks=False)
if identity(new_source) != destination_id or identity(new_destination) != source_id:
    raise RuntimeError("publication swap postcondition failed")
try:
    os.fsync(source_root_fd)
    os.fsync(destination_parent_fd)
finally:
    os.close(destination_parent_fd)
    os.close(source_root_fd)
    os.close(source_parent_fd)
' "${source_path}" "${destination_path}" "${source_identity}" \
    "${destination_identity}" "${root_identity}" >/dev/null 2>&1
}

install_exact_directory() {
  local source_path="$1" destination_path="$2" source_identity="$3"
  local root_identity="$4"
  python3 -c '
import ctypes, os, stat, sys
operation = "install-generated-directory"
source, destination, source_id, root_id = sys.argv[1:]
source_root = os.path.dirname(source)
source_name = os.path.basename(source)
source_parent = os.path.dirname(source_root)
source_root_name = os.path.basename(source_root)
destination_parent = os.path.dirname(destination)
destination_name = os.path.basename(destination)
directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
if hasattr(os, "O_NOFOLLOW"):
    directory_flags |= os.O_NOFOLLOW
source_parent_fd = os.open(source_parent, directory_flags)
source_root_fd = os.open(source_root_name, directory_flags, dir_fd=source_parent_fd)
destination_parent_fd = os.open(destination_parent, directory_flags)
opened_root = os.fstat(source_root_fd)
if (not stat.S_ISDIR(opened_root.st_mode) or opened_root.st_uid != os.geteuid()
        or f"{opened_root.st_dev}:{opened_root.st_ino}" != root_id):
    raise RuntimeError("transaction root changed before publication")
info = os.stat(source_name, dir_fd=source_root_fd, follow_symlinks=False)
if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
        or f"{info.st_dev}:{info.st_ino}" != source_id):
    raise RuntimeError("candidate changed before publication")
library = ctypes.CDLL(None, use_errno=True)
renameatx_np = library.renameatx_np
renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p,
                         ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameatx_np.restype = ctypes.c_int
if renameatx_np(source_root_fd, os.fsencode(source_name),
                destination_parent_fd, os.fsencode(destination_name), 0x4) != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error))
published = os.stat(destination_name, dir_fd=destination_parent_fd,
                    follow_symlinks=False)
if (not stat.S_ISDIR(published.st_mode) or published.st_uid != os.geteuid()
        or f"{published.st_dev}:{published.st_ino}" != source_id):
    raise RuntimeError("publication install postcondition failed")
try:
    os.fsync(source_root_fd)
    os.fsync(destination_parent_fd)
finally:
    os.close(destination_parent_fd)
    os.close(source_root_fd)
    os.close(source_parent_fd)
' "${source_path}" "${destination_path}" "${source_identity}" \
    "${root_identity}" >/dev/null 2>&1
}

reconcile_transaction() {
  local check_owner="$1"
  local expected_identity="${2:-}"
  local snapshot=""
  if ! snapshot="$(transaction_snapshot "${expected_identity}")"; then
    printf 'Existing Swift protobuf transaction is unsafe; preserving it.\n' >&2
    printf '中文：现有 Swift protobuf 事务布局不安全，已原样保留。\n' >&2
    return 1
  fi
  local root_identity owner_pid state candidate_identity output_identity extra
  IFS='|' read -r root_identity owner_pid state candidate_identity \
    output_identity extra <<<"${snapshot}"
  if [[ -n "${extra:-}" || -z "${root_identity}" || -z "${owner_pid}" \
      || -z "${state}" ]]; then
    printf 'Swift protobuf transaction snapshot is malformed.\n' >&2
    return 1
  fi
  if ! [[ "${owner_pid}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Swift protobuf transaction owner marker is invalid.\n' >&2
    return 1
  fi
  if [[ "${check_owner}" == true ]] && kill -0 "${owner_pid}" 2>/dev/null; then
    printf 'Another Swift protobuf generation transaction is active.\n' >&2
    return 1
  fi

  case "${state}" in
    preparing)
      ;;
    prepared)
      [[ "${candidate_identity}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
      node_matches_identity "${transaction_dir}/staging" "${candidate_identity}" \
        && generated_tree_safe "${transaction_dir}/staging" || return 1
      ;;
    swapping|swapped)
      [[ "${candidate_identity}" =~ ^[0-9]+:[0-9]+$ \
          && "${output_identity}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
      if node_matches_identity "${transaction_dir}/staging" "${candidate_identity}" \
          && generated_tree_safe "${transaction_dir}/staging"; then
        : # The atomic swap did not occur. Leave any concurrent output untouched.
      elif node_matches_identity "${transaction_dir}/staging" "${output_identity}" \
          && node_matches_identity "${output_dir}" "${candidate_identity}" \
          && generated_tree_safe "${transaction_dir}/staging" \
          && generated_tree_safe "${output_dir}"; then
        : # The validated candidate is canonical and the old tree is disposable.
      else
        printf 'Interrupted Swift protobuf swap has an inconsistent mapping.\n' >&2
        return 1
      fi
      ;;
    installing-new|installed-new)
      [[ "${candidate_identity}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
      if node_matches_identity "${transaction_dir}/staging" "${candidate_identity}" \
          && generated_tree_safe "${transaction_dir}/staging"; then
        : # Exclusive installation did not occur; preserve any concurrent output.
      elif [[ ! -e "${transaction_dir}/staging" \
          && ! -L "${transaction_dir}/staging" ]] \
          && node_matches_identity "${output_dir}" "${candidate_identity}" \
          && generated_tree_safe "${output_dir}"; then
        : # First publication completed before interruption.
      else
        printf 'Interrupted Swift protobuf first publication is inconsistent.\n' >&2
        return 1
      fi
      ;;
    *)
      printf 'Swift protobuf transaction has an unknown state.\n' >&2
      return 1
      ;;
  esac
  remove_transaction_tree "${root_identity}"
}

handle_exit() {
  local status="$1"
  trap - EXIT INT TERM
  if [[ "${transaction_owned}" == true \
      && ( -e "${transaction_dir}" || -L "${transaction_dir}" ) ]]; then
    if ! reconcile_transaction false "${transaction_identity}"; then
      printf 'Swift protobuf recovery is incomplete; the private transaction was preserved.\n' >&2
      printf '中文：Swift protobuf 恢复未完成；已保留私有事务现场。\n' >&2
    fi
  fi
  exit "${status}"
}

if [[ -e "${transaction_dir}" || -L "${transaction_dir}" ]]; then
  reconcile_transaction true
fi
if [[ -e "${output_dir}" || -L "${output_dir}" ]]; then
  if ! generated_tree_safe "${output_dir}"; then
    printf 'Refusing to replace an unsafe or unrecognized generated source tree.\n' >&2
    printf '中文：拒绝替换不安全或无法识别的生成源码树。\n' >&2
    exit 1
  fi
fi

create_transaction
transaction_owned=true
trap 'handle_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

staging_dir="${transaction_dir}/staging"
mkdir -m 0700 "${staging_dir}"

"${protoc_bin}" \
  --plugin="protoc-gen-swift=${protoc_gen_swift}" \
  --proto_path=proto \
  --swift_out="${staging_dir}" \
  --swift_opt=Visibility=Public \
  proto/v1/*.proto

if ! generated_tree_safe "${staging_dir}" true true; then
  printf 'Swift protobuf generation produced an incomplete or unsafe tree.\n' >&2
  exit 1
fi
candidate_identity="$(node_identity "${staging_dir}")"
write_marker candidate-id "${candidate_identity}" "${transaction_identity}"
write_marker state prepared "${transaction_identity}"

if [[ -e "${output_dir}" || -L "${output_dir}" ]]; then
  generated_tree_safe "${output_dir}" || {
    printf 'Generated output changed to an unsafe node before publication.\n' >&2
    exit 1
  }
  output_identity="$(node_identity "${output_dir}")"
  write_marker output-id "${output_identity}" "${transaction_identity}"
  write_marker state swapping "${transaction_identity}"
  swap_exact_directories "${staging_dir}" "${output_dir}" \
    "${candidate_identity}" "${output_identity}" "${transaction_identity}"
  generated_tree_safe "${output_dir}" || exit 1
  write_marker state swapped "${transaction_identity}"
else
  write_marker state installing-new "${transaction_identity}"
  install_exact_directory "${staging_dir}" "${output_dir}" \
    "${candidate_identity}" "${transaction_identity}"
  generated_tree_safe "${output_dir}" || exit 1
  write_marker state installed-new "${transaction_identity}"
fi

reconcile_transaction false "${transaction_identity}"
if ! node_matches_identity "${output_dir}" "${candidate_identity}" \
    || ! generated_tree_safe "${output_dir}"; then
  printf 'Generated output changed after publication; refusing to report success.\n' >&2
  printf '中文：生成输出在发布后发生变化；拒绝报告成功。\n' >&2
  exit 1
fi
transaction_owned=false
trap - EXIT INT TERM

printf 'Generated Swift protobuf files in %s\n' "${output_dir}"
