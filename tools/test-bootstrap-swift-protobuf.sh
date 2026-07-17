#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-protoc-bootstrap.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

checkout="${test_root}/swift-protobuf"
resolved="${test_root}/Package.resolved"
scratch_parent="${test_root}/scratch"
fake_bin="${test_root}/fake-bin"
fake_swift="${fake_bin}/swift"
fake_swiftc="${fake_bin}/swiftc"
swift_calls="${test_root}/swift-calls"
swiftc_calls="${test_root}/swiftc-calls"
real_uname="$(command -v uname)"
real_git="$(command -v git)"
real_python="$(command -v python3)"
mkdir -p "${checkout}" "${fake_bin}"

git -C "${checkout}" init -q
git -C "${checkout}" config user.name 'DroidMatch Test'
git -C "${checkout}" config user.email 'test@invalid.example'
printf '%s\n' '// swift-tools-version: 6.0' >"${checkout}/Package.swift"
printf '%s\n' 'Ignored.swift' >"${checkout}/.gitignore"
git -C "${checkout}" add Package.swift .gitignore
git -C "${checkout}" commit -qm initial
pinned_revision="$(git -C "${checkout}" rev-parse HEAD)"

cat >"${resolved}" <<JSON
{
  "pins": [{
    "identity": "swift-protobuf",
    "state": {"revision": "${pinned_revision}", "version": "test"}
  }],
  "version": 3
}
JSON

cat >"${fake_swift}" <<'FAKE_SWIFT'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_SWIFT_CALLS:?}"
if [[ "${1:-}" == package ]]; then
  exit 0
fi

scratch=""
configuration="debug"
show_bin_path=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --scratch-path) scratch="$2"; shift 2 ;;
    --configuration) configuration="$2"; shift 2 ;;
    --show-bin-path) show_bin_path=1; shift ;;
    *) shift ;;
  esac
done
[[ -n "${scratch}" ]]
bin_path="${scratch}/${configuration}"
if [[ "${show_bin_path}" -eq 1 ]]; then
  if [[ "${FAKE_SWIFT_BEHAVIOR:-success}" == delete-product ]]; then
    rm -f "${bin_path}/protoc-gen-swift"
  fi
  printf '%s\n' "${bin_path}"
  exit 0
fi

if [[ "${FAKE_SWIFT_BEHAVIOR:-success}" == build-failure ]]; then
  exit 42
fi
mkdir -p "${bin_path}"
printf '%s\n' '#!/usr/bin/env bash' \
  "printf '%s\\n' '${FAKE_PRODUCT_TEXT:-generated}'" \
  >"${bin_path}/protoc-gen-swift"
chmod 0755 "${bin_path}/protoc-gen-swift"

case "${FAKE_SWIFT_BEHAVIOR:-success}" in
  module-cache-symlink)
    rm -rf "${CLANG_MODULE_CACHE_PATH:?}"
    ln -s "${FAKE_SYMLINK_DESTINATION:?}" "${CLANG_MODULE_CACHE_PATH}"
    ;;
  dirty-checkout)
    printf '%s\n' '// injected during build' >"${FAKE_CHECKOUT:?}/Injected.swift"
    ;;
  hardlink-product)
    ln "${bin_path}/protoc-gen-swift" "${scratch}/second-product-link"
    ;;
  target-directory)
    mkdir "${FAKE_INSTALL_PATH:?}"
    ;;
  target-symlink)
    ln -s "${FAKE_PROTECTED_PATH:?}" "${FAKE_INSTALL_PATH:?}"
    ;;
  hardlink-install-target)
    ln "${FAKE_INSTALL_PATH:?}" "${FAKE_INSTALL_PEER:?}"
    ;;
esac
FAKE_SWIFT

cat >"${fake_swiftc}" <<'FAKE_SWIFTC'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_SWIFTC_CALLS:?}"
case "${FAKE_SWIFTC_MODE:-default}" in
  default) exit 0 ;;
  arm64e)
    [[ "$*" == *'-target arm64e-apple-macosx13.0'* ]]
    ;;
  unavailable) exit 1 ;;
  *) exit 64 ;;
esac
FAKE_SWIFTC

cat >"${fake_bin}/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_UNAME_MODE:-native}" == darwin-arm64 ]]; then
  case "${1:-}" in
    -s) printf '%s\n' Darwin ;;
    -m) printf '%s\n' arm64 ;;
    *) printf '%s\n' Darwin ;;
  esac
