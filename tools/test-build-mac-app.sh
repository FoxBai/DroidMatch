#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-app-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT
real_python="$(command -v python3)"

mock_bin="${test_root}/bin"
mock_state="${test_root}/state"
swift_bin="${test_root}/swift-bin"
module_cache="${test_root}/module-cache"
mock_platform_tools="${test_root}/platform-tools"
mkdir -p "${mock_bin}" "${mock_state}" \
  "${mock_platform_tools}" \
  "${module_cache}" \
  "${swift_bin}/DroidMatchMac_DroidMatchCore.bundle" \
  "${swift_bin}/DroidMatchMac_DroidMatchApp.bundle/en.lproj" \
  "${swift_bin}/DroidMatchMac_DroidMatchApp.bundle/zh-hans.lproj" \
  "${swift_bin}/SwiftProtobuf_SwiftProtobuf.bundle"
printf 'mock-new-executable\n' >"${swift_bin}/DroidMatch"
chmod +x "${swift_bin}/DroidMatch"
printf 'mock resource\n' \
  >"${swift_bin}/DroidMatchMac_DroidMatchApp.bundle/Info.plist"
printf 'mock privacy\n' \
  >"${swift_bin}/SwiftProtobuf_SwiftProtobuf.bundle/PrivacyInfo.xcprivacy"
/bin/cp "${repo_root}/mac/Sources/DroidMatchCore/Resources/device-marketing-name-aliases.json" "${swift_bin}/DroidMatchMac_DroidMatchCore.bundle/"
printf '#!/usr/bin/env bash\nexit 0\n' >"${mock_platform_tools}/adb"
printf 'mock platform-tools notice\n' >"${mock_platform_tools}/NOTICE.txt"
chmod +x "${mock_platform_tools}/adb"

cat >"${mock_bin}/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"rev-parse HEAD"*)
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    ;;
  *"status --porcelain=v1 --untracked-files=all"*)
    ;;
  *)
    exit 64
    ;;
esac
MOCK_GIT

cat >"${mock_bin}/swift" <<'MOCK_SWIFT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_STATE}/swift-calls"
if [[ "${1:-}" == */render-mac-icon.swift ]]; then
  if [[ "${MOCK_BUILD_MODE:-success}" == "icon_fail" ]]; then
    exit 1
  fi
  printf 'master icon\n' >"${2}"
elif [[ "$*" == *"--show-bin-path"* ]]; then
  printf '%s\n' "${MOCK_SWIFT_BIN}"
elif [[ "${MOCK_BUILD_MODE:-success}" == "build_fail" ]]; then
  printf 'mock Swift build failed\n' >&2
  exit 1
fi
MOCK_SWIFT

cat >"${mock_bin}/swiftc" <<'MOCK_SWIFTC'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'-target arm64e-apple-macosx13.0'* ]]; then
  exit "${MOCK_SWIFTC_ARM64E_STATUS:-0}"
fi
exit "${MOCK_SWIFTC_DEFAULT_STATUS:-0}"
MOCK_SWIFTC

cat >"${mock_bin}/xcrun" <<'MOCK_XCRUN'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'--show-sdk-path'* ]]; then
  printf '/mock/MacOSX.sdk\n'
  exit 0
fi
exit 64
MOCK_XCRUN

cat >"${mock_bin}/uname" <<'MOCK_UNAME'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-m" ]]; then
  printf '%s\n' "${MOCK_UNAME_MACHINE:-arm64}"
  exit 0
fi
exec /usr/bin/uname "$@"
MOCK_UNAME

cat >"${mock_bin}/plutil" <<'MOCK_PLUTIL'
#!/usr/bin/env bash
set -euo pipefail
exit 0
MOCK_PLUTIL

cat >"${mock_bin}/ditto" <<'MOCK_DITTO'
#!/usr/bin/env bash
set -euo pipefail
/bin/cp -R "$1" "$2"
MOCK_DITTO

cat >"${mock_bin}/sips" <<'MOCK_SIPS'
#!/usr/bin/env bash
set -euo pipefail
output=""
previous=""
for argument in "$@"; do
  if [[ "${previous}" == "--out" ]]; then
    output="${argument}"
  fi
  previous="${argument}"
done
printf 'resized icon\n' >"${output}"
MOCK_SIPS

cat >"${mock_bin}/iconutil" <<'MOCK_ICONUTIL'
#!/usr/bin/env bash
set -euo pipefail
output=""
previous=""
for argument in "$@"; do
  if [[ "${previous}" == "-o" ]]; then
    output="${argument}"
  fi
  previous="${argument}"
