#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -P "${script_dir}/.." && pwd)"
cd "${repo_root}"
umask 077

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

python_bin="${PYTHON3:-$(command -v python3 || true)}"
git_bin="${GIT:-$(command -v git || true)}"
swift_bin="${SWIFT:-$(command -v swift || true)}"
swiftc_bin="${SWIFTC:-$(command -v swiftc || true)}"
[[ -n "${python_bin}" && -x "${python_bin}" ]] \
  || fail 'python3 is required for safe path handling. / 安全路径处理需要 python3。'
[[ -n "${git_bin}" && -x "${git_bin}" ]] \
  || fail 'git is required to verify SwiftProtobuf. / 验证 SwiftProtobuf 需要 git。'
[[ -n "${swift_bin}" && -x "${swift_bin}" ]] \
  || fail 'swift is required to build protoc-gen-swift. / 构建 protoc-gen-swift 需要 swift。'

# All mutable paths are opened component by component with O_NOFOLLOW. The
# helper also owns atomic publication so shell path re-resolution cannot turn
# the destination into a directory or redirect a staged executable.
path_guard() {
  "${python_bin}" - "$@" <<'PY'
import hashlib
import json
import os
import secrets
import stat
import sys

O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
O_CLOEXEC = getattr(os, "O_CLOEXEC", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
OPEN_DIR = os.O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
OPEN_FILE = os.O_RDONLY | O_CLOEXEC | O_NOFOLLOW


def abort(message):
    raise RuntimeError(message)


def normalized(path):
    if not path:
        abort("empty path")
    if any(character in path for character in "\n\r\t|"):
        abort("path contains an unsupported control or separator character")
    path = os.path.abspath(path)
    # Darwin exposes these compatibility roots as symlinks. Map only the fixed
    # operating-system aliases; arbitrary symlink ancestors remain forbidden.
    if sys.platform == "darwin":
        for alias in ("tmp", "var", "etc"):
            prefix = "/" + alias
            if path == prefix or path.startswith(prefix + "/"):
                path = "/private" + path
                break
    return os.path.normpath(path)


def components(path):
    path = normalized(path)
    if path == "/":
        return path, []
    return path, [part for part in path.split("/") if part]


def open_directory(path, create=False):
    path, parts = components(path)
    descriptor = os.open("/", OPEN_DIR)
    try:
        for part in parts:
            while True:
                try:
                    before = os.stat(part, dir_fd=descriptor,
                                     follow_symlinks=False)
                except FileNotFoundError:
                    if not create:
                        abort("directory path is missing")
                    try:
                        os.mkdir(part, 0o700, dir_fd=descriptor)
                    except FileExistsError:
                        continue
                    before = os.stat(part, dir_fd=descriptor,
                                     follow_symlinks=False)
                if not stat.S_ISDIR(before.st_mode):
                    abort("directory path contains a non-directory or symlink")
                child = os.open(part, OPEN_DIR, dir_fd=descriptor)
                after = os.fstat(child)
                if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
                    os.close(child)
                    abort("directory path changed while it was opened")
                os.close(descriptor)
                descriptor = child
                break
        return path, descriptor
    except BaseException:
        os.close(descriptor)
        raise


def identity(file_stat):
    return f"{file_stat.st_dev}:{file_stat.st_ino}"


def require_identity(file_stat, expected, label):
    if identity(file_stat) != expected:
        abort(f"{label} identity changed")


def hash_descriptor(descriptor):
    digest = hashlib.sha256()
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        block = os.read(descriptor, 1024 * 1024)
        if not block:
            break
        digest.update(block)
    os.lseek(descriptor, 0, os.SEEK_SET)
    return digest.hexdigest()


def snapshot_descriptor(descriptor):
    file_stat = os.fstat(descriptor)
    return ",".join((
        "present",
        str(file_stat.st_dev),
        str(file_stat.st_ino),
        str(file_stat.st_size),
        str(stat.S_IMODE(file_stat.st_mode)),
        str(file_stat.st_nlink),
        hash_descriptor(descriptor),
    ))


def open_regular(parent, name, *, executable=False, single_link=False):
    before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode):
        abort("path is not a regular file")
    descriptor = os.open(name, OPEN_FILE, dir_fd=parent)
    after = os.fstat(descriptor)
    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        os.close(descriptor)
        abort("file changed while it was opened")
    if single_link and after.st_nlink != 1:
        os.close(descriptor)
        abort("regular file has more than one hard link")
    if executable and stat.S_IMODE(after.st_mode) & 0o111 == 0:
        os.close(descriptor)
        abort("regular file is not executable")
    return descriptor


def split_parent(path, create=False):
    path = normalized(path)
    name = os.path.basename(path)
    if not name or name in (".", ".."):
        abort("path has no safe final component")
    parent_path, parent = open_directory(os.path.dirname(path), create=create)
    return path, parent_path, parent, name


def target_snapshot(parent, name):
    try:
        descriptor = open_regular(parent, name, single_link=True)
    except FileNotFoundError:
        return "absent"
    try:
        return snapshot_descriptor(descriptor)
    finally:
        os.close(descriptor)


def product_snapshot(path, scratch_path, scratch_identity):
    path = normalized(path)
    scratch_path = normalized(scratch_path)
    try:
        if os.path.commonpath((path, scratch_path)) != scratch_path or path == scratch_path:
            abort("build product escaped the fresh scratch directory")
    except ValueError:
        abort("build product escaped the fresh scratch directory")
    _, scratch = open_directory(scratch_path)
    try:
        require_identity(os.fstat(scratch), scratch_identity, "scratch directory")
    finally:
        os.close(scratch)
    _, _, parent, name = split_parent(path)
    try:
        descriptor = open_regular(parent, name, executable=True, single_link=True)
        try:
            return snapshot_descriptor(descriptor)
        finally:
            os.close(descriptor)
    finally:
        os.close(parent)


def parse_snapshot(value):
    fields = value.split(",")
    if len(fields) != 7 or fields[0] != "present":
        abort("invalid file snapshot")
    return {
        "dev": int(fields[1]),
        "ino": int(fields[2]),
        "size": int(fields[3]),
        "mode": int(fields[4]),
        "nlink": int(fields[5]),
        "hash": fields[6],
    }


def publish(product_path, expected_product, install_path,
            expected_parent, expected_target):
    _, _, product_parent, product_name = split_parent(product_path)
    product = None
    parent = None
    staged = None
    staged_name = None
    backup_name = None
    committed = False
    final_verified = False
    retain_backup = False
    published_snapshot = None
    try:
        product = open_regular(product_parent, product_name,
                               executable=True, single_link=True)
        if snapshot_descriptor(product) != expected_product:
            abort("build product changed before publication")
        product_info = parse_snapshot(expected_product)

        install_path, _, parent, target_name = split_parent(install_path)
        require_identity(os.fstat(parent), expected_parent,
                         "install parent directory")
        try:
            current_target = target_snapshot(parent, target_name)
        except (OSError, RuntimeError):
            abort("install target changed concurrently or is unsafe")
        if current_target != expected_target:
            abort("install target changed concurrently")

        for _ in range(128):
            candidate = ".protoc-gen-swift." + secrets.token_hex(16) + ".tmp"
            try:
                staged = os.open(candidate,
                                 os.O_RDWR | os.O_CREAT | os.O_EXCL |
                                 O_CLOEXEC | O_NOFOLLOW,
                                 0o700, dir_fd=parent)
                staged_name = candidate
                break
            except FileExistsError:
                continue
        if staged is None:
            abort("could not reserve a unique staging file")

        while True:
            block = os.read(product, 1024 * 1024)
            if not block:
                break
            view = memoryview(block)
            while view:
                written = os.write(staged, view)
                if written <= 0:
                    abort("short write while staging executable")
                view = view[written:]
        os.fchmod(staged, 0o755)
        os.fsync(staged)
        staged_stat = os.fstat(staged)
        if (not stat.S_ISREG(staged_stat.st_mode) or
                staged_stat.st_nlink != 1 or
                stat.S_IMODE(staged_stat.st_mode) != 0o755 or
                staged_stat.st_size != product_info["size"] or
                hash_descriptor(staged) != product_info["hash"]):
            abort("staged executable verification failed")
        staged_identity = identity(staged_stat)

        require_identity(os.fstat(parent), expected_parent,
                         "install parent directory")
        if target_snapshot(parent, target_name) != expected_target:
            abort("install target changed concurrently")

        if expected_target != "absent":
            old_info = parse_snapshot(expected_target)
            for _ in range(128):
                candidate = ".protoc-gen-swift." + secrets.token_hex(16) + ".old"
                try:
                    os.link(target_name, candidate,
                            src_dir_fd=parent, dst_dir_fd=parent,
                            follow_symlinks=False)
                    backup_name = candidate
                    break
                except FileExistsError:
                    continue
            if backup_name is None:
                abort("could not retain the previous executable")
            backup = open_regular(parent, backup_name)
            try:
                backup_stat = os.fstat(backup)
                if ((backup_stat.st_dev, backup_stat.st_ino) !=
                        (old_info["dev"], old_info["ino"]) or
                        backup_stat.st_size != old_info["size"] or
                        stat.S_IMODE(backup_stat.st_mode) != old_info["mode"] or
                        backup_stat.st_nlink != 2 or
                        hash_descriptor(backup) != old_info["hash"]):
                    abort("previous executable changed before publication")
            finally:
                os.close(backup)
            current = os.stat(target_name, dir_fd=parent,
                              follow_symlinks=False)
            if ((current.st_dev, current.st_ino) !=
                    (old_info["dev"], old_info["ino"]) or
                    current.st_size != old_info["size"] or
                    stat.S_IMODE(current.st_mode) != old_info["mode"] or
                    current.st_nlink != 2):
                abort("install target changed while retaining the old executable")
            os.fsync(parent)

        os.replace(staged_name, target_name,
                   src_dir_fd=parent, dst_dir_fd=parent)
        staged_name = None
        committed = True
        os.fsync(parent)

        final_file = open_regular(parent, target_name,
                                  executable=True, single_link=True)
        try:
            final_stat = os.fstat(final_file)
            if (identity(final_stat) != staged_identity or
                    stat.S_IMODE(final_stat.st_mode) != 0o755 or
                    final_stat.st_size != product_info["size"] or
                    hash_descriptor(final_file) != product_info["hash"]):
                abort("published executable verification failed")
            os.fsync(final_file)
            published_snapshot = snapshot_descriptor(final_file)
            if published_snapshot != ",".join((
                    "present", str(final_stat.st_dev), str(final_stat.st_ino),
                    str(final_stat.st_size), str(0o755), "1",
                    product_info["hash"])):
                abort("published executable changed during verification")
        finally:
            os.close(final_file)
        os.fsync(parent)

        if target_snapshot(parent, target_name) != published_snapshot:
            abort("published executable changed before commit finalization")
        final_verified = True
        if backup_name is not None:
            os.unlink(backup_name, dir_fd=parent)
            backup_name = None
            # The replacement and final executable were already fsynced while
            # the rollback link still existed. This fsync persists its removal.
            os.fsync(parent)
        if target_snapshot(parent, target_name) != published_snapshot:
            abort("published executable changed after final verification")
        return published_snapshot
    except BaseException:
        if committed and not final_verified:
            restored = False
            try:
                current = os.stat(target_name, dir_fd=parent,
                                  follow_symlinks=False)
                if identity(current) == staged_identity:
                    if backup_name is not None:
                        os.replace(backup_name, target_name,
                                   src_dir_fd=parent, dst_dir_fd=parent)
                        backup_name = None
                    else:
                        os.unlink(target_name, dir_fd=parent)
                    os.fsync(parent)
                    restored = True
            except BaseException:
                pass
            if backup_name is not None and not restored:
                # If an external actor changed the just-published name, do not
                # destroy the only remaining link to the previous executable.
                retain_backup = True
        raise
    finally:
        if staged is not None:
            os.close(staged)
        if product is not None:
            os.close(product)
        os.close(product_parent)
        if parent is not None:
            if staged_name is not None:
                try:
                    os.unlink(staged_name, dir_fd=parent)
                except OSError:
                    pass
            if backup_name is not None and not retain_backup:
                try:
                    os.unlink(backup_name, dir_fd=parent)
                    os.fsync(parent)
                except OSError:
                    pass
            os.close(parent)


def remove_tree(descriptor):
    for name in os.listdir(descriptor):
        entry = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISDIR(entry.st_mode):
            child = os.open(name, OPEN_DIR, dir_fd=descriptor)
            try:
                opened = os.fstat(child)
                if (opened.st_dev, opened.st_ino) != (entry.st_dev, entry.st_ino):
                    abort("scratch entry changed during cleanup")
                remove_tree(child)
            finally:
                os.close(child)
            os.rmdir(name, dir_fd=descriptor)
        else:
            os.unlink(name, dir_fd=descriptor)


try:
    action = sys.argv[1]
    arguments = sys.argv[2:]
    if action == "normalize":
        print(normalized(arguments[0]))
    elif action in ("ensure-dir", "inspect-dir"):
        path, descriptor = open_directory(arguments[0], create=action == "ensure-dir")
        try:
            print(identity(os.fstat(descriptor)))
        finally:
            os.close(descriptor)
    elif action == "assert-dir":
        _, descriptor = open_directory(arguments[0])
        try:
            require_identity(os.fstat(descriptor), arguments[1], "directory")
        finally:
            os.close(descriptor)
    elif action == "create-child":
        base_path, base = open_directory(arguments[0], create=True)
        try:
            prefix = arguments[1]
            if not prefix or "/" in prefix:
                abort("unsafe scratch prefix")
            for _ in range(128):
                name = prefix + secrets.token_hex(16)
                try:
                    os.mkdir(name, 0o700, dir_fd=base)
                    created = os.stat(name, dir_fd=base,
                                      follow_symlinks=False)
                    break
                except FileExistsError:
                    continue
            else:
                abort("could not reserve a fresh scratch directory")
            child = os.open(name, OPEN_DIR, dir_fd=base)
            try:
                child_stat = os.fstat(child)
                if ((created.st_dev, created.st_ino) !=
                        (child_stat.st_dev, child_stat.st_ino)):
                    abort("fresh scratch directory changed while it was opened")
                if stat.S_IMODE(child_stat.st_mode) != 0o700:
                    abort("fresh scratch directory is not private")
                print(f"{base_path}/{name}|{identity(child_stat)}")
            finally:
                os.close(child)
        finally:
            os.close(base)
    elif action == "read-pin":
        path, _, parent, name = split_parent(arguments[0])
        try:
            descriptor = open_regular(parent, name)
            try:
                raw = b""
                while True:
                    block = os.read(descriptor, 1024 * 1024)
                    if not block:
                        break
                    raw += block
                    if len(raw) > 16 * 1024 * 1024:
                        abort("Package.resolved is unexpectedly large")
                document = json.loads(raw)
                matches = [pin for pin in document.get("pins", [])
                           if pin.get("identity") == "swift-protobuf"]
                if len(matches) != 1:
                    abort("Package.resolved does not contain one SwiftProtobuf pin")
                revision = matches[0].get("state", {}).get("revision")
                if (not isinstance(revision, str) or len(revision) != 40 or
                        any(character not in "0123456789abcdefABCDEF"
                            for character in revision)):
                    abort("SwiftProtobuf revision is not a full commit hash")
                os.lseek(descriptor, 0, os.SEEK_SET)
                print(f"{revision.lower()}|{snapshot_descriptor(descriptor)}")
            finally:
                os.close(descriptor)
        finally:
            os.close(parent)
    elif action == "target-snapshot":
        _, _, parent, name = split_parent(arguments[0])
        try:
            print(target_snapshot(parent, name))
        finally:
            os.close(parent)
    elif action == "product-snapshot":
        print(product_snapshot(*arguments))
    elif action == "publish":
        print(publish(*arguments))
    elif action == "remove-child":
        base_path, base = open_directory(arguments[0])
        try:
            require_identity(os.fstat(base), arguments[3], "scratch parent")
            name = arguments[1]
            entry = os.stat(name, dir_fd=base, follow_symlinks=False)
            if not stat.S_ISDIR(entry.st_mode) or identity(entry) != arguments[2]:
                abort("scratch directory changed before cleanup")
            child = os.open(name, OPEN_DIR, dir_fd=base)
            try:
                require_identity(os.fstat(child), arguments[2], "scratch directory")
                remove_tree(child)
            finally:
                os.close(child)
            os.rmdir(name, dir_fd=base)
        finally:
            os.close(base)
    else:
        abort("unknown path guard action")
except BaseException as error:
    print(f"bootstrap path guard: {error}", file=sys.stderr)
    raise SystemExit(2)
PY
}