else
  exec "${REAL_UNAME:?}" "$@"
fi
FAKE_UNAME

cat >"${fake_bin}/xcrun" <<'FAKE_XCRUN'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_XCRUN_MODE:-unavailable}" == available ]]; then
  printf '%s\n' "${FAKE_SDK_PATH:?}"
  exit 0
fi
exit 1
FAKE_XCRUN

chmod +x "${fake_swift}" "${fake_swiftc}" "${fake_bin}/uname" \
  "${fake_bin}/xcrun"

run_bootstrap() {
  local install_path="$1"
  local scratch_path="$2"
  PATH="${fake_bin}:${PATH}" \
  REAL_UNAME="${real_uname}" \
  SWIFT="${fake_swift}" \
  SWIFTC="${fake_swiftc}" \
  GIT="${real_git}" \
  PYTHON3="${real_python}" \
  FAKE_SWIFT_CALLS="${swift_calls}" \
  FAKE_SWIFTC_CALLS="${swiftc_calls}" \
  FAKE_SWIFT_BEHAVIOR="${CASE_SWIFT_BEHAVIOR:-success}" \
  FAKE_SWIFTC_MODE="${CASE_SWIFTC_MODE:-default}" \
  FAKE_UNAME_MODE="${CASE_UNAME_MODE:-native}" \
  FAKE_XCRUN_MODE="${CASE_XCRUN_MODE:-unavailable}" \
  FAKE_SDK_PATH="${test_root}/fake-sdk" \
  FAKE_PRODUCT_TEXT="${CASE_PRODUCT_TEXT:-generated}" \
  FAKE_SYMLINK_DESTINATION="${test_root}/module-cache-target" \
  FAKE_CHECKOUT="${checkout}" \
  FAKE_INSTALL_PATH="${install_path}" \
  FAKE_INSTALL_PEER="${test_root}/concurrent-install-peer" \
  FAKE_PROTECTED_PATH="${CASE_PROTECTED_PATH:-${test_root}/protected}" \
  SWIFT_PROTOBUF_PACKAGE_RESOLVED="${resolved}" \
  SWIFT_PROTOBUF_CHECKOUT="${checkout}" \
  SWIFT_PROTOBUF_TOOL_SCRATCH_PATH="${scratch_path}" \
  PROTOC_GEN_SWIFT="${install_path}" \
    bash "${repo_root}/tools/bootstrap-swift-protobuf.sh"
}

expect_failure() {
  local output="$1"
  local install_path="$2"
  local scratch_path="$3"
  local status
  set +e
  run_bootstrap "${install_path}" "${scratch_path}" >"${output}" 2>&1
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
}

signature() {
  "${real_python}" - "$1" <<'PY'
import hashlib
import os
import stat
import sys

path = sys.argv[1]
info = os.stat(path, follow_symlinks=False)
with open(path, "rb") as handle:
    digest = hashlib.sha256(handle.read()).hexdigest()
print(f"{info.st_dev}:{info.st_ino}:{stat.S_IMODE(info.st_mode)}:{info.st_nlink}:{digest}")
PY
}

seed_old_binary() {
  local path="$1"
  mkdir -p "$(dirname "${path}")"
  printf '%s\n' '#!/usr/bin/env bash' 'printf old' >"${path}"
  chmod 0755 "${path}"
}

assert_private_executable() {
  "${real_python}" - "$1" <<'PY'
import os
import stat
import sys

info = os.stat(sys.argv[1], follow_symlinks=False)
assert stat.S_ISREG(info.st_mode)
assert stat.S_IMODE(info.st_mode) == 0o755
assert info.st_nlink == 1
PY
}

mkdir -p "${test_root}/fake-sdk" "${test_root}/module-cache-target"
: >"${swift_calls}"
: >"${swiftc_calls}"

# Default-target publication succeeds, replaces an old binary atomically, and
# never reuses the same SwiftPM scratch directory across invocations.
default_install="${test_root}/default-install/protoc-gen-swift"
CASE_PRODUCT_TEXT=first run_bootstrap "${default_install}" "${scratch_parent}" \
  >"${test_root}/default-first.out"
grep -Fq 'Installed pinned protoc-gen-swift' "${test_root}/default-first.out"
assert_private_executable "${default_install}"
first_signature="$(signature "${default_install}")"
CASE_PRODUCT_TEXT=second run_bootstrap "${default_install}" "${scratch_parent}" \
  >"${test_root}/default-second.out"