done
if [[ "$*" == *'-c iconset'* ]]; then
  mkdir -p "${output}"
else
  printf 'mock icns\n' >"${output}"
fi
MOCK_ICONUTIL

cat >"${mock_bin}/codesign" <<'MOCK_CODESIGN'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_STATE}/codesign-calls"
mode="${MOCK_CODESIGN_MODE:-success}"
if [[ "${mode}" == "unsigned" && "${1:-}" == "-d" ]]; then exit 1; fi
if [[ ( "${mode}" == "verify_fail" && "$*" == *'--verify'* ) \
    || ( "${mode}" == "stale_nested" && "$*" == *'--verify'* \
      && "$*" == *'/platform-tools/adb'* ) \
    || ( "${mode}" == "sign_fail" && "$*" != *'--verify'* ) \
    || ( "${mode}" == "nested_sign_fail" && "$*" == *'/platform-tools/adb'* ) \
    || ( "${mode}" == "outer_sign_fail" && "$*" == *'--entitlements'* ) ]]; then
  printf 'SECRET_TOOL_SUBJECT\n' >&2
  exit 1
fi
MOCK_CODESIGN

cat >"${mock_bin}/python3" <<'MOCK_PYTHON'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-c" && "${2:-}" == *"renameatx_np"* ]]; then
  source_path="${3}"
  destination_path="${4}"
  if [[ "${2}" == *"0x00000004"* ]]; then
    case "${MOCK_INSTALL_RACE_MODE:-none}" in
      empty_directory)
        [[ -f "${MOCK_STATE}/checker-complete" ]]
        /bin/mkdir "${destination_path}"
        exit 1
        ;;
      unknown_node)
        [[ -f "${MOCK_STATE}/checker-complete" ]]
        printf 'race-owned-node\n' >"${destination_path}"
        exit 1
        ;;
    esac
    [[ ! -e "${destination_path}" && ! -L "${destination_path}" ]] || exit 1
    /bin/mv "${source_path}" "${destination_path}"
    if [[ "${MOCK_INSTALL_RACE_MODE:-none}" == "kill_after_install" ]]; then
      kill -9 "${PPID}"
    fi
    exit 0
  fi
  if [[ "${MOCK_SWAP_MODE:-success}" == "fail" ]]; then
    exit 1
  fi
  temporary_path="${source_path}.mock-swap"
  /bin/mv "${source_path}" "${temporary_path}"
  /bin/mv "${destination_path}" "${source_path}"
  /bin/mv "${temporary_path}" "${destination_path}"
  if [[ "${MOCK_SWAP_MODE:-success}" == "kill_after_swap" ]]; then
    kill -9 "${PPID}"
  fi
  if [[ "${MOCK_SWAP_MODE:-success}" == "kill_during_rollback_after_swap" \
      && "$(<"$(dirname "${source_path}")/state")" == "rollback-required" ]]; then
    kill -9 "${PPID}"
  fi
  exit 0
fi
if [[ "${1:-}" == "-c" && "${4:-}" == "state" ]]; then
  case "${MOCK_SWAP_MODE:-success}:${5:-}" in
    fail_after_swap_state:swapped)
      exit 1
      ;;
    kill_before_verified_state:swapped|kill_before_verified_state:installed-new)
      kill -9 "${PPID}"
      exit 137
      ;;
    kill_on_rollback_required:rollback-required|\
    kill_after_rolled_back_state:rolled-back|\
    kill_after_verified_state:swapped|kill_after_verified_state:installed-new)
      "${REAL_PYTHON}" "$@"
      kill -9 "${PPID}"
      exit 137
      ;;
  esac
fi
if [[ "${1:-}" == */check-mac-app-bundle.py ]]; then
  printf '%s\n' "$*" >>"${MOCK_STATE}/checker-calls"
  checker_call_count="$(wc -l <"${MOCK_STATE}/checker-calls" | tr -d ' ')"
  if [[ "${MOCK_CHECK_MODE:-success}" == "fail" \
      || ( "${MOCK_CHECK_MODE:-success}" == "fail_published" \
        && "${checker_call_count}" -ge 2 ) ]]; then
    printf 'SECRET_TOOL_SUBJECT\n' >&2
    exit 1
  fi
  if [[ "${MOCK_CHECK_MODE:-success}" == "kill_published" \
      && "${checker_call_count}" -ge 2 ]]; then
    checker_parent="$(/bin/ps -o ppid= -p "${PPID}" | tr -d ' ')"
    kill -9 "${checker_parent}"
    exit 137
  fi
  printf 'complete\n' >"${MOCK_STATE}/checker-complete"
  exit 0