normalize_path() {
  path_guard normalize "$1" \
    || fail 'A bootstrap path is invalid. / 引导安装路径无效。'
}

resolved_file="$(normalize_path "${SWIFT_PROTOBUF_PACKAGE_RESOLVED:-${repo_root}/mac/Package.resolved}")"
checkout="$(normalize_path "${SWIFT_PROTOBUF_CHECKOUT:-${repo_root}/mac/.build/checkouts/swift-protobuf}")"
scratch_parent="$(normalize_path "${SWIFT_PROTOBUF_TOOL_SCRATCH_PATH:-${repo_root}/.tools/build/swift-protobuf}")"
install_path="$(normalize_path "${PROTOC_GEN_SWIFT:-${repo_root}/.tools/bin/protoc-gen-swift}")"
default_checkout="$(normalize_path "${repo_root}/mac/.build/checkouts/swift-protobuf")"

resolved_state="$(path_guard read-pin "${resolved_file}")" \
  || fail 'mac/Package.resolved is missing or unsafe. / mac/Package.resolved 缺失或不安全。'
pinned_revision="${resolved_state%%|*}"

checkout_identity=""
if ! checkout_identity="$(path_guard inspect-dir "${checkout}" 2>/dev/null)"; then
  if [[ "${checkout}" != "${default_checkout}" || -e "${checkout}" || -L "${checkout}" ]]; then
    fail 'The requested SwiftProtobuf checkout is missing or unsafe. / 指定的 SwiftProtobuf checkout 缺失或不安全。'
  fi
  path_guard ensure-dir "$(dirname "${checkout}")" >/dev/null \
    || fail 'Swift package checkout parent is unsafe. / Swift 依赖 checkout 父目录不安全。'
  "${swift_bin}" package --package-path mac resolve
  checkout_identity="$(path_guard inspect-dir "${checkout}")" \
    || fail 'SwiftProtobuf checkout is missing or unsafe after resolution. / 依赖解析后 SwiftProtobuf checkout 仍缺失或不安全。'
