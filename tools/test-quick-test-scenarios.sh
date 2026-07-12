#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_runner="${repo_root}/tools/quick-test-scenarios.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-quick-scenarios.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

mkdir -p "${test_root}/tools" "${test_root}/fixtures"
runner="${test_root}/tools/quick-test-scenarios.sh"
smoke_runner="${test_root}/tools/run-m1-device-smoke.sh"
call_log="${test_root}/calls.log"
call_count="${test_root}/call-count"
upload_100mb="${test_root}/fixtures/droidmatch-100mb-upload.bin"
upload_10mb="${test_root}/fixtures/droidmatch-10mb-upload.bin"
fake_adb="${test_root}/adb"

# Keep the wrapper code under test intact apart from redirecting its fixed-size
# fixture paths into this temporary directory.
sed \
  -e "s|/tmp/droidmatch-100mb-upload.bin|${upload_100mb}|g" \
  -e "s|/tmp/droidmatch-10mb-upload.bin|${upload_10mb}|g" \
  "${source_runner}" > "${runner}"
chmod +x "${runner}"

cat > "${smoke_runner}" <<'SMOKE'
#!/usr/bin/env bash
set -euo pipefail

count=0
if [[ -f "${FAKE_CALL_COUNT}" ]]; then
  count="$(<"${FAKE_CALL_COUNT}")"
fi
count=$((count + 1))
printf '%s\n' "${count}" > "${FAKE_CALL_COUNT}"

{
  printf 'ADB=%s' "${DROIDMATCH_ADB:-}"
  printf '\t%s' "$@"
  printf '\n'
} >> "${FAKE_CALL_LOG}"

if [[ "${FAKE_FAIL_AT:-}" == "${count}" ]]; then
  exit "${FAKE_FAIL_STATUS:-1}"
fi
SMOKE
chmod +x "${smoke_runner}"

cat > "${fake_adb}" <<'ADB'
#!/usr/bin/env bash
exit 0
ADB
chmod +x "${fake_adb}"

reset_calls() {
  : > "${call_log}"
  rm -f "${call_count}"
}

run_wrapper() {
  FAKE_CALL_LOG="${call_log}" \
  FAKE_CALL_COUNT="${call_count}" \
    "${runner}" "$@"
}

reset_calls
matrix_output="$(
  DROIDMATCH_RUN_NOTES='offline matrix' run_wrapper full-matrix \
    --serial test-device \
    --adb "${fake_adb}" \
    --device-slot C \
    --max-list-ms 123 \
    --max-retry-attempts 3 \
    --retry-backoff-ms 100
)"

[[ "$(wc -l < "${call_log}" | tr -d ' ')" == 9 ]]
first_call="$(sed -n '1p' "${call_log}")"
[[ "${first_call}" != *$'\t--skip-build'* ]]
awk -F '\t' '
  NR == 1 { for (field = 1; field <= NF; field++) if ($field == "--skip-build") exit 1 }
  NR > 1 {
    count = 0
    for (field = 1; field <= NF; field++) if ($field == "--skip-build") count++
    if (count != 1) exit 1
  }
' "${call_log}"
[[ "$(grep -c -- $'\t--serial\ttest-device' "${call_log}")" == 9 ]]
[[ "$(grep -c -- $'\t--device-slot\tC' "${call_log}")" == 9 ]]
[[ "$(grep -c -- $'\t--notes\toffline matrix' "${call_log}")" == 9 ]]
[[ "$(grep -c -- $'\t--max-list-ms\t123' "${call_log}")" == 9 ]]
[[ "$(grep -c -- $'\t--max-retry-attempts\t3' "${call_log}")" == 3 ]]
[[ "$(grep -c -- $'\t--retry-backoff-ms\t100' "${call_log}")" == 3 ]]
[[ "$(grep -c -- "ADB=${fake_adb}" "${call_log}")" == 9 ]]
! grep -q -- $'\t--no-result-log' "${call_log}"
[[ "${matrix_output}" == *'Running Automated Core ADB Matrix'* ]]
[[ "${matrix_output}" == *'Complementary attended product discovery/SAS approval/SAF authorization'* ]]
[[ "${matrix_output}" == *'and physical-unplug runs are not included.'* ]]
[[ "${matrix_output}" == *'Automated Core ADB Matrix Completed'* ]]
if grep -Eq 'complete M1 validation|all M1 exit criteria|Full M1|All tests passed' <<<"${matrix_output}"; then
  printf 'full-matrix output overclaims M1 evidence completeness\n' >&2
  exit 1
fi

help_output="$(run_wrapper help)"
[[ "${help_output}" == *'Quick Core ADB Test Scenarios'* ]]
[[ "${help_output}" == *'Runs the automated core ADB matrix on one device.'* ]]
[[ "${help_output}" == *'Excludes complementary attended product discovery/SAS approval/SAF'* ]]
[[ "${help_output}" == *'authorization and physical-unplug runs.'* ]]
if grep -Eq 'complete M1 validation|all M1 exit criteria|Full M1|All tests passed' <<<"${help_output}"; then
  printf 'quick scenario help overclaims M1 evidence completeness\n' >&2
  exit 1
fi

# Standalone scenarios retain their existing build behavior, including the
# two-call expected-error scenario.
reset_calls
run_wrapper basic-smoke --serial test-device --device-slot C >/dev/null
[[ "$(wc -l < "${call_log}" | tr -d ' ')" == 1 ]]
! grep -q -- $'\t--skip-build' "${call_log}"

reset_calls
run_wrapper expected-errors --serial test-device --device-slot C >/dev/null
[[ "$(wc -l < "${call_log}" | tr -d ' ')" == 2 ]]
! grep -q -- $'\t--skip-build' "${call_log}"
[[ "$(grep -c -- $'\t--no-result-log' "${call_log}")" == 2 ]]

# A failed smoke invocation remains the wrapper's exit status and stops the
# matrix immediately; the successful first run still enables build reuse.
reset_calls
set +e
failure_output="$(
  FAKE_FAIL_AT=2 \
  FAKE_FAIL_STATUS=37 \
  FAKE_CALL_LOG="${call_log}" \
  FAKE_CALL_COUNT="${call_count}" \
    "${runner}" full-matrix --serial test-device --device-slot C 2>&1
)"
failure_status=$?
set -e
[[ "${failure_status}" == 37 ]]
[[ "$(wc -l < "${call_log}" | tr -d ' ')" == 2 ]]
[[ "$(sed -n '2p' "${call_log}")" == *$'\t--skip-build'* ]]
[[ "${failure_output}" != *'Automated Core ADB Matrix Completed'* ]]

# A failure in the first smoke call returns before either build reuse or any
# later scenario can begin.
reset_calls
set +e
first_failure_output="$(
  FAKE_FAIL_AT=1 \
  FAKE_FAIL_STATUS=41 \
  FAKE_CALL_LOG="${call_log}" \
  FAKE_CALL_COUNT="${call_count}" \
    "${runner}" full-matrix --serial test-device --device-slot C 2>&1
)"
first_failure_status=$?
set -e
[[ "${first_failure_status}" == 41 ]]
[[ "$(wc -l < "${call_log}" | tr -d ' ')" == 1 ]]
! grep -q -- $'\t--skip-build' "${call_log}"
[[ "${first_failure_output}" != *'Automated Core ADB Matrix Completed'* ]]
[[ "${first_failure_output}" != *'Running scenario: 2. Download Throughput'* ]]

printf 'Quick test scenario wrapper tests passed.\n'
printf '中文：快速测试场景 wrapper 离线测试通过。\n'
