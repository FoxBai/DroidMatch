#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-swift-runner-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

mock_bin="${test_root}/bin"
call_log="${test_root}/swift-calls"
swiftc_log="${test_root}/swiftc-calls"
module_cache="${test_root}/module-cache"
default_test_list=$'DroidMatchCoreTests.alpha()\nDroidMatchCoreTests.beta(value:)\nDroidMatchPresentationTests.gamma()'
mkdir -p "${mock_bin}" "${module_cache}"

cat >"${mock_bin}/swiftc" <<'MOCK_SWIFTC'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_SWIFTC_CALL_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"${MOCK_SWIFTC_CALL_LOG}"
fi
if [[ "${MOCK_SWIFTC_EXPLICIT_MODE:-0}" == 1 ]]; then
  if [[ "$*" == *'TestingProbe.swift'* && "$*" != *'-F '* ]]; then
    exit 1
  fi
  if [[ "$*" == *'TestingProbe.swift'* && "$*" == *'-F '* ]]; then
    exit "${MOCK_SWIFTC_EXPLICIT_STATUS:-0}"
  fi
fi
exit 0
MOCK_SWIFTC

cat >"${mock_bin}/swift" <<'MOCK_SWIFT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_SWIFT_CALL_LOG}"
if [[ "${MOCK_REQUIRE_WIDTH_UNSET:-0}" == 1 \
    && -n "${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH+x}" ]]; then
  exit 88
fi
if [[ "${1:-}" == "build" ]]; then
  exit "${MOCK_SWIFT_BUILD_STATUS:-0}"
fi
if [[ "${!#}" == "list" ]]; then
  if [[ -n "${MOCK_SWIFT_TEST_LIST:-}" ]]; then
    printf '%s\n' "${MOCK_SWIFT_TEST_LIST}"
  fi
  exit "${MOCK_SWIFT_LIST_STATUS:-0}"
fi
filter=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "--filter" && "$#" -ge 2 ]]; then
    filter="$2"
    shift 2
    continue
  fi
  shift
done
if [[ -n "${filter}" ]]; then
  count=1
  remaining="${filter}"
  while [[ "${remaining}" == *'|'* ]]; do
    remaining="${remaining#*|}"
    count=$((count + 1))
  done
  count=$((count + ${MOCK_SWIFT_TEST_RUN_COUNT_OFFSET:-0}))
  printf 'Test run with %s tests in 0 suites passed.\n' "${count}"
  exit "${MOCK_SWIFT_TEST_RUN_STATUS:-0}"
fi
MOCK_SWIFT

cat >"${mock_bin}/xcode-select" <<'MOCK_XCODE_SELECT'
#!/usr/bin/env bash
if [[ -n "${MOCK_XCODE_SELECT_PATH:-}" ]]; then
  printf '%s\n' "${MOCK_XCODE_SELECT_PATH}"
  exit 0
fi
exit 1
MOCK_XCODE_SELECT

cat >"${mock_bin}/find" <<'MOCK_FIND'
#!/usr/bin/env bash
if [[ "${MOCK_FIND_EXPLICIT_PATHS:-0}" == 1 ]]; then
  case "$*" in
    *'Testing.framework'*) printf '%s\n' "${MOCK_XCODE_SELECT_PATH}/Testing.framework" ;;
    *'libTestingMacros.dylib'*) printf '%s\n' "${MOCK_XCODE_SELECT_PATH}/libTestingMacros.dylib" ;;
    *'lib_TestingInterop.dylib'*) printf '%s\n' "${MOCK_XCODE_SELECT_PATH}/lib_TestingInterop.dylib" ;;
  esac
fi
exit 0
MOCK_FIND