fi

verify_checkout() {
  local current_identity revision status untracked current_resolved
  current_identity="$(path_guard inspect-dir "${checkout}")" \
    || fail 'SwiftProtobuf checkout became unsafe. / SwiftProtobuf checkout 变得不安全。'
  [[ "${current_identity}" == "${checkout_identity}" ]] \
    || fail 'SwiftProtobuf checkout identity changed. / SwiftProtobuf checkout 身份已改变。'
  revision="$(${git_bin} -C "${checkout}" rev-parse --verify HEAD 2>/dev/null)" \
    || fail 'SwiftProtobuf checkout has no valid HEAD. / SwiftProtobuf checkout 没有有效 HEAD。'
  [[ "${revision}" == "${pinned_revision}" ]] \
    || fail 'SwiftProtobuf checkout does not match Package.resolved; resolve dependencies again. / SwiftProtobuf checkout 与 Package.resolved 不一致，请重新解析依赖。'
  status="$(${git_bin} -C "${checkout}" status --porcelain=v1 --untracked-files=all 2>/dev/null)" \
    || fail 'SwiftProtobuf checkout status could not be verified. / 无法验证 SwiftProtobuf checkout 状态。'
  untracked="$(${git_bin} -C "${checkout}" ls-files --others --directory --no-empty-directory 2>/dev/null)" \
    || fail 'SwiftProtobuf untracked files could not be verified. / 无法验证 SwiftProtobuf 未跟踪文件。'
  [[ -z "${status}" && -z "${untracked}" ]] \
    || fail 'SwiftProtobuf checkout has tracked or untracked modifications; refusing to build. / SwiftProtobuf checkout 含已跟踪或未跟踪修改，拒绝构建。'
  current_resolved="$(path_guard read-pin "${resolved_file}")" \
    || fail 'Package.resolved became unsafe. / Package.resolved 变得不安全。'
  [[ "${current_resolved}" == "${resolved_state}" ]] \
    || fail 'Package.resolved changed during bootstrap. / Package.resolved 在引导安装期间发生变化。'
}