assert_private_executable "${default_install}"
[[ "$(signature "${default_install}")" != "${first_signature}" ]]
if grep -Fq -- '--triple arm64e-apple-macosx13.0' "${swift_calls}"; then
  printf 'default target unexpectedly used the arm64e fallback\n' >&2
  exit 1
fi
"${real_python}" - "${swift_calls}" <<'PY'
import shlex
import sys

scratches = set()
for line in open(sys.argv[1], encoding="utf-8"):
    arguments = shlex.split(line)
    if "--scratch-path" in arguments:
        scratches.add(arguments[arguments.index("--scratch-path") + 1])
assert len(scratches) == 2, scratches
PY

# A failing default probe uses the arm64e fallback only after a successful
# explicit probe. Fake uname/xcrun keep this runnable on x86_64 Linux.
: >"${swift_calls}"
fallback_install="${test_root}/fallback-install/protoc-gen-swift"
CASE_SWIFTC_MODE=arm64e \
CASE_UNAME_MODE=darwin-arm64 \
CASE_XCRUN_MODE=available \
run_bootstrap "${fallback_install}" "${scratch_parent}" \
  >"${test_root}/fallback.out"
grep -Fq 'Swift target fallback: using arm64e' "${test_root}/fallback.out"
grep -Fq -- '--triple arm64e-apple-macosx13.0' "${swift_calls}"
assert_private_executable "${fallback_install}"

# No usable fallback fails before build and leaves the existing binary intact.
unavailable_install="${test_root}/unavailable-install/protoc-gen-swift"
seed_old_binary "${unavailable_install}"
unavailable_before="$(signature "${unavailable_install}")"
: >"${swift_calls}"
CASE_SWIFTC_MODE=unavailable \
CASE_UNAME_MODE=darwin-arm64 \
CASE_XCRUN_MODE=available \
expect_failure "${test_root}/fallback-unavailable.out" \
  "${unavailable_install}" "${scratch_parent}"
grep -Fq 'arm64e fallback is unavailable' \
  "${test_root}/fallback-unavailable.out"
[[ "$(signature "${unavailable_install}")" == "${unavailable_before}" ]]
[[ ! -s "${swift_calls}" ]]

# Both pre-existing and build-time checkout dirt are rejected, including
# untracked files, and neither failure reaches publication.
dirty_install="${test_root}/dirty-install/protoc-gen-swift"
seed_old_binary "${dirty_install}"
dirty_before="$(signature "${dirty_install}")"
printf '%s\n' '// untracked before bootstrap' >"${checkout}/Untracked.swift"
expect_failure "${test_root}/untracked.out" \
  "${dirty_install}" "${scratch_parent}"
grep -Fq 'tracked or untracked modifications' "${test_root}/untracked.out"
[[ "$(signature "${dirty_install}")" == "${dirty_before}" ]]
rm "${checkout}/Untracked.swift"

printf '%s\n' '// ignored but still untracked' >"${checkout}/Ignored.swift"
expect_failure "${test_root}/ignored-untracked.out" \
  "${dirty_install}" "${scratch_parent}"
grep -Fq 'tracked or untracked modifications' \
  "${test_root}/ignored-untracked.out"
[[ "$(signature "${dirty_install}")" == "${dirty_before}" ]]
rm "${checkout}/Ignored.swift"

CASE_SWIFT_BEHAVIOR=dirty-checkout \
expect_failure "${test_root}/dirty-during-build.out" \
  "${dirty_install}" "${scratch_parent}"
grep -Fq 'tracked or untracked modifications' \
  "${test_root}/dirty-during-build.out"
[[ "$(signature "${dirty_install}")" == "${dirty_before}" ]]
rm "${checkout}/Injected.swift"

# Symlinked write ancestors and a module cache swapped during the build fail
# closed. The old executable remains byte-for-byte and inode-for-inode intact.
ancestor_install="${test_root}/ancestor-install/protoc-gen-swift"
seed_old_binary "${ancestor_install}"
ancestor_before="$(signature "${ancestor_install}")"
mkdir "${test_root}/real-scratch"
ln -s "${test_root}/real-scratch" "${test_root}/scratch-link"
expect_failure "${test_root}/scratch-ancestor.out" \
  "${ancestor_install}" "${test_root}/scratch-link"
grep -Fq 'scratch parent is unsafe' "${test_root}/scratch-ancestor.out"
[[ "$(signature "${ancestor_install}")" == "${ancestor_before}" ]]