chmod +x "${mock_bin}"/*

run_runner() {
  local swift_test_list
  swift_test_list="${MOCK_SWIFT_TEST_LIST-${default_test_list}}"
  PATH="${mock_bin}:${PATH}" \
  MOCK_SWIFT_CALL_LOG="${call_log}" \
  MOCK_SWIFTC_CALL_LOG="${swiftc_log}" \
  MOCK_SWIFTC_EXPLICIT_MODE="${MOCK_SWIFTC_EXPLICIT_MODE:-0}" \
  MOCK_SWIFTC_EXPLICIT_STATUS="${MOCK_SWIFTC_EXPLICIT_STATUS:-0}" \
  MOCK_XCODE_SELECT_PATH="${MOCK_XCODE_SELECT_PATH:-}" \
  MOCK_FIND_EXPLICIT_PATHS="${MOCK_FIND_EXPLICIT_PATHS:-0}" \
  MOCK_SWIFT_TEST_LIST="${swift_test_list}" \
  MOCK_SWIFT_LIST_STATUS="${MOCK_SWIFT_LIST_STATUS:-0}" \
  MOCK_SWIFT_BUILD_STATUS="${MOCK_SWIFT_BUILD_STATUS:-0}" \
  MOCK_SWIFT_TEST_RUN_COUNT_OFFSET="${MOCK_SWIFT_TEST_RUN_COUNT_OFFSET:-0}" \
  MOCK_SWIFT_TEST_RUN_STATUS="${MOCK_SWIFT_TEST_RUN_STATUS:-0}" \
  MOCK_REQUIRE_WIDTH_UNSET="${MOCK_REQUIRE_WIDTH_UNSET:-0}" \
  DROIDMATCH_SWIFT_MODULE_CACHE_PATH="${module_cache}" \
  DROIDMATCH_SWIFT_TEST_SHARD_SIZE="${MOCK_SWIFT_TEST_SHARD_SIZE:-2}" \
  CODEX_SANDBOX="${MOCK_CODEX_SANDBOX:-}" \
    bash "${repo_root}/tools/run-swift-tests.sh" "$@"
}

run_runner_with_default_module_cache() {
  local scratch_path="${MOCK_DEFAULT_SCRATCH_PATH:-${test_root}/default-scratch}"
  local swift_test_list
  swift_test_list="${MOCK_SWIFT_TEST_LIST-${default_test_list}}"
  env -u DROIDMATCH_SWIFT_MODULE_CACHE_PATH \
    PATH="${mock_bin}:${PATH}" \
    MOCK_SWIFT_CALL_LOG="${call_log}" \
    MOCK_SWIFTC_CALL_LOG="${swiftc_log}" \
    MOCK_SWIFT_TEST_LIST="${swift_test_list}" \
    MOCK_SWIFT_LIST_STATUS="${MOCK_SWIFT_LIST_STATUS:-0}" \
    MOCK_SWIFT_BUILD_STATUS="${MOCK_SWIFT_BUILD_STATUS:-0}" \
    MOCK_SWIFT_TEST_RUN_COUNT_OFFSET="${MOCK_SWIFT_TEST_RUN_COUNT_OFFSET:-0}" \
    MOCK_SWIFT_TEST_RUN_STATUS="${MOCK_SWIFT_TEST_RUN_STATUS:-0}" \
    MOCK_REQUIRE_WIDTH_UNSET="${MOCK_REQUIRE_WIDTH_UNSET:-0}" \
    DROIDMATCH_SWIFT_SCRATCH_PATH="${scratch_path}" \
    DROIDMATCH_SWIFT_TEST_SHARD_SIZE="${MOCK_SWIFT_TEST_SHARD_SIZE:-2}" \
    CODEX_SANDBOX="" \
    bash "${repo_root}/tools/run-swift-tests.sh" "$@"
}

: >"${call_log}"
run_runner >/dev/null
[[ "$(sed -n '1p' "${call_log}")" == \
  "build --package-path mac -Xswiftc -module-cache-path -Xswiftc ${module_cache} --build-tests" ]]
[[ "$(sed -n '2p' "${call_log}")" == \
  "test --package-path mac -Xswiftc -module-cache-path -Xswiftc ${module_cache} --skip-build list" ]]
[[ "$(wc -l <"${call_log}" | tr -d ' ')" -eq 4 ]]
grep -Fq -- \
  '--filter (?:DroidMatchCoreTests\.alpha\(\)|DroidMatchCoreTests\.beta\(value:\))' \
  "${call_log}"
grep -Fq -- \
  '--filter (?:DroidMatchPresentationTests\.gamma\(\))' \
  "${call_log}"

: >"${call_log}"
run_runner_with_default_module_cache >/dev/null
default_scratch="${test_root}/default-scratch"
[[ -d "${default_scratch}/droidmatch-module-cache" ]]
[[ "$(sed -n '1p' "${call_log}")" == \
  "build --package-path mac -Xswiftc -module-cache-path -Xswiftc ${default_scratch}/droidmatch-module-cache --scratch-path ${default_scratch} --build-tests" ]]
[[ "$(sed -n '2p' "${call_log}")" == \
  "test --package-path mac -Xswiftc -module-cache-path -Xswiftc ${default_scratch}/droidmatch-module-cache --scratch-path ${default_scratch} --skip-build list" ]]
[[ "$(wc -l <"${call_log}" | tr -d ' ')" -eq 4 ]]

: >"${call_log}"
MOCK_DEFAULT_SCRATCH_PATH="mac/.build" run_runner_with_default_module_cache >/dev/null
[[ "$(sed -n '1p' "${call_log}")" == \
  "build --package-path mac -Xswiftc -module-cache-path -Xswiftc ${repo_root}/mac/.build/droidmatch-module-cache --scratch-path mac/.build --build-tests" ]]
[[ "$(sed -n '2p' "${call_log}")" == \
  "test --package-path mac -Xswiftc -module-cache-path -Xswiftc ${repo_root}/mac/.build/droidmatch-module-cache --scratch-path mac/.build --skip-build list" ]]
[[ "$(wc -l <"${call_log}" | tr -d ' ')" -eq 4 ]]

: >"${call_log}"
DROIDMATCH_SWIFT_SCRATCH_PATH="mac/.swift-filter-test" \
  run_runner --filter 'lockedValueUnlocksAfterThrowingUpdate' >/dev/null
[[ "$(sed -n '2p' "${call_log}")" == \
  "test --package-path mac -Xswiftc -module-cache-path -Xswiftc ${module_cache} --scratch-path mac/.swift-filter-test --filter lockedValueUnlocksAfterThrowingUpdate --skip-build" ]]
[[ "$(wc -l <"${call_log}" | tr -d ' ')" -eq 2 ]]

: >"${call_log}"
MOCK_CODEX_SANDBOX=1 run_runner >/dev/null
[[ "$(grep -Fc -- '--disable-sandbox' "${call_log}")" -eq 4 ]]

: >"${call_log}"
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 \
  MOCK_REQUIRE_WIDTH_UNSET=1 \
  run_runner >/dev/null
[[ "$(wc -l <"${call_log}" | tr -d ' ')" -eq 4 ]]

: >"${call_log}"
MOCK_SWIFT_TEST_SHARD_SIZE=1 run_runner >/dev/null
[[ "$(wc -l <"${call_log}" | tr -d ' ')" -eq 5 ]]

: >"${call_log}"
set +e
build_failure_output="$(MOCK_SWIFT_BUILD_STATUS=7 run_runner --filter 'oneTest' 2>&1)"
build_failure_status=$?
set -e
[[ "${build_failure_status}" -eq 7 ]]
[[ "$(wc -l <"${call_log}" | tr -d ' ')" -eq 1 ]]
grep -q 'Building the complete Swift test bundle once' <<<"${build_failure_output}"

: >"${call_log}"
probe_output="$(run_runner --probe-only)"
grep -q 'Swift prerequisite ok' <<<"${probe_output}"
[[ ! -s "${call_log}" ]]

explicit_root="${test_root}/ExplicitDeveloper"
mkdir -p "${explicit_root}/Testing.framework"
touch \
  "${explicit_root}/libTestingMacros.dylib" \
  "${explicit_root}/lib_TestingInterop.dylib"
: >"${swiftc_log}"
set +e
explicit_failure_output="$(
  MOCK_SWIFTC_EXPLICIT_MODE=1 \
  MOCK_SWIFTC_EXPLICIT_STATUS=42 \
  MOCK_XCODE_SELECT_PATH="${explicit_root}" \
  MOCK_FIND_EXPLICIT_PATHS=1 \
    run_runner --probe-only 2>&1
)"
explicit_failure_status=$?
set -e
[[ "${explicit_failure_status}" -eq 1 ]]
grep -q 'Swift Testing not found' <<<"${explicit_failure_output}"
grep -Fq -- '-F '"${explicit_root}" "${swiftc_log}"
grep -Fq -- '-load-plugin-library '"${explicit_root}/libTestingMacros.dylib" \
  "${swiftc_log}"

: >"${swiftc_log}"
explicit_success_output="$(
  MOCK_SWIFTC_EXPLICIT_MODE=1 \
  MOCK_SWIFTC_EXPLICIT_STATUS=0 \
  MOCK_XCODE_SELECT_PATH="${explicit_root}" \
  MOCK_FIND_EXPLICIT_PATHS=1 \
    run_runner --probe-only
)"
grep -q 'Swift prerequisite ok: using explicit Swift Testing paths' \
  <<<"${explicit_success_output}"

platform_root="${test_root}/MultiPlatformDeveloper"
mkdir -p \
  "${platform_root}/Platforms/AppleTVOS.platform/Developer/Library/Frameworks/Testing.framework" \
  "${platform_root}/Platforms/MacOSX.platform/Developer/Library/Frameworks/Testing.framework" \
  "${platform_root}/Platforms/AppleTVOS.platform/Developer/usr/lib" \
  "${platform_root}/Platforms/MacOSX.platform/Developer/usr/lib" \
  "${platform_root}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"
touch \
  "${platform_root}/Platforms/AppleTVOS.platform/Developer/usr/lib/lib_TestingInterop.dylib" \
  "${platform_root}/Platforms/MacOSX.platform/Developer/usr/lib/lib_TestingInterop.dylib" \
  "${platform_root}/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
: >"${swiftc_log}"
platform_output="$(
  MOCK_SWIFTC_EXPLICIT_MODE=1 \
  MOCK_SWIFTC_EXPLICIT_STATUS=0 \
  MOCK_XCODE_SELECT_PATH="${platform_root}" \
    run_runner --probe-only
)"
grep -q 'Swift prerequisite ok: using explicit Swift Testing paths' \
  <<<"${platform_output}"
grep -Fq -- '-F '"${platform_root}/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
  "${swiftc_log}"
if grep -Fq 'AppleTVOS.platform' "${swiftc_log}"; then
  printf 'Swift Testing selection mixed the macOS target with Apple TV support.\n' >&2
  exit 1
fi

assert_usage_failure() {
  local expected_message="$1"
  shift
  : >"${call_log}"
  set +e
  usage_output="$(run_runner "$@" 2>&1)"
  usage_status=$?
  set -e
  [[ "${usage_status}" -eq 2 ]]
  [[ ! -s "${call_log}" ]]
  grep -q -- "${expected_message}" <<<"${usage_output}"
}

assert_usage_failure 'Expected a non-empty regular expression' --filter
assert_usage_failure 'Expected a non-empty regular expression' --filter --probe-only
assert_usage_failure 'cannot be combined' --filter 'oneTest' --probe-only
assert_usage_failure 'Duplicate argument: --filter' --filter 'oneTest' --filter 'otherTest'
assert_usage_failure 'Unexpected argument: --unknown' --unknown

: >"${call_log}"
set +e
empty_output="$(MOCK_SWIFT_TEST_LIST='' run_runner 2>&1)"
empty_status=$?
set -e
[[ "${empty_status}" -eq 1 ]]
grep -q 'empty inventory' <<<"${empty_output}"

: >"${call_log}"
duplicate_list=$'DroidMatchCoreTests.alpha()\nDroidMatchCoreTests.alpha()'
set +e
duplicate_output="$(MOCK_SWIFT_TEST_LIST="${duplicate_list}" run_runner 2>&1)"
duplicate_status=$?
set -e
[[ "${duplicate_status}" -eq 1 ]]
grep -q 'duplicate specifier' <<<"${duplicate_output}"

: >"${call_log}"
set +e
mismatch_output="$(MOCK_SWIFT_TEST_RUN_COUNT_OFFSET=1 run_runner 2>&1)"
mismatch_status=$?
set -e
[[ "${mismatch_status}" -eq 1 ]]
grep -q 'ran 3 tests; expected 2' <<<"${mismatch_output}"

: >"${call_log}"
set +e
list_failure_output="$(MOCK_SWIFT_LIST_STATUS=9 run_runner 2>&1)"
list_failure_status=$?
set -e
[[ "${list_failure_status}" -eq 1 ]]
grep -q 'Could not discover' <<<"${list_failure_output}"

: >"${call_log}"
set +e
invalid_shard_output="$(MOCK_SWIFT_TEST_SHARD_SIZE=0 run_runner 2>&1)"
invalid_shard_status=$?
set -e
[[ "${invalid_shard_status}" -eq 1 ]]
grep -q 'must be an integer from 1 through 20' <<<"${invalid_shard_output}"

: >"${call_log}"
set +e
oversized_shard_output="$(MOCK_SWIFT_TEST_SHARD_SIZE=21 run_runner 2>&1)"
oversized_shard_status=$?
set -e
[[ "${oversized_shard_status}" -eq 1 ]]
grep -q 'must be an integer from 1 through 20' <<<"${oversized_shard_output}"

printf 'Swift test runner argument tests passed.\n'
printf '中文：Swift 测试 runner 参数测试通过。\n'
