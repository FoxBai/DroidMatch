#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-swift-runner-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

mock_bin="${test_root}/bin"
call_log="${test_root}/swift-calls"
mkdir -p "${mock_bin}"

cat >"${mock_bin}/swiftc" <<'MOCK_SWIFTC'
#!/usr/bin/env bash
exit 0
MOCK_SWIFTC

cat >"${mock_bin}/swift" <<'MOCK_SWIFT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_SWIFT_CALL_LOG}"
MOCK_SWIFT

cat >"${mock_bin}/xcode-select" <<'MOCK_XCODE_SELECT'
#!/usr/bin/env bash
exit 1
MOCK_XCODE_SELECT

cat >"${mock_bin}/find" <<'MOCK_FIND'
#!/usr/bin/env bash
exit 0
MOCK_FIND

chmod +x "${mock_bin}"/*

run_runner() {
  PATH="${mock_bin}:${PATH}" \
  MOCK_SWIFT_CALL_LOG="${call_log}" \
    bash "${repo_root}/tools/run-swift-tests.sh" "$@"
}

: >"${call_log}"
run_runner
[[ "$(<"${call_log}")" == "test --package-path mac" ]]

: >"${call_log}"
DROIDMATCH_SWIFT_SCRATCH_PATH="mac/.swift-filter-test" \
  run_runner --filter 'lockedValueUnlocksAfterThrowingUpdate'
[[ "$(<"${call_log}")" == \
  "test --package-path mac --scratch-path mac/.swift-filter-test --filter lockedValueUnlocksAfterThrowingUpdate" ]]

: >"${call_log}"
probe_output="$(run_runner --probe-only)"
grep -q 'Swift prerequisite ok' <<<"${probe_output}"
[[ ! -s "${call_log}" ]]

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

printf 'Swift test runner argument tests passed.\n'
printf '中文：Swift 测试 runner 参数测试通过。\n'