mkdir -p "${test_root}/real-install-parent"
ln -s "${test_root}/real-install-parent" "${test_root}/install-parent-link"
expect_failure "${test_root}/install-ancestor.out" \
  "${test_root}/install-parent-link/protoc-gen-swift" "${scratch_parent}"
grep -Fq 'install directory is unsafe' "${test_root}/install-ancestor.out"
[[ ! -e "${test_root}/real-install-parent/protoc-gen-swift" ]]

CASE_SWIFT_BEHAVIOR=module-cache-symlink \
expect_failure "${test_root}/module-cache-symlink.out" \
  "${ancestor_install}" "${scratch_parent}"
grep -Fq 'module cache identity changed during build' \
  "${test_root}/module-cache-symlink.out"
[[ "$(signature "${ancestor_install}")" == "${ancestor_before}" ]]

# Neither an existing hard-linked install target nor a hard-linked build
# product is accepted as a publication endpoint/source.
hardlink_install="${test_root}/hardlink-install/protoc-gen-swift"
seed_old_binary "${hardlink_install}"
ln "${hardlink_install}" "${test_root}/old-product-peer"
hardlink_before="$(signature "${hardlink_install}")"
expect_failure "${test_root}/old-hardlink.out" \
  "${hardlink_install}" "${scratch_parent}"
grep -Fq 'install target is unsafe' "${test_root}/old-hardlink.out"
[[ "$(signature "${hardlink_install}")" == "${hardlink_before}" ]]
[[ "$(signature "${test_root}/old-product-peer")" == "${hardlink_before}" ]]

built_hardlink_install="${test_root}/built-hardlink-install/protoc-gen-swift"
seed_old_binary "${built_hardlink_install}"
built_hardlink_before="$(signature "${built_hardlink_install}")"
CASE_SWIFT_BEHAVIOR=hardlink-product \
expect_failure "${test_root}/built-hardlink.out" \
  "${built_hardlink_install}" "${scratch_parent}"
grep -Fq 'safe single-link executable' "${test_root}/built-hardlink.out"
[[ "$(signature "${built_hardlink_install}")" == "${built_hardlink_before}" ]]

# Deterministic mutation after initial snapshots proves publication does not
# move into a concurrently inserted directory or follow an inserted symlink.
directory_install="${test_root}/directory-race/protoc-gen-swift"
mkdir -p "$(dirname "${directory_install}")"
CASE_SWIFT_BEHAVIOR=target-directory \
expect_failure "${test_root}/directory-race.out" \
  "${directory_install}" "${scratch_parent}"
grep -Fq 'Atomic protoc-gen-swift publication failed' \
  "${test_root}/directory-race.out"
[[ -d "${directory_install}" ]]
[[ -z "$(find "${directory_install}" -mindepth 1 -maxdepth 1 -print -quit)" ]]

protected="${test_root}/protected"
printf '%s\n' protected >"${protected}"
symlink_install="${test_root}/symlink-race/protoc-gen-swift"
mkdir -p "$(dirname "${symlink_install}")"
CASE_SWIFT_BEHAVIOR=target-symlink \
CASE_PROTECTED_PATH="${protected}" \
expect_failure "${test_root}/symlink-race.out" \
  "${symlink_install}" "${scratch_parent}"
grep -Fq 'Atomic protoc-gen-swift publication failed' \
  "${test_root}/symlink-race.out"
[[ -L "${symlink_install}" ]]
[[ "$(cat "${protected}")" == protected ]]

# Build and install-source failures are transactional: an existing executable
# retains its inode, mode, link count, and content.
failure_install="${test_root}/failure-install/protoc-gen-swift"
seed_old_binary "${failure_install}"
failure_before="$(signature "${failure_install}")"
CASE_SWIFT_BEHAVIOR=build-failure \
expect_failure "${test_root}/build-failure.out" \
  "${failure_install}" "${scratch_parent}"
[[ "$(signature "${failure_install}")" == "${failure_before}" ]]

CASE_SWIFT_BEHAVIOR=hardlink-install-target \
expect_failure "${test_root}/install-failure.out" \
  "${failure_install}" "${scratch_parent}"
grep -Fq 'Atomic protoc-gen-swift publication failed' \
  "${test_root}/install-failure.out"
rm "${test_root}/concurrent-install-peer"
[[ "$(signature "${failure_install}")" == "${failure_before}" ]]

printf 'SwiftProtobuf bootstrap tests passed.\n'
printf '中文：SwiftProtobuf 引导安装测试通过。\n'
