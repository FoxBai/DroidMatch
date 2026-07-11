#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mock_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-large-directory-test.XXXXXX")"
trap 'rm -rf "${mock_root}"' EXIT

mock_adb="${mock_root}/adb"
mock_harness="${mock_root}/harness"
call_log="${mock_root}/calls"

cat >"${mock_adb}" <<'MOCK_ADB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${MOCK_CALL_LOG}"
if [[ " $* " == *" get-state "* ]]; then
  printf '%s\n' device
elif [[ " $* " == *" shell pm path app.droidmatch "* ]]; then
  printf '%s\n' package:/test/base.apk
elif [[ " $* " == *" wc -l"* ]]; then
  printf '%s\n' 1005
elif [[ " $* " == *" shell dumpsys meminfo app.droidmatch "* ]]; then
  printf '%s\n' '           TOTAL PSS:      120            TOTAL RSS:      240'
elif [[ " $* " == *" forward tcp:0 tcp:39001 "* ]]; then
  printf '%s\n' 49152
elif [[ " $* " == *" forward --list "* ]]; then
  exit 0
elif [[ " $* " == *" run-as app.droidmatch test -e "* ]]; then
  exit 1
fi
MOCK_ADB

cat >"${mock_harness}" <<'MOCK_HARNESS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'PRIVATE-ENTRY-NAME-MUST-NOT-LEAK'
if [[ "${MOCK_HARNESS_FAILURE:-0}" == 1 ]]; then
  exit 9
fi
sleep 0.2
printf '%s\n' 'list-dir-all passed pages=2 page_counts=1000,5 entries=1005 elapsed_ms=42'
MOCK_HARNESS
chmod +x "${mock_adb}" "${mock_harness}"

run_probe() {
  MOCK_CALL_LOG="${call_log}" \
  DROIDMATCH_HARNESS="${mock_harness}" \
    "${repo_root}/tools/run-large-directory-device-smoke.sh" \
      --serial TEST-SERIAL --adb "${mock_adb}" --measure-memory
}

pass_output="$(run_probe 2>&1)"
grep -q 'list-dir-all passed pages=2 page_counts=1000,5 entries=1005 elapsed_ms=42' \
  <<<"${pass_output}"
grep -q 'memory_pss_kib baseline=120 peak=120 delta=0 sampling=diagnostic' \
  <<<"${pass_output}"
grep -q 'large-directory device probe passed entries=1005 cleanup=verified' \
  <<<"${pass_output}"
if grep -q 'PRIVATE-ENTRY-NAME-MUST-NOT-LEAK\|TEST-SERIAL' <<<"${pass_output}"; then
  printf '%s\n' 'large-directory success output crossed the privacy boundary' >&2
  exit 1
fi
grep -q 'forward --remove tcp:49152' "${call_log}"
grep -q 'run-as app.droidmatch rm -rf' "${call_log}"

: >"${call_log}"
set +e
failure_output="$(MOCK_HARNESS_FAILURE=1 run_probe 2>&1)"
failure_status=$?
set -e
if [[ "${failure_status}" -ne 9 ]]; then
  printf 'expected harness failure status 9, got %s\n' "${failure_status}" >&2
  exit 1
fi
grep -q 'captured output withheld by the privacy boundary' <<<"${failure_output}"
if grep -q 'PRIVATE-ENTRY-NAME-MUST-NOT-LEAK\|TEST-SERIAL' <<<"${failure_output}"; then
  printf '%s\n' 'large-directory failure output crossed the privacy boundary' >&2
  exit 1
fi
grep -q 'forward --remove tcp:49152' "${call_log}"
grep -q 'run-as app.droidmatch rm -rf' "${call_log}"

printf '%s\n' 'large-directory device smoke offline tests passed.'
