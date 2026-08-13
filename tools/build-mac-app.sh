#!/bin/bash -p

set +x
set -euo pipefail
umask 077

original_arguments=("$@")
evidence_requested=false
for argument in "${original_arguments[@]}"; do
  [[ "${argument}" != "--evidence-ready" ]] || evidence_requested=true
done
if [[ "${evidence_requested}" == true ]]; then
  for environment_name in $(builtin compgen -e); do
    case "${environment_name}" in
      GIT_PAGER|GIT_TERMINAL_PROMPT) ;;
      GIT_*)
        printf '%s\n' 'Evidence-ready builds reject caller Git overrides.' >&2
        exit 1
        ;;
    esac
  done
  if [[ "${DROIDMATCH_EVIDENCE_BUILD_CLEAN:-}" != 1 || "$-" != *p* ]]; then
    builtin exec /usr/bin/env -i \
      HOME=/var/empty TMPDIR=/private/tmp \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C \
      PYTHONDONTWRITEBYTECODE=1 \
      DROIDMATCH_EVIDENCE_BUILD_CLEAN=1 \
      /bin/bash --noprofile --norc -p "${BASH_SOURCE[0]}" \
      "${original_arguments[@]}"
  fi
  [[ "${HOME}" == /var/empty && "${TMPDIR}" == /private/tmp \
      && "${PATH}" == /usr/bin:/bin:/usr/sbin:/sbin \
      && "${LANG}" == C && "${LC_ALL}" == C \
      && "${PYTHONDONTWRITEBYTECODE}" == 1 ]] || exit 1
  while IFS= read -r environment_name; do
    case "${environment_name}" in
      DROIDMATCH_EVIDENCE_BUILD_CLEAN|HOME|LANG|LC_ALL|PATH|PWD|\
      PYTHONDONTWRITEBYTECODE|SHLVL|TMPDIR)
        ;;
      *)
        printf '%s\n' 'Evidence-ready build environment is not isolated.' >&2
        exit 1
        ;;
    esac
  done < <(builtin compgen -e)
  while IFS= read -r inherited_function; do
    builtin unset -f "${inherited_function}"
  done < <(builtin compgen -A function)
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tools/swift-build-compat.sh"
source "${repo_root}/tools/mac-bundle-check-retry.sh"
source "${repo_root}/tools/mac-app-publication-cleanup.sh"
source "${repo_root}/tools/git-evidence-provenance.sh"
configuration="debug"
output_path="${repo_root}/mac/.build/app/DroidMatch.app"
sandboxed=false
evidence_ready=false
adb_source_override=""
usage() {
  cat <<'EOF'
Usage: tools/build-mac-app.sh [--configuration debug|release] [--output <DroidMatch.app>] [--sandboxed] [--evidence-ready --adb-executable <absolute-adb>]

Builds the SwiftUI product with SwiftPM, assembles a local .app bundle, and
applies an ad-hoc signature. Distribution signing and notarization still require
a configured release identity; tools/build-mac-dmg.sh packages the verified
local App without making a distribution-signing claim.
Publication refuses to replace a DroidMatch App that is still running from the
target path; quit that App before rebuilding the same output.
Pass --sandboxed to require and embed adb, then sign with the checked-in local
App Sandbox entitlements for product-boundary verification.
Pass --evidence-ready only with release + sandboxed + an explicit reviewed adb;
it uses a clean system-tool environment and a fresh private Swift scratch tree.

中文：使用 SwiftPM 构建 SwiftUI 产品，组装本地 .app 并执行 ad-hoc 签名。
分发签名和公证仍需要已配置的发布身份；tools/build-mac-dmg.sh 可打包已验证的
本地 App，但不代表已完成分发签名。
若目标位置的 DroidMatch 仍在运行，发布会拒绝覆盖；请先退出再构建同一路径。
EOF
}
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --configuration)
      configuration="${2:-}"
      shift 2
      ;;
    --output)
      output_path="${2:-}"
      shift 2
      ;;
    --sandboxed)
      sandboxed=true
      shift
      ;;
    --evidence-ready)
      evidence_ready=true
      shift
      ;;
    --adb-executable)
      adb_source_override="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${configuration}" != "debug" && "${configuration}" != "release" ]]; then
  printf 'Unsupported configuration: %s\n' "${configuration}" >&2
  exit 2