verify_checkout

install_parent="$(dirname "${install_path}")"
install_parent_identity="$(path_guard ensure-dir "${install_parent}")" \
  || fail 'protoc-gen-swift install directory is unsafe. / protoc-gen-swift 安装目录不安全。'
initial_target="$(path_guard target-snapshot "${install_path}")" \
  || fail 'protoc-gen-swift install target is unsafe. / protoc-gen-swift 安装目标不安全。'

scratch_parent_identity="$(path_guard ensure-dir "${scratch_parent}")" \
  || fail 'SwiftProtobuf scratch parent is unsafe. / SwiftProtobuf 构建父目录不安全。'
scratch_info="$(path_guard create-child "${scratch_parent}" 'run.')" \
  || fail 'Could not create an exclusive fresh SwiftProtobuf scratch directory. / 无法创建独占且全新的 SwiftProtobuf 构建目录。'
scratch="${scratch_info%%|*}"
scratch_identity="${scratch_info#*|}"
scratch_name="$(basename "${scratch}")"
cleanup_scratch() {
  path_guard remove-child "${scratch_parent}" "${scratch_name}" \
    "${scratch_identity}" "${scratch_parent_identity}" >/dev/null 2>&1 || true
}
trap cleanup_scratch EXIT

module_cache="${scratch}/module-cache"
module_cache_identity="$(path_guard ensure-dir "${module_cache}")" \
  || fail 'Swift module cache path is unsafe. / Swift 模块缓存路径不安全。'