fi
if [[ "${1:-}" == */package-mac-icon.py ]]; then
  printf 'mock icns\n' >"${3}"
  exit 0
fi
exec "${REAL_PYTHON}" "$@"
MOCK_PYTHON

chmod +x "${mock_bin}"/*
transaction_path() {
  local output="$1"
  printf '%s/.%s.publication-transaction' \
    "$(dirname "${output}")" "$(basename "${output}")"
}
seed_droidmatch_bundle() {
  local bundle="$1"
  local marker="$2"
  mkdir -p "${bundle}/Contents/MacOS" "${bundle}/Contents/Resources"
  /bin/cp "${repo_root}/mac/App/Info.plist" \
    "${bundle}/Contents/Info.plist"
  printf '%s\n' "${marker}" >"${bundle}/Contents/MacOS/DroidMatch"
  chmod +x "${bundle}/Contents/MacOS/DroidMatch"
}

assert_bundle_marker() {
  local bundle="$1"
  local marker="$2"
  [[ "$(${real_python} -c '
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text().strip())
' "${bundle}/Contents/MacOS/DroidMatch")" == "${marker}" ]]
}

assert_no_transaction() {
  local output="$1"
  local transaction
  transaction="$(transaction_path "${output}")"
  [[ ! -e "${transaction}" && ! -L "${transaction}" ]]
}

reset_state() {
  rm -f "${mock_state}"/*
}

run_build() {
  local output="$1"
  local build_mode="${2:-success}"
  local codesign_mode="${3:-success}"
  local check_mode="${4:-success}"
  local swap_mode="${5:-success}"
  local install_race_mode="${6:-none}"
  local -a app_arguments=(--output "${output}")
  if [[ "${MOCK_SANDBOXED:-0}" == 1 ]]; then
    app_arguments+=(--sandboxed)
  fi
  MOCK_STATE="${mock_state}" \
  MOCK_SWIFT_BIN="${swift_bin}" \
  MOCK_BUILD_MODE="${build_mode}" \
  MOCK_CODESIGN_MODE="${codesign_mode}" \
  MOCK_CHECK_MODE="${check_mode}" \
  MOCK_SWAP_MODE="${swap_mode}" \
  MOCK_INSTALL_RACE_MODE="${install_race_mode}" \
  MOCK_SWIFTC_DEFAULT_STATUS="${MOCK_SWIFTC_DEFAULT_STATUS:-0}" \
  MOCK_SWIFTC_ARM64E_STATUS="${MOCK_SWIFTC_ARM64E_STATUS:-0}" \
  MOCK_UNAME_MACHINE="${MOCK_UNAME_MACHINE:-arm64}" \
  CODEX_SANDBOX="${MOCK_CODEX_SANDBOX:-}" \
  DROIDMATCH_ADB="${mock_platform_tools}/adb" \
  DROIDMATCH_SWIFT_MODULE_CACHE_PATH="${module_cache}" \
  REAL_PYTHON="${real_python}" \
  PATH="${mock_bin}:${PATH}" \
    bash "${repo_root}/tools/build-mac-app.sh" "${app_arguments[@]}"
}

permission_parent="${test_root}/preserved-parent-mode"
mkdir -m 0711 "${permission_parent}"
permission_before="$(${real_python} -c '
import os, stat, sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))
' "${permission_parent}")"
run_build "${permission_parent}/DroidMatch.app" \
  >"${test_root}/preserved-parent-mode.out" 2>&1
permission_after="$(${real_python} -c '
import os, stat, sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))
' "${permission_parent}")"
[[ "${permission_after}" == "${permission_before}" ]]
assert_bundle_marker "${permission_parent}/DroidMatch.app" mock-new-executable
[[ -s "${permission_parent}/DroidMatch.app/Contents/Resources/device-marketing-name-aliases.json" ]]
assert_no_transaction "${permission_parent}/DroidMatch.app"
old_output="${test_root}/preserved/DroidMatch.app"
seed_droidmatch_bundle "${old_output}" old-bundle
for failure in build sign verify check; do
  reset_state
  set +e
  case "${failure}" in
    build)
      run_build "${old_output}" build_fail \
        >"${test_root}/${failure}.out" 2>&1
      ;;
    sign)
      run_build "${old_output}" success sign_fail \
        >"${test_root}/${failure}.out" 2>&1
      ;;
    verify)
      run_build "${old_output}" success verify_fail \
        >"${test_root}/${failure}.out" 2>&1
      ;;
    check)
      run_build "${old_output}" success success fail \
        >"${test_root}/${failure}.out" 2>&1
      ;;
  esac
  failure_status=$?
  set -e
  [[ "${failure_status}" -ne 0 ]]
  assert_bundle_marker "${old_output}" old-bundle
  assert_no_transaction "${old_output}"
  if grep -q 'SECRET_TOOL_SUBJECT' "${test_root}/${failure}.out"; then
    printf 'sensitive candidate tool output escaped the App builder\n' >&2
    exit 1
  fi
done

reset_state
set +e
run_build "${old_output}" success success fail_published \
  >"${test_root}/published-check-failure.out" 2>&1
published_check_status=$?
set -e
[[ "${published_check_status}" -ne 0 ]]
assert_bundle_marker "${old_output}" old-bundle
assert_no_transaction "${old_output}"
grep -q 'Product-boundary validation of the published App failed' \
  "${test_root}/published-check-failure.out"
grep -q 'Restored the previous DroidMatch App' \
  "${test_root}/published-check-failure.out"
if grep -q 'SECRET_TOOL_SUBJECT' "${test_root}/published-check-failure.out"; then
  printf 'sensitive published-candidate tool output escaped the App builder\n' >&2
  exit 1
fi

reset_state
sandbox_vendor_output="${test_root}/sandbox-vendor/DroidMatch.app"
mkdir -p "$(dirname "${sandbox_vendor_output}")"
MOCK_SANDBOXED=1 run_build "${sandbox_vendor_output}" \
  >"${test_root}/sandbox-vendor.out" 2>&1
assert_bundle_marker "${sandbox_vendor_output}" mock-new-executable
assert_no_transaction "${sandbox_vendor_output}"
sandbox_vendor_parent="$(cd "$(dirname "${sandbox_vendor_output}")" && pwd -P)"
[[ "$(wc -l <"${mock_state}/checker-calls" | tr -d ' ')" -eq 2 ]]
sandbox_candidate_check="$(sed -n '1p' "${mock_state}/checker-calls")"
sandbox_published_check="$(sed -n '2p' "${mock_state}/checker-calls")"
[[ "${sandbox_candidate_check}" == \
  "${repo_root}/tools/check-mac-app-bundle.py --sandboxed --defer-adb-execution ${sandbox_vendor_parent}/.DroidMatch.app.publication-transaction/candidate.app" ]]
[[ "${sandbox_published_check}" == \
  "${repo_root}/tools/check-mac-app-bundle.py --sandboxed ${sandbox_vendor_parent}/DroidMatch.app" ]]
grep -F -- '--force --sign -' "${mock_state}/codesign-calls" | grep -Fq '/platform-tools/adb'
nested_sign_line="$(grep -nF '/platform-tools/adb' "${mock_state}/codesign-calls" | grep -F -- '--force --sign -' | cut -d: -f1)"
outer_sign_line="$(grep -nF -- '--entitlements ' "${mock_state}/codesign-calls" | cut -d: -f1)"
[[ -n "${nested_sign_line}" && -n "${outer_sign_line}" && "${nested_sign_line}" -lt "${outer_sign_line}" ]]
if grep -Fq -- '--force --deep --sign' "${mock_state}/codesign-calls"; then
  printf 'outer App signing unexpectedly re-signed nested code\n' >&2
  exit 1
fi

reset_state
sandbox_unsigned_output="${test_root}/sandbox-unsigned/DroidMatch.app"
mkdir -p "$(dirname "${sandbox_unsigned_output}")"
MOCK_SANDBOXED=1 run_build \
  "${sandbox_unsigned_output}" success unsigned \
  >"${test_root}/sandbox-unsigned.out" 2>&1
assert_bundle_marker "${sandbox_unsigned_output}" mock-new-executable
assert_no_transaction "${sandbox_unsigned_output}"
grep -F -- '--force --sign -' "${mock_state}/codesign-calls" \
  | grep -Fq '/platform-tools/adb'

reset_state
sandbox_stale_output="${test_root}/sandbox-stale/DroidMatch.app"
MOCK_SANDBOXED=1 run_build "${sandbox_stale_output}" success stale_nested >"${test_root}/sandbox-stale.out" 2>&1
assert_bundle_marker "${sandbox_stale_output}" mock-new-executable
assert_no_transaction "${sandbox_stale_output}"
grep -F -- '--force --sign -' "${mock_state}/codesign-calls" | grep -Fq '/platform-tools/adb'

reset_state
set +e
MOCK_SANDBOXED=1 run_build "${test_root}/sandbox-nested-sign-failure.app" success nested_sign_fail >"${test_root}/sandbox-nested-sign-failure.out" 2>&1
sandbox_nested_sign_status=$?
set -e
[[ "${sandbox_nested_sign_status}" -ne 0 && ! -e "${test_root}/sandbox-nested-sign-failure.app" ]]
grep -q 'Signing of the embedded adb candidate failed' "${test_root}/sandbox-nested-sign-failure.out"

reset_state
sandbox_outer_sign_output="${test_root}/sandbox-outer-sign-failure/DroidMatch.app"
seed_droidmatch_bundle "${sandbox_outer_sign_output}" old-bundle
set +e
MOCK_SANDBOXED=1 run_build "${sandbox_outer_sign_output}" success outer_sign_fail >"${test_root}/sandbox-outer-sign-failure.out" 2>&1
sandbox_outer_sign_status=$?
set -e
[[ "${sandbox_outer_sign_status}" -ne 0 ]]
assert_bundle_marker "${sandbox_outer_sign_output}" old-bundle
assert_no_transaction "${sandbox_outer_sign_output}"
grep -q 'Ad-hoc signing of the App candidate failed' "${test_root}/sandbox-outer-sign-failure.out"

reset_state
failed_first_output="${test_root}/failed-first/DroidMatch.app"
mkdir -p "$(dirname "${failed_first_output}")"
set +e
run_build "${failed_first_output}" success success fail_published \
  >"${test_root}/failed-first.out" 2>&1
failed_first_status=$?
set -e
[[ "${failed_first_status}" -ne 0 ]]
[[ ! -e "${failed_first_output}" && ! -L "${failed_first_output}" ]]
assert_no_transaction "${failed_first_output}"
grep -q 'Withdrew the first DroidMatch App after validation failure' \
  "${test_root}/failed-first.out"

reset_state
set +e
run_build "${old_output}" success success success fail \
  >"${test_root}/publication-failure.out" 2>&1
publication_status=$?
set -e
[[ "${publication_status}" -ne 0 ]]
assert_bundle_marker "${old_output}" old-bundle
assert_no_transaction "${old_output}"
grep -q 'Atomic App publication swap failed or is unavailable' \
  "${test_root}/publication-failure.out"

reset_state
set +e
run_build "${old_output}" success success success fail_after_swap_state \
  >"${test_root}/post-swap-failure.out" 2>&1
post_swap_status=$?
set -e
[[ "${post_swap_status}" -ne 0 ]]
assert_bundle_marker "${old_output}" old-bundle
assert_no_transaction "${old_output}"
grep -q 'Restored the previous DroidMatch App' \
  "${test_root}/post-swap-failure.out"

reset_state
MOCK_CODEX_SANDBOX=1 run_build "${old_output}" \
  >"${test_root}/replacement.out" 2>&1
assert_bundle_marker "${old_output}" mock-new-executable
assert_no_transaction "${old_output}"
grep -q 'Built local DroidMatch app' "${test_root}/replacement.out"
grep -Fq -- "-Xswiftc -module-cache-path -Xswiftc ${module_cache}" \
  "${mock_state}/swift-calls"
grep -Fq -- '--disable-sandbox' "${mock_state}/swift-calls"
grep -q '/icon-work/DroidMatch-1024.png' "${mock_state}/swift-calls"
if grep -q '/mac/.build/app-icon' "${mock_state}/swift-calls"; then
  printf 'icon rendering escaped the private App transaction\n' >&2
  exit 1
fi

reset_state
fallback_output="${test_root}/fallback/DroidMatch.app"
mkdir -p "$(dirname "${fallback_output}")"
MOCK_SWIFTC_DEFAULT_STATUS=1 \
MOCK_SWIFTC_ARM64E_STATUS=0 \
MOCK_UNAME_MACHINE=arm64 \
  run_build "${fallback_output}" >"${test_root}/fallback.out" 2>&1
assert_bundle_marker "${fallback_output}" mock-new-executable
assert_no_transaction "${fallback_output}"
grep -q 'Swift target fallback' "${test_root}/fallback.out"
grep -Fq -- '--triple arm64e-apple-macosx13.0' \
  "${mock_state}/swift-calls"

reset_state
first_output="${test_root}/first/DroidMatch.app"
mkdir -p "$(dirname "${first_output}")"
run_build "${first_output}" >"${test_root}/first.out" 2>&1
assert_bundle_marker "${first_output}" mock-new-executable
assert_no_transaction "${first_output}"

for race_mode in empty_directory unknown_node; do
  reset_state
  race_output="${test_root}/first-race-${race_mode}/DroidMatch.app"
  mkdir -p "$(dirname "${race_output}")"
  set +e
  run_build "${race_output}" success success success success "${race_mode}" \
    >"${test_root}/first-race-${race_mode}.out" 2>&1
  race_status=$?
  set -e
  [[ "${race_status}" -ne 0 ]]
  assert_no_transaction "${race_output}"
  grep -q 'Initial App publication rename failed' \
    "${test_root}/first-race-${race_mode}.out"
  if [[ "${race_mode}" == "empty_directory" ]]; then
    [[ -d "${race_output}" && ! -L "${race_output}" ]]
    [[ -z "$(find "${race_output}" -mindepth 1 -print -quit)" ]]
  else
    [[ -f "${race_output}" && ! -L "${race_output}" ]]
    [[ "$(${real_python} -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text().strip())' \
      "${race_output}")" == "race-owned-node" ]]
  fi
done

regular_output="${test_root}/abnormal/regular.app"
mkdir -p "$(dirname "${regular_output}")"
printf 'do-not-replace\n' >"${regular_output}"
set +e
run_build "${regular_output}" >"${test_root}/regular.out" 2>&1
regular_status=$?
set -e
[[ "${regular_status}" -ne 0 ]]
[[ "$(${real_python} -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text().strip())' \
  "${regular_output}")" == "do-not-replace" ]]
assert_no_transaction "${regular_output}"

unrelated_output="${test_root}/abnormal/unrelated.app"
mkdir -p "${unrelated_output}"
printf 'unrelated\n' >"${unrelated_output}/sentinel"
set +e
run_build "${unrelated_output}" >"${test_root}/unrelated.out" 2>&1
unrelated_status=$?
set -e
[[ "${unrelated_status}" -ne 0 ]]
[[ "$(${real_python} -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text().strip())' \
  "${unrelated_output}/sentinel")" == "unrelated" ]]
assert_no_transaction "${unrelated_output}"

symlink_target="${test_root}/abnormal/symlink-target"
symlink_output="${test_root}/abnormal/symlink.app"
mkdir -p "${symlink_target}"
printf 'symlink-target\n' >"${symlink_target}/sentinel"
ln -s "${symlink_target}" "${symlink_output}"
set +e
run_build "${symlink_output}" >"${test_root}/symlink.out" 2>&1
symlink_status=$?
set -e
[[ "${symlink_status}" -ne 0 && -L "${symlink_output}" ]]
[[ "$(readlink "${symlink_output}")" == "${symlink_target}" ]]
[[ "$(${real_python} -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text().strip())' \
  "${symlink_target}/sentinel")" == "symlink-target" ]]
assert_no_transaction "${symlink_output}"

# shellcheck source=test-build-mac-app-owner-identity.sh
source "${repo_root}/tools/test-build-mac-app-owner-identity.sh"

unsafe_output="${test_root}/unsafe/DroidMatch.app"
seed_droidmatch_bundle "${unsafe_output}" unsafe-old
unsafe_transaction="$(transaction_path "${unsafe_output}")"
mkdir -m 755 "${unsafe_transaction}"
printf '99999999\n' >"${unsafe_transaction}/owner-pid"
printf 'preparing\n' >"${unsafe_transaction}/state"
set +e
run_build "${unsafe_output}" >"${test_root}/unsafe.out" 2>&1
unsafe_status=$?
set -e
[[ "${unsafe_status}" -ne 0 && -d "${unsafe_transaction}" ]]
assert_bundle_marker "${unsafe_output}" unsafe-old
grep -q 'transaction is unsafe' "${test_root}/unsafe.out"

interrupted_output="${test_root}/interrupted/DroidMatch.app"
seed_droidmatch_bundle "${interrupted_output}" interrupted-old
running_executable="${test_root}/running-executable"
/usr/bin/clang -x c -o "${running_executable}" - <<'RUNNING_EXECUTABLE'
#include <unistd.h>
int main(void) {
  sleep(300);
  return 0;
}
RUNNING_EXECUTABLE
/bin/cp "${running_executable}" "${swift_bin}/DroidMatch"
reset_state
set +e
run_build "${interrupted_output}" success success success kill_after_swap \
  >"${test_root}/interrupted.out" 2>&1
interrupted_status=$?
set -e
[[ "${interrupted_status}" -ne 0 ]]
[[ -d "$(transaction_path "${interrupted_output}")" ]]
"${interrupted_output}/Contents/MacOS/DroidMatch" &
running_recovery_pid=$!
running_recovery_detected=false
for _ in {1..50}; do
  if checker_output="$("${real_python}" \
      "${repo_root}/tools/check-mac-app-not-running.py" \
      "${interrupted_output}" 2>&1)"; then
    :
  elif [[ "${checker_output}" == *'DroidMatch is still running'* ]]; then
    running_recovery_detected=true
    break
  fi
done
[[ "${running_recovery_detected}" == true ]]
set +e
run_build "${interrupted_output}" build_fail \
  >"${test_root}/running-recovery.out" 2>&1
running_recovery_status=$?
kill "${running_recovery_pid}" 2>/dev/null
wait "${running_recovery_pid}" 2>/dev/null
set -e
[[ "${running_recovery_status}" -ne 0 ]]
/usr/bin/cmp -s "${running_executable}" \
  "${interrupted_output}/Contents/MacOS/DroidMatch"
[[ "$(<"$(transaction_path "${interrupted_output}")/state")" == "swapping" ]]
assert_bundle_marker \
  "$(transaction_path "${interrupted_output}")/candidate.app" interrupted-old
grep -q 'DroidMatch is still running' "${test_root}/running-recovery.out"
printf 'mock-new-executable\n' >"${swift_bin}/DroidMatch"

reset_state
set +e
run_build "${interrupted_output}" build_fail \
  >"${test_root}/recovery.out" 2>&1
recovery_status=$?
set -e
[[ "${recovery_status}" -ne 0 ]]
assert_bundle_marker "${interrupted_output}" interrupted-old
assert_no_transaction "${interrupted_output}"
grep -q 'Recovered the previous App before post-publication validation completed' \
  "${test_root}/recovery.out"

# First-publication rename completed but its verifying state was not written.
first_install_kill="${test_root}/kill-first-install/DroidMatch.app"
mkdir -p "$(dirname "${first_install_kill}")"
reset_state
set +e
run_build "${first_install_kill}" success success success success kill_after_install \
  >"${test_root}/kill-first-install.out" 2>&1
first_install_kill_status=$?
set -e
[[ "${first_install_kill_status}" -ne 0 ]]
assert_bundle_marker "${first_install_kill}" mock-new-executable
[[ -d "$(transaction_path "${first_install_kill}")" ]]
reset_state
set +e
run_build "${first_install_kill}" build_fail \
  >"${test_root}/recover-first-install.out" 2>&1
recover_first_install_status=$?
set -e
[[ "${recover_first_install_status}" -ne 0 ]]
[[ ! -e "${first_install_kill}" && ! -L "${first_install_kill}" ]]
assert_no_transaction "${first_install_kill}"
grep -q 'Withdrew an unverified first App publication after interruption' \
  "${test_root}/recover-first-install.out"

# Full verification had started for a first publication but never completed.
first_verifying_kill="${test_root}/kill-first-verifying/DroidMatch.app"
mkdir -p "$(dirname "${first_verifying_kill}")"
reset_state
set +e
run_build "${first_verifying_kill}" success success kill_published \
  >"${test_root}/kill-first-verifying.out" 2>&1
first_verifying_kill_status=$?
set -e
[[ "${first_verifying_kill_status}" -ne 0 ]]
assert_bundle_marker "${first_verifying_kill}" mock-new-executable
reset_state
set +e
run_build "${first_verifying_kill}" build_fail \
  >"${test_root}/recover-first-verifying.out" 2>&1
recover_first_verifying_status=$?
set -e
[[ "${recover_first_verifying_status}" -ne 0 ]]
[[ ! -e "${first_verifying_kill}" && ! -L "${first_verifying_kill}" ]]
assert_no_transaction "${first_verifying_kill}"

# A replacement whose published-path verifier was killed must restore old bytes.
replacement_verifying_kill="${test_root}/kill-replacement-verifying/DroidMatch.app"
seed_droidmatch_bundle "${replacement_verifying_kill}" replacement-verifying-old
reset_state
set +e
run_build "${replacement_verifying_kill}" success success kill_published \
  >"${test_root}/kill-replacement-verifying.out" 2>&1
replacement_verifying_kill_status=$?
set -e
[[ "${replacement_verifying_kill_status}" -ne 0 ]]
assert_bundle_marker "${replacement_verifying_kill}" mock-new-executable
reset_state
set +e
run_build "${replacement_verifying_kill}" build_fail \
  >"${test_root}/recover-replacement-verifying.out" 2>&1
recover_replacement_verifying_status=$?
set -e
[[ "${recover_replacement_verifying_status}" -ne 0 ]]
assert_bundle_marker "${replacement_verifying_kill}" replacement-verifying-old
assert_no_transaction "${replacement_verifying_kill}"

# Verification returned success but the verified state was not persisted.
for publish_kind in replacement first; do
  state_kill_output="${test_root}/kill-before-state-${publish_kind}/DroidMatch.app"
  if [[ "${publish_kind}" == replacement ]]; then
    seed_droidmatch_bundle "${state_kill_output}" before-state-old
  else
    mkdir -p "$(dirname "${state_kill_output}")"
  fi
  reset_state
  set +e
  run_build "${state_kill_output}" success success success kill_before_verified_state \
    >"${test_root}/kill-before-state-${publish_kind}.out" 2>&1
  state_kill_status=$?
  set -e
  [[ "${state_kill_status}" -ne 0 ]]
  reset_state
  set +e
  run_build "${state_kill_output}" build_fail \
    >"${test_root}/recover-before-state-${publish_kind}.out" 2>&1
  recover_state_kill_status=$?
  set -e
  [[ "${recover_state_kill_status}" -ne 0 ]]
  if [[ "${publish_kind}" == replacement ]]; then
    assert_bundle_marker "${state_kill_output}" before-state-old
  else
    [[ ! -e "${state_kill_output}" && ! -L "${state_kill_output}" ]]
  fi
  assert_no_transaction "${state_kill_output}"
done

# Once the verified state is durable, recovery keeps the fully checked App.
for publish_kind in replacement first; do
  verified_kill_output="${test_root}/kill-after-state-${publish_kind}/DroidMatch.app"
  if [[ "${publish_kind}" == replacement ]]; then
    seed_droidmatch_bundle "${verified_kill_output}" after-state-old
  else
    mkdir -p "$(dirname "${verified_kill_output}")"
  fi
  reset_state
  set +e
  run_build "${verified_kill_output}" success success success kill_after_verified_state \
    >"${test_root}/kill-after-state-${publish_kind}.out" 2>&1
  verified_kill_status=$?
  set -e
  [[ "${verified_kill_status}" -ne 0 ]]
  reset_state
  set +e
  run_build "${verified_kill_output}" build_fail \
    >"${test_root}/recover-after-state-${publish_kind}.out" 2>&1
  recover_verified_kill_status=$?
  set -e
  [[ "${recover_verified_kill_status}" -ne 0 ]]
  assert_bundle_marker "${verified_kill_output}" mock-new-executable
  assert_no_transaction "${verified_kill_output}"
done

# Every durable rollback boundary recovers the original App, never the candidate.
for rollback_kill_mode in \
    kill_on_rollback_required \
    kill_during_rollback_after_swap \
    kill_after_rolled_back_state; do
  rollback_kill_output="${test_root}/${rollback_kill_mode}/DroidMatch.app"
  seed_droidmatch_bundle "${rollback_kill_output}" rollback-old
  reset_state
  set +e
  run_build "${rollback_kill_output}" \
    success success fail_published "${rollback_kill_mode}" \
    >"${test_root}/${rollback_kill_mode}.out" 2>&1
  rollback_kill_status=$?
  set -e
  [[ "${rollback_kill_status}" -ne 0 ]]
  reset_state
  set +e
  run_build "${rollback_kill_output}" build_fail \
    >"${test_root}/recover-${rollback_kill_mode}.out" 2>&1
  recover_rollback_kill_status=$?
  set -e
  [[ "${recover_rollback_kill_status}" -ne 0 ]]
  assert_bundle_marker "${rollback_kill_output}" rollback-old
  assert_no_transaction "${rollback_kill_output}"
done

printf 'Mac App transactional publication tests passed.\n'
printf '中文：Mac App 事务发布测试通过。\n'