fi
if [[ "${evidence_ready}" == true ]]; then
  [[ "${configuration}" == release && "${sandboxed}" == true \
      && "${adb_source_override}" == /* \
      && -f "${adb_source_override}" && ! -L "${adb_source_override}" \
      && -x "${adb_source_override}" ]] || {
    printf '%s\n' 'Evidence-ready builds require release, sandboxing, and one absolute regular executable adb.' >&2
    exit 2
  }
elif [[ -n "${adb_source_override}" ]]; then
  printf '%s\n' '--adb-executable is reserved for --evidence-ready builds.' >&2
  exit 2
fi
if [[ -z "${output_path}" || "${output_path}" != *.app ]]; then
  printf 'Output must be a non-empty .app path.\n' >&2
  exit 2
fi
if [[ "${evidence_ready}" == true ]]; then
  if ! droidmatch_git_source_contract "${repo_root}"; then
    printf '%s\n' 'Evidence-ready builds require an unredirected source layout before output preparation.' >&2
    exit 1
  fi
  if ! droidmatch_git_product_inputs_clean "${repo_root}"; then
    printf '%s\n' 'Evidence-ready builds reject altered or ignored product inputs before output preparation.' >&2
    exit 1
  fi
  if ! droidmatch_git_official_origin_contract "${repo_root}"; then
    printf '%s\n' 'Evidence-ready builds require the canonical official origin before output preparation.' >&2
    exit 1
  fi
  evidence_preflight_status="$(droidmatch_git_status "${repo_root}")" || {
    printf '%s\n' 'Evidence-ready builds could not verify source cleanliness before output preparation.' >&2
    exit 1
  }
  if [[ -n "${evidence_preflight_status}" ]]; then
    printf '%s\n' 'Evidence-ready builds require a clean source tree before output preparation.' >&2
    exit 1
  fi
fi

output_parent_input="$(dirname "${output_path}")"
output_basename="$(basename "${output_path}")"
if [[ "${output_basename}" == "." || "${output_basename}" == ".." ]]; then
  printf 'Output must name a concrete .app bundle.\n' >&2
  exit 2
fi
python3 -c '
import os, sys
os.makedirs(sys.argv[1], exist_ok=True)
' "${output_parent_input}"
output_parent="$(cd "${output_parent_input}" && pwd -P)"
output_path="${output_parent}/${output_basename}"
transaction_root="${output_parent}/.${output_basename}.publication-transaction"
transaction_owned=false
publication_started=false
publication_complete=false
owner_instance="$(python3 "${repo_root}/tools/process_instance_identity.py" capture "$$")" || {
  printf 'Could not establish the App publication owner identity.\n' >&2
  printf '中文：无法建立 App 发布事务的拥有者身份。\n' >&2
  exit 1
}

output_bundle_identity_safe() {
  local bundle_path="$1"
  python3 -c '
import os
import plistlib
import stat
import sys

bundle = sys.argv[1]
root = os.lstat(bundle)
if not stat.S_ISDIR(root.st_mode) or root.st_uid != os.geteuid():
    raise RuntimeError("bundle root is not an owned directory")
directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
if hasattr(os, "O_NOFOLLOW"):
    directory_flags |= os.O_NOFOLLOW
root_fd = os.open(bundle, directory_flags)
try:
    contents_fd = os.open("Contents", directory_flags, dir_fd=root_fd)
    try:
        info_flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            info_flags |= os.O_NOFOLLOW
        info_fd = os.open("Info.plist", info_flags, dir_fd=contents_fd)
        try:
            info_stat = os.fstat(info_fd)
            if (not stat.S_ISREG(info_stat.st_mode)
                    or info_stat.st_uid != os.geteuid()
                    or info_stat.st_nlink != 1):
                raise RuntimeError("Info.plist is not an owned single-link file")
            with os.fdopen(os.dup(info_fd), "rb") as source:
                info = plistlib.load(source)
        finally:
            os.close(info_fd)
        expected = {
            "CFBundleIdentifier": "app.droidmatch.mac",
            "CFBundleExecutable": "DroidMatch",
            "CFBundlePackageType": "APPL",
        }
        if any(info.get(key) != value for key, value in expected.items()):
            raise RuntimeError("directory is not a DroidMatch bundle")
        macos_fd = os.open("MacOS", directory_flags, dir_fd=contents_fd)
        try:
            executable = os.stat("DroidMatch", dir_fd=macos_fd, follow_symlinks=False)
            if (not stat.S_ISREG(executable.st_mode)
                    or executable.st_uid != os.geteuid()
                    or executable.st_nlink != 1
                    or not executable.st_mode & 0o111):
                raise RuntimeError("DroidMatch executable is unsafe")
        finally:
            os.close(macos_fd)
    finally:
        os.close(contents_fd)
finally:
    os.close(root_fd)
' "${bundle_path}" >/dev/null 2>&1
}

canonical_output_safe() {
  if [[ -e "${output_path}" || -L "${output_path}" ]]; then
    if ! output_bundle_identity_safe "${output_path}"; then
      printf 'Refusing to replace an unsafe or non-DroidMatch output node.\n' >&2
      printf '中文：拒绝替换不安全或不属于 DroidMatch 的输出节点。\n' >&2
      return 1
    fi
  fi
}

create_transaction() {
  if ! python3 -c '
import os
import sys

root, owner, owner_instance = sys.argv[1:]
parent = os.path.dirname(root)
temporary = root + ".new." + owner
os.mkdir(temporary, 0o700)
try:
    markers = (("format", "droidmatch-app-publication-v2\n"),
               ("owner-pid", owner + "\n"),
               ("owner-instance", owner_instance + "\n"),
               ("state", "preparing\n"))
    for name, value in markers:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(os.path.join(temporary, name), flags, 0o600)
        try:
            os.write(fd, value.encode("ascii"))
            os.fsync(fd)
        finally:
            os.close(fd)
    temporary_fd = os.open(temporary, os.O_RDONLY)
    try:
        os.fsync(temporary_fd)
    finally:
        os.close(temporary_fd)
    os.rename(temporary, root)
    parent_fd = os.open(parent, os.O_RDONLY)
    try:
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)
except BaseException:
    try:
        for name in os.listdir(temporary):
            os.unlink(os.path.join(temporary, name))
        os.rmdir(temporary)
    except OSError:
        pass
    raise
' "${transaction_root}" "$$" "${owner_instance}" >/dev/null 2>&1; then
    printf 'Could not create a private App publication transaction.\n' >&2
    printf '中文：无法创建私有 App 发布事务。\n' >&2
    return 1
  fi
}

write_marker() {
  local marker_name="$1"
  local marker_value="$2"
  if ! python3 -c '
import os
import sys

root, name, value = sys.argv[1:]
temporary = os.path.join(root, "." + name + ".next")
destination = os.path.join(root, name)
try:
    info = os.lstat(temporary)
except FileNotFoundError:
    pass
else:
    if not os.path.isfile(temporary) or os.path.islink(temporary):
        raise RuntimeError("unsafe temporary marker")
    os.unlink(temporary)
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(temporary, flags, 0o600)
try:
    os.write(fd, (value + "\n").encode("ascii"))
    os.fsync(fd)
finally:
    os.close(fd)
os.replace(temporary, destination)
root_fd = os.open(root, os.O_RDONLY)
try:
    os.fsync(root_fd)
finally:
    os.close(root_fd)
' "${transaction_root}" "${marker_name}" "${marker_value}" >/dev/null 2>&1; then
    printf 'App publication transaction state could not be recorded.\n' >&2
    printf '中文：无法记录 App 发布事务状态。\n' >&2
    return 1
  fi
}

write_transaction_state() {
  write_marker state "$1"
}

node_identity() {
  python3 -c '
import os
import stat
import sys
info = os.lstat(sys.argv[1])
if not stat.S_ISDIR(info.st_mode):
    raise RuntimeError("publication node is not a directory")
print(f"{info.st_dev}:{info.st_ino}")
' "$1" 2>/dev/null
}

node_matches_identity() {
  local node_path="$1"
  local expected_identity="$2"
  [[ -e "${node_path}" && ! -L "${node_path}" ]] || return 1
  [[ "$(node_identity "${node_path}")" == "${expected_identity}" ]]
}

swap_exact_directories() {
  local source_path="$1"
  local destination_path="$2"
  local source_identity="$3"
  local destination_identity="$4"
  if ! python3 -c '
import ctypes
import os
import stat
import sys

source, destination, source_id, destination_id = sys.argv[1:]
def identity(path):
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode):
        raise RuntimeError("publication node is not a directory")
    return f"{info.st_dev}:{info.st_ino}"
if identity(source) != source_id or identity(destination) != destination_id:
    raise RuntimeError("publication node changed before swap")
library = ctypes.CDLL(None, use_errno=True)
try:
    renameatx_np = library.renameatx_np
except AttributeError:
    raise RuntimeError("atomic directory swap is unavailable")
renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p,
                         ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameatx_np.restype = ctypes.c_int
AT_FDCWD = -2
RENAME_SWAP = 0x00000002
if renameatx_np(AT_FDCWD, os.fsencode(source), AT_FDCWD,
                os.fsencode(destination), RENAME_SWAP) != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error))
if identity(source) != destination_id or identity(destination) != source_id:
    raise RuntimeError("atomic directory swap postcondition failed")
parent_fd = os.open(os.path.dirname(destination), os.O_RDONLY)
try:
    os.fsync(parent_fd)
finally:
    os.close(parent_fd)
' "${source_path}" "${destination_path}" \
    "${source_identity}" "${destination_identity}" >/dev/null 2>&1; then
    printf 'Atomic App publication swap failed or is unavailable.\n' >&2
    printf '中文：App 原子发布交换失败或不可用。\n' >&2
    return 1
  fi
}

install_exact_directory() {
  local source_path="$1"
  local destination_path="$2"
  local source_identity="$3"
  if ! python3 -c '
import ctypes, os, stat, sys
source, destination, source_id = sys.argv[1:]
info = os.lstat(source)
if (not stat.S_ISDIR(info.st_mode)
        or f"{info.st_dev}:{info.st_ino}" != source_id):
    raise RuntimeError("candidate changed before publication")
library = ctypes.CDLL(None, use_errno=True)
try:
    renameatx_np = library.renameatx_np
except AttributeError:
    raise RuntimeError("exclusive rename is unavailable")
renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p,
                         ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameatx_np.restype = ctypes.c_int
if renameatx_np(-2, os.fsencode(source), -2,
                os.fsencode(destination), 0x00000004) != 0:  # RENAME_EXCL
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error))
published = os.lstat(destination)
if (not stat.S_ISDIR(published.st_mode)
        or f"{published.st_dev}:{published.st_ino}" != source_id):
    raise RuntimeError("publication postcondition failed")
parent_fd = os.open(os.path.dirname(destination), os.O_RDONLY)
try:
    os.fsync(parent_fd)
finally:
    os.close(parent_fd)
' "${source_path}" "${destination_path}" "${source_identity}" \
    >/dev/null 2>&1; then
    printf 'Initial App publication rename failed.\n' >&2
    printf '中文：首次 App 发布重命名失败。\n' >&2
    return 1
  fi
}

read_marker() {
  local marker_name="$1"
  local marker_value=""
  IFS= read -r marker_value <"${transaction_root}/${marker_name}" || return 1
  printf '%s' "${marker_value}"
}

# shellcheck source=mac-app-publication-recovery.sh
source "${repo_root}/tools/mac-app-publication-recovery.sh"

handle_exit() {
  local status="$1"
  trap - EXIT INT TERM
  if [[ "${transaction_owned}" == true \
      && ( -e "${transaction_root}" || -L "${transaction_root}" ) ]]; then
    if [[ "${publication_started}" == true \
        && "${publication_complete}" != true ]]; then
      if ! rollback_owned_publication; then
        printf 'App publication recovery is incomplete; the private transaction was preserved.\n' >&2
        printf '中文：App 发布恢复未完成；已保留私有事务。\n' >&2
        exit "${status}"
      fi
    fi
    if ! remove_transaction_tree; then
      printf 'App publication cleanup is incomplete; inspect the private transaction.\n' >&2
      printf '中文：App 发布清理未完成；请检查保留的私有事务。\n' >&2
    fi
  fi
  exit "${status}"
}

python3 "${repo_root}/tools/check-mac-app-not-running.py" "${output_path}"
if [[ -e "${transaction_root}" || -L "${transaction_root}" ]]; then
  recover_stale_transaction
fi
canonical_output_safe
create_transaction
transaction_owned=true
trap 'handle_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

droidmatch_build_source_contract() {
  if [[ "${evidence_ready}" == true ]]; then
    droidmatch_git_official_repository_contract "${repo_root}"
  else
    droidmatch_git_source_contract "${repo_root}"
  fi
}

droidmatch_build_source_contract || {
  printf 'Git source provenance is unsafe for the product bundle.\n' >&2
  exit 1
}
source_revision="$(droidmatch_git_head "${repo_root}" || true)"
if [[ -z "${source_revision}" ]]; then
  printf 'Could not resolve the full Git source revision for the product bundle.\n' >&2
  exit 1
fi
source_dirty=false
source_status="$(droidmatch_git_status "${repo_root}")" || {
  printf 'Could not inspect the initial Git source state for the product bundle.\n' >&2
  exit 1
}
if [[ -n "${source_status}" ]]; then
  source_dirty=true
fi
if [[ "${evidence_ready}" == true && "${source_dirty}" != false ]]; then
  printf '%s\n' 'Evidence-ready builds require a clean official source tree.' >&2
  exit 1
fi

if [[ "${evidence_ready}" == true ]]; then
  DROIDMATCH_SWIFT_SCRATCH_PATH="${transaction_root}/swift-scratch"
  export DROIDMATCH_SWIFT_SCRATCH_PATH
fi
droidmatch_prepare_swift_build_environment "${repo_root}"
swift_build_args=(
  build
  --package-path "${repo_root}/mac"
  --configuration "${configuration}"
  "${droidmatch_swift_compat_args[@]}"
)
if [[ -n "${DROIDMATCH_SWIFT_SCRATCH_PATH:-}" ]]; then
  swift_build_args+=(--scratch-path "${DROIDMATCH_SWIFT_SCRATCH_PATH}")
fi

droidmatch_run_with_immutable_swift_lock \
  swift "${swift_build_args[@]}" --product DroidMatch

bin_path="$(
  droidmatch_run_with_immutable_swift_lock \
    swift "${swift_build_args[@]}" --show-bin-path
)"
executable_path="${bin_path}/DroidMatch"
resource_bundle_path="${bin_path}/DroidMatchMac_DroidMatchApp.bundle"
core_resource_bundle_path="${bin_path}/DroidMatchMac_DroidMatchCore.bundle"
protobuf_resource_bundle_path="${bin_path}/SwiftProtobuf_SwiftProtobuf.bundle"
candidate_path="${transaction_root}/candidate.app"
icon_work_path="${transaction_root}/icon-work"

if [[ ! -x "${executable_path}" \
    || ! -d "${resource_bundle_path}" \
    || ! -f "${core_resource_bundle_path}/device-marketing-name-aliases.json" \
    || ! -f "${protobuf_resource_bundle_path}/PrivacyInfo.xcprivacy" ]]; then
  printf 'SwiftPM did not produce the expected executable, product resources, or dependency privacy manifest.\n' >&2
  exit 1
fi

install -d "${candidate_path}/Contents/MacOS" \
  "${candidate_path}/Contents/Resources"
install -m 0755 "${executable_path}" \
  "${candidate_path}/Contents/MacOS/DroidMatch"
install -m 0644 "${repo_root}/mac/App/Info.plist" \
  "${candidate_path}/Contents/Info.plist"
plutil -replace DroidMatchSourceRevision -string "${source_revision}" \
  "${candidate_path}/Contents/Info.plist"
plutil -replace DroidMatchSourceDirty -bool "${source_dirty}" \
  "${candidate_path}/Contents/Info.plist"
plutil -replace DroidMatchBuildConfiguration -string "${configuration}" \
  "${candidate_path}/Contents/Info.plist"
plutil -replace DroidMatchEvidenceBuild -bool "${evidence_ready}" \
  "${candidate_path}/Contents/Info.plist"
plutil -replace DroidMatchBundledAdbRequired -bool "${sandboxed}" \
  "${candidate_path}/Contents/Info.plist"
install -m 0644 "${repo_root}/mac/App/PrivacyInfo.xcprivacy" \
  "${candidate_path}/Contents/Resources/PrivacyInfo.xcprivacy"
ditto "${resource_bundle_path}" \
  "${candidate_path}/Contents/Resources/DroidMatchMac_DroidMatchApp.bundle"
install -m 0644 "${core_resource_bundle_path}/device-marketing-name-aliases.json" \
  "${candidate_path}/Contents/Resources/device-marketing-name-aliases.json"
ditto "${protobuf_resource_bundle_path}" \
  "${candidate_path}/Contents/Resources/SwiftProtobuf_SwiftProtobuf.bundle"
ditto "${repo_root}/third_party/mac" \
  "${candidate_path}/Contents/Resources/Legal"

if [[ "${sandboxed}" == true ]]; then
  adb_source="${adb_source_override}"
  if [[ -z "${adb_source}" ]]; then
    adb_source="${DROIDMATCH_ADB:-}"
    if [[ -z "${adb_source}" && -n "${ANDROID_HOME:-}" ]]; then
      adb_source="${ANDROID_HOME}/platform-tools/adb"
    fi
    if [[ -z "${adb_source}" && -n "${ANDROID_SDK_ROOT:-}" ]]; then
      adb_source="${ANDROID_SDK_ROOT}/platform-tools/adb"
    fi
    if [[ -z "${adb_source}" ]]; then
      adb_source="${HOME}/Library/Android/sdk/platform-tools/adb"
    fi
  fi
  if [[ ! -x "${adb_source}" ]]; then
    printf 'Sandboxed build requires an executable adb via DROIDMATCH_ADB or Android SDK platform-tools.\n' >&2
    exit 1
  fi
  platform_tools_dir="$(cd "$(dirname "${adb_source}")" && pwd)"
  install -d "${candidate_path}/Contents/Resources/platform-tools"
  install -m 0755 "${adb_source}" \
    "${candidate_path}/Contents/Resources/platform-tools/adb"
  if [[ ! -f "${platform_tools_dir}/NOTICE.txt" ]]; then
    printf 'Sandboxed build requires platform-tools NOTICE.txt beside adb.\n' >&2
    exit 1
  fi
  install -m 0644 "${platform_tools_dir}/NOTICE.txt" \
    "${candidate_path}/Contents/Resources/platform-tools/NOTICE.txt"
fi

bash "${repo_root}/tools/build-mac-icon.sh" "${repo_root}" \
  "${icon_work_path}" "${candidate_path}/Contents/Resources/DroidMatch.icns"

# Re-read provenance after compilation and resource assembly. A source edit or
# branch move during the build must not leave a clean-looking stale artifact.
droidmatch_build_source_contract || {
  printf 'Git source provenance became unsafe during product assembly.\n' >&2
  exit 1
}
post_build_revision="$(droidmatch_git_head "${repo_root}" || true)"
post_build_dirty=false
post_build_status="$(droidmatch_git_status "${repo_root}")" || {
  printf 'Could not recheck Git source state after product assembly.\n' >&2
  exit 1
}
if [[ -n "${post_build_status}" ]]; then
  post_build_dirty=true
fi
[[ "${post_build_revision}" == "${source_revision}" ]] || {
  printf 'Git source revision changed while building the product bundle.\n' >&2
  exit 1
}
if [[ "${post_build_dirty}" == true && "${source_dirty}" == false ]]; then
  source_dirty=true
  plutil -replace DroidMatchSourceDirty -bool "${source_dirty}" \
    "${candidate_path}/Contents/Info.plist"
fi

plutil -lint "${candidate_path}/Contents/Info.plist" >/dev/null
if [[ "${sandboxed}" == true ]]; then
  embedded_adb="${candidate_path}/Contents/Resources/platform-tools/adb"
  # The builder accepts a caller-selected unsigned custom adb, so the input's
  # existing signature is not an authenticity boundary. On macOS 26, a stale
  # invalid verdict is reused by CDHash across fresh copies; verifying before
  # replacement can therefore permanently block the local identity intended to
  # fix that state. Always replace only the embedded copy's signature first.
  # codesign failure and the complete candidate/final verifiers remain fail-closed,
  # the SDK source is untouched, and the outer seal binds the resulting bytes.
  # 中文：输入签名不是信任根；始终先只重签内置副本，SDK 源文件不变，外层 seal
  # 绑定结果字节，签名或候选/最终验证失败仍会安全终止。
  if ! codesign --force --options runtime --sign - "${embedded_adb}" >/dev/null 2>&1; then
    printf 'Signing of the embedded adb candidate failed.\n' >&2
    printf '中文：内置 adb 候选签名失败。\n' >&2
    exit 1
  fi
  if ! codesign --force --options runtime --sign - \
        --entitlements "${repo_root}/mac/App/DroidMatch.entitlements" \
        "${candidate_path}" >/dev/null 2>&1; then
    printf 'Ad-hoc signing of the App candidate failed.\n' >&2
    printf '中文：App 候选产物的 ad-hoc 签名失败。\n' >&2
    exit 1
  fi
else
  if ! codesign --force --options runtime --sign - "${candidate_path}" \
      >/dev/null 2>&1; then
    printf 'Ad-hoc signing of the App candidate failed.\n' >&2
    printf '中文：App 候选产物的 ad-hoc 签名失败。\n' >&2
    exit 1
  fi
fi
if ! codesign --verify --deep --strict "${candidate_path}" \
    >/dev/null 2>&1; then
  printf 'Signature verification of the App candidate failed.\n' >&2
  printf '中文：App 候选产物签名校验失败。\n' >&2
  exit 1
fi

droidmatch_build_source_contract || {
  printf 'Git source provenance became unsafe after product signing.\n' >&2
  exit 1
}
final_source_revision="$(droidmatch_git_head "${repo_root}" || true)"
final_source_dirty=false
final_source_status="$(droidmatch_git_status "${repo_root}")" || {
  printf 'Could not recheck Git source state after product signing.\n' >&2
  exit 1
}
if [[ -n "${final_source_status}" ]]; then
  final_source_dirty=true
fi
[[ "${final_source_revision}" == "${source_revision}" \
    && "${final_source_dirty}" == "${source_dirty}" ]] || {
  printf 'Git source state changed after product bundle provenance was signed.\n' >&2
  exit 1
}

if [[ "${sandboxed}" == true ]]; then
  candidate_check_args=(--sandboxed --defer-adb-execution)
  [[ "${evidence_ready}" != true ]] || candidate_check_args+=(--evidence-ready)
  if ! python3 "${repo_root}/tools/check-mac-app-bundle.py" \
      "${candidate_check_args[@]}" "${candidate_path}" \
      >/dev/null 2>&1; then
    printf 'Product-boundary validation of the App candidate failed.\n' >&2
    printf '中文：App 候选产物的产品边界校验失败。\n' >&2
    exit 1
  fi
else
  if ! python3 "${repo_root}/tools/check-mac-app-bundle.py" \
      "${candidate_path}" >/dev/null 2>&1; then
    printf 'Product-boundary validation of the App candidate failed.\n' >&2
    printf '中文：App 候选产物的产品边界校验失败。\n' >&2
    exit 1
  fi
fi
output_bundle_identity_safe "${candidate_path}" || {
  printf 'Verified App candidate has an unsafe publication identity.\n' >&2
  exit 1
}

candidate_identity="$(node_identity "${candidate_path}")"
write_marker candidate-id "${candidate_identity}"
write_transaction_state prepared

canonical_output_safe
published_replacement=false
if [[ -e "${output_path}" ]]; then
  published_replacement=true
  output_identity="$(node_identity "${output_path}")"
  canonical_output_safe
  write_marker output-id "${output_identity}"
  write_transaction_state swapping
  publication_started=true
  python3 "${repo_root}/tools/check-mac-app-not-running.py" "${output_path}"
  swap_exact_directories "${candidate_path}" "${output_path}" \
    "${candidate_identity}" "${output_identity}"
  write_transaction_state verifying-swapped
else
  write_transaction_state installing-new
  publication_started=true
  python3 "${repo_root}/tools/check-mac-app-not-running.py" "${output_path}"
  install_exact_directory "${candidate_path}" "${output_path}" \
    "${candidate_identity}"
  write_transaction_state verifying-installed-new
fi

if ! droidmatch_check_app_with_retry \
    "${repo_root}/tools/check-mac-app-bundle.py" \
    "${output_path}" "${sandboxed}" "${evidence_ready}" >/dev/null 2>&1; then
  printf 'Product-boundary validation of the published App failed.\n' >&2
  printf '中文：已发布 App 的产品边界校验失败。\n' >&2
  exit 1
fi
if [[ "${published_replacement}" == true ]]; then
  write_transaction_state swapped
else
  write_transaction_state installed-new
fi
publication_complete=true

if ! remove_transaction_tree; then
  printf 'The verified App was published, but transaction cleanup is incomplete.\n' >&2
  printf '中文：已发布验证通过的 App，但事务清理未完成。\n' >&2
  exit 1
fi
transaction_owned=false
trap - EXIT INT TERM

printf 'Built local DroidMatch app: %s\n' "${output_path}"
printf '中文：已构建本地 DroidMatch App：%s\n' "${output_path}"