export CLANG_MODULE_CACHE_PATH="${module_cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${module_cache}"

swift_build_args=(
  build
  --package-path "${checkout}"
  --scratch-path "${scratch}"
  --configuration release
  --product protoc-gen-swift
  -Xswiftc -module-cache-path
  -Xswiftc "${module_cache}"
)
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
  swift_build_args+=(--disable-sandbox)
fi

if [[ -n "${swiftc_bin}" && -x "${swiftc_bin}" ]]; then
  if ! "${swiftc_bin}" -module-cache-path "${module_cache}" \
      -typecheck - >/dev/null 2>&1 <<'SWIFT'
func droidMatchDefaultTargetProbe() {}
SWIFT
  then
    sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    if [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 \
        && -n "${sdk_path}" ]] \
        && "${swiftc_bin}" -target arm64e-apple-macosx13.0 \
          -sdk "${sdk_path}" -module-cache-path "${module_cache}" \
          -typecheck - >/dev/null 2>&1 <<'SWIFT'
func droidMatchArm64eTargetProbe() {}
SWIFT
    then
      swift_build_args+=(--triple arm64e-apple-macosx13.0)
      printf 'Swift target fallback: using arm64e for protoc-gen-swift.\n'
      printf '中文：Swift 目标回退：protoc-gen-swift 使用 arm64e。\n'
    else
      fail 'The default Swift target is unusable and the arm64e fallback is unavailable. / 默认 Swift 目标不可用，且 arm64e 回退也不可用。'
    fi
  fi
fi

path_guard assert-dir "${scratch}" "${scratch_identity}" \
  || fail 'Fresh SwiftProtobuf scratch identity changed. / 全新 SwiftProtobuf 构建目录身份已改变。'
path_guard assert-dir "${module_cache}" "${module_cache_identity}" \
  || fail 'Swift module cache identity changed. / Swift 模块缓存身份已改变。'
verify_checkout

"${swift_bin}" "${swift_build_args[@]}"
bin_path="$(${swift_bin} "${swift_build_args[@]}" --show-bin-path)"
bin_path="$(normalize_path "${bin_path}")"
built_plugin="${bin_path}/protoc-gen-swift"

path_guard assert-dir "${scratch}" "${scratch_identity}" \
  || fail 'Fresh SwiftProtobuf scratch identity changed during build. / 全新 SwiftProtobuf 构建目录身份在构建期间发生变化。'
path_guard assert-dir "${module_cache}" "${module_cache_identity}" \
  || fail 'Swift module cache identity changed during build. / Swift 模块缓存在构建期间身份发生变化。'
verify_checkout
built_snapshot="$(path_guard product-snapshot "${built_plugin}" \
  "${scratch}" "${scratch_identity}")" \
  || fail 'SwiftPM did not produce a safe single-link executable in the fresh scratch directory. / SwiftPM 未在全新构建目录中生成安全的单链接可执行文件。'

final_snapshot="$(path_guard publish "${built_plugin}" "${built_snapshot}" \
  "${install_path}" "${install_parent_identity}" "${initial_target}")" \
  || fail 'Atomic protoc-gen-swift publication failed or became uncertain; a verified previous executable is retained whenever rollback is still safe. / protoc-gen-swift 原子发布失败或状态不确定；只要仍可安全回滚，就会保留已验证的旧可执行文件。'
[[ "$(path_guard inspect-dir "${install_parent}")" == "${install_parent_identity}" ]] \
  || fail 'Install parent identity changed after publication. / 发布后安装父目录身份发生变化。'
[[ "$(path_guard target-snapshot "${install_path}")" == "${final_snapshot}" ]] \
  || fail 'Installed protoc-gen-swift failed final verification. / 已安装的 protoc-gen-swift 最终验证失败。'

printf 'Installed pinned protoc-gen-swift at %s\n' "${install_path}"
printf '中文：已安装仓库固定版本的 protoc-gen-swift：%s\n' "${install_path}"
