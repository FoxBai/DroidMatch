#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_wrapper="${repo_root}/tools/run-m1-throughput-gate.sh"
source_checker="${repo_root}/tools/check-m1-run-logs.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-throughput-profile-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

remote_repo="${test_root}/origin.git"
test_repo="${test_root}/repo"
private_tmp="${test_root}/tmp"
fake_adb="${test_root}/fake-adb"
fake_bin="${test_root}/bin"
runner_args="${test_root}/runner-args"
adb_calls="${test_root}/adb-calls"
cleanup_marker="${test_root}/cleanup-called"
git_status_calls="${test_root}/git-status-calls"
raw_serial="RAW-SERIAL-DO-NOT-LEAK"
real_git="$(command -v git)"
real_grep="$(command -v grep)"
real_ln="$(command -v ln)"

git init --bare -q "${remote_repo}"
git init -q "${test_repo}"
git -C "${test_repo}" config user.name 'DroidMatch Offline Test'
git -C "${test_repo}" config user.email 'offline-test@droidmatch.invalid'
mkdir -p \
  "${test_repo}/tools" \
  "${test_repo}/fixtures/m1-runs" \
  "${private_tmp}" \
  "${fake_bin}"
cp "${source_wrapper}" "${test_repo}/tools/run-m1-throughput-gate.sh"
cp "${source_checker}" "${test_repo}/tools/check-m1-run-logs.sh"
chmod +x "${test_repo}/tools/"*.sh

cat >"${fake_bin}/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "status" && -n "${FAKE_GIT_STATUS_FAIL_ON:-}" ]]; then
  calls=0
  [[ ! -f "${FAKE_GIT_STATUS_CALLS}" ]] \
    || calls="$(cat "${FAKE_GIT_STATUS_CALLS}")"
  calls=$((calls + 1))
  printf '%s\n' "${calls}" >"${FAKE_GIT_STATUS_CALLS}"
  if [[ "${calls}" == "${FAKE_GIT_STATUS_FAIL_ON}" ]]; then
    exit 71
  fi
fi
exec "${REAL_GIT:?}" "$@"
FAKE_GIT

cat >"${fake_bin}/ln" <<'FAKE_LN'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${FAKE_LN_RACE:-0}" == "1" || "${FAKE_LN_SYMLINK_RACE:-0}" == "1" ]]; then
  [[ $# -eq 3 && "$1" == "-n" ]]
  target="$3"
  if [[ "${FAKE_LN_SYMLINK_RACE:-0}" == "1" ]]; then
    mkdir "${target}.directory"
    "${REAL_LN:?}" -s "${PWD}/${target}.directory" "${target}"
  else
    printf '%s\n' 'concurrent-writer-sentinel' >"${target}"
  fi
fi
exec "${REAL_LN:?}" "$@"
FAKE_LN

cat >"${fake_bin}/grep" <<'FAKE_GREP'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${FAKE_GREP_CONTROL_FAILURE:-0}" == "1" \
    && "$*" == *'[[:cntrl:]]'* ]]; then
  exit 72
fi
if [[ "${FAKE_GREP_COUNT_FAILURE:-0}" == "1" \
    && "$*" == *'^evidence profile:'* ]]; then
  exit 73
fi
if [[ "${FAKE_GREP_SERIAL_FAILURE:-0}" == "1" \
    && "$*" == *'RAW-SERIAL-DO-NOT-LEAK'* ]]; then
  exit 74
fi
if [[ "${FAKE_GREP_SENSITIVE_FAILURE:-0}" == "1" \
    && "$*" == *'/Users/|/home/'* ]]; then
  exit 75
fi
exec "${REAL_GREP:?}" "$@"
FAKE_GREP
chmod +x "${fake_bin}/git" "${fake_bin}/grep" "${fake_bin}/ln"

cat >"${test_repo}/tools/run-m1-device-smoke.sh" <<'FAKE_RUNNER'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >"${FAKE_RUNNER_ARGS}"
printf '\n' >>"${FAKE_RUNNER_ARGS}"

serial=""
result_log=""
download_destination=""
upload_source=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) serial="$2"; shift 2 ;;
    --result-log) result_log="$2"; shift 2 ;;
    --destination) download_destination="$2"; shift 2 ;;
    --upload-source) upload_source="$2"; shift 2 ;;
    --device-slot|--notes|--handshake-attempts|--min-handshake-passes|--list-path|--max-list-ms|--prepare-app-sandbox-file|--prepare-app-sandbox-bytes|--min-download-bytes|--min-download-mib-per-second|--chunk-size-bytes|--upload-destination-path|--min-upload-bytes|--min-upload-mib-per-second)
      shift 2
      ;;
    --adb-baseline-download-check) shift ;;
    --require-disposable-app-sandbox-paths) shift ;;
    *) printf 'unexpected fake runner option: %s\n' "$1" >&2; exit 91 ;;
  esac
done

[[ -n "${serial}" && -n "${result_log}" && -n "${download_destination}" && -n "${upload_source}" ]]
[[ "$(wc -c <"${upload_source}" | tr -d ' ')" == "104857600" ]]
mkdir -p "$(dirname "${result_log}")"
truncate -s 104857600 "${download_destination}"

short_sha="$(git rev-parse --short HEAD)"
cat >"${result_log}" <<EOF_LOG
# 2026-07-13 00:00:00Z ADB Device Smoke

status: passed
date: 2026-07-13 00:00:00Z
device slot: A
manufacturer/model: test legacy-device
android version/api: Android 9 / API 28
build channel: local release Swift harness + debug APK from git ${short_sha}
transport: ADB forward to debug harness Activity endpoint
handshake attempts: 20/20 passed via \`m1-smoke\` (minimum 19)
visible time: device already authorized over USB before script start
first list time: ${FAKE_LIST_ELAPSED_MS:-42} ms for \`dm://media-images/\` (max 1000 ms)
100MB download: \`download\` command passed for \`dm://app-sandbox/fake-source.bin\`; bytes 104857600 >= required 104857600; throughput 25.00 MiB/s over 4000 ms (required >= 20 MiB/s)
100MB upload: \`upload\` command passed to \`dm://app-sandbox/fake-upload.bin\`; bytes 104857600 >= required 104857600; throughput 25.00 MiB/s over 4000 ms (required >= 20 MiB/s)
resume result: not run
permission cases: launcher entry resolved to \`DroidMatchActivity\`; detailed permission-denied cases not run
diagnostics bundle: fake offline runner
notes:

- serial redaction tag: \`<serial-redacted:offline>\`
EOF_LOG

if [[ "${FAKE_SENSITIVE_LOG:-0}" == 1 ]]; then
  printf '%s\n' 'private path: /Users/private/secret-file' >>"${result_log}"
fi
if [[ "${FAKE_DUPLICATE_STATUS:-0}" == 1 ]]; then
  printf '%s\n' 'status: passed' >>"${result_log}"
fi

bytes="${FAKE_TRANSFER_BYTES:-104857600}"
chunk="${FAKE_NEGOTIATED_CHUNK:-1048576}"
elapsed_ms="${FAKE_ELAPSED_MS:-4000}"
printf 'private runner diagnostic serial=%s path=%s\n' "${serial}" "${download_destination}"
printf 'adb baseline download passed bytes=104857600 expected_bytes=104857600 elapsed_ms=4000 throughput_mib_per_sec=25.00\n'
if [[ "${FAKE_SKIP_RESERVATION_MARKER:-0}" != 1 ]]; then
  printf '%s\n' 'disposable app-sandbox paths reserved'
fi
printf 'serial=%s local_port=49152 remote_port=39001\n' "${serial}"
printf 'download passed transfer_id=d chunks=100 bytes=%s total=%s requested_chunk_size_bytes=1048576 chunk_size_bytes=%s final_offset=%s elapsed_ms=%s throughput_mib_per_sec=25.00 resume=false retry_attempts=1 recovered=false destination=<local-file>\n' \
  "${bytes}" "${bytes}" "${chunk}" "${bytes}" "${elapsed_ms}"
printf 'upload passed transfer_id=u chunks=100 bytes=%s total=%s requested_chunk_size_bytes=1048576 chunk_size_bytes=%s final_offset=%s elapsed_ms=%s throughput_mib_per_sec=25.00 resume=false retry_attempts=1 recovered=false source=<local-file> destination=dm://app-sandbox/fake.bin\n' \
  "${bytes}" "${bytes}" "${chunk}" "${bytes}" "${elapsed_ms}"
printf 'M1 device smoke passed serial=%s local_port=49152 remote_port=39001\n' "${serial}"
if [[ "${FAKE_ADVANCE_REMOTE:-0}" == 1 ]]; then
  git -C "${FAKE_ADVANCE_REPO}" commit --allow-empty -qm 'concurrent main advance'
  git -C "${FAKE_ADVANCE_REPO}" push -q origin main
fi
FAKE_RUNNER
chmod +x "${test_repo}/tools/run-m1-device-smoke.sh"

cat >"${fake_adb}" <<'FAKE_ADB'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${FAKE_ADB_CALLS}"
printf '\n' >>"${FAKE_ADB_CALLS}"

joined="$*"
if [[ "${joined}" == *'get-state'* ]]; then
  printf 'device\n'
elif [[ "${joined}" == *'getprop ro.build.version.sdk'* ]]; then
  printf '%s\n' "${FAKE_SDK:-28}"
elif [[ "${joined}" == 'forward --list' ]]; then
  if [[ "${FAKE_FORWARD_LIST_FAILURE:-0}" == 1 ]]; then
    exit 1
  fi
  if [[ "${FAKE_EXISTING_PROFILE_FORWARD:-0}" == 1 ]]; then
    printf '%s tcp:40000 tcp:39001\n' "${FAKE_SERIAL}"
  else
    printf '%s tcp:40000 tcp:40001\n' "${FAKE_SERIAL}"
  fi
elif [[ "${joined}" == *'forward --remove'* ]]; then
  exit 0
elif [[ "${joined}" == *' run-as app.droidmatch stat -c %s '* ]]; then
  printf '104857600\n'
elif [[ "${joined}" == *' run-as app.droidmatch rm -f '* ]]; then
  : >"${FAKE_CLEANUP_MARKER}"
elif [[ "${joined}" == *' run-as app.droidmatch test ! -e '* ]]; then
  if [[ "${FAKE_CLEANUP_FAILURE:-0}" == 1 && -e "${FAKE_CLEANUP_MARKER}" ]]; then
    exit 1
  fi
  exit 0
fi
FAKE_ADB
chmod +x "${fake_adb}"

git -C "${test_repo}" add tools
git -C "${test_repo}" commit -qm baseline
git -C "${test_repo}" branch -M main
git -C "${test_repo}" remote add origin "${remote_repo}"
git -C "${test_repo}" push -qu origin main
expected_sha="$(git -C "${test_repo}" rev-parse HEAD)"
advance_repo="${test_root}/advance"
git clone -q --branch main "${remote_repo}" "${advance_repo}"
git -C "${advance_repo}" config user.name 'DroidMatch Concurrent Test'
git -C "${advance_repo}" config user.email 'concurrent-test@droidmatch.invalid'

run_profile() {
  local log_name="$1"
  shift
  (
    cd "${test_repo}"
    TMPDIR="${private_tmp}" \
    FAKE_RUNNER_ARGS="${runner_args}" \
    FAKE_ADB_CALLS="${adb_calls}" \
    FAKE_CLEANUP_MARKER="${cleanup_marker}" \
    FAKE_SERIAL="${raw_serial}" \
    FAKE_ADVANCE_REPO="${advance_repo}" \
    FAKE_GIT_STATUS_CALLS="${git_status_calls}" \
    REAL_GIT="${real_git}" \
    REAL_GREP="${real_grep}" \
    REAL_LN="${real_ln}" \
    PATH="${fake_bin}:${PATH}" \
      "$@" bash tools/run-m1-throughput-gate.sh \
        --serial "${raw_serial}" \
        --expected-main-sha "${expected_sha}" \
        --adb "${fake_adb}" \
        --result-log "fixtures/m1-runs/${log_name}"
  )
}

rm -f "${runner_args}" "${adb_calls}" "${cleanup_marker}"
success_output="$(run_profile valid.md env 2>&1)"
valid_log="${test_repo}/fixtures/m1-runs/valid.md"
[[ -s "${valid_log}" ]]
[[ "${success_output}" == *'M1 throughput evidence passed profile=m1-adb-throughput-v1'* ]]
[[ "${success_output}" != *"${raw_serial}"* ]]
! grep -Fq "${raw_serial}" "${valid_log}"
grep -Fqx 'evidence profile: m1-adb-throughput-v1' "${valid_log}"
grep -Fqx 'profile cleanup verified before pass: true' "${valid_log}"
grep -Fqx 'profile download negotiated chunk bytes: 1048576' "${valid_log}"
grep -Fqx 'profile upload negotiated chunk bytes: 1048576' "${valid_log}"
grep -Fqx 'profile source revision: '"${expected_sha}" "${valid_log}"

for required_arg in \
  '--device-slot A' \
  '--handshake-attempts 20' \
  '--min-handshake-passes 19' \
  '--max-list-ms 1000' \
  '--prepare-app-sandbox-bytes 104857600' \
  '--require-disposable-app-sandbox-paths' \
  '--adb-baseline-download-check' \
  '--min-download-bytes 104857600' \
  '--min-download-mib-per-second 20' \
  '--chunk-size-bytes 1048576' \
  '--min-upload-bytes 104857600' \
  '--min-upload-mib-per-second 20'; do
  grep -Fq -- "${required_arg}" "${runner_args}"
done
! grep -Eq -- '--skip-build|--resume-check|--upload-resume-check|--cleanup-upload-destination' "${runner_args}"
grep -Fq '.droidmatch-upload-part' "${adb_calls}"
grep -Fq 'forward --remove tcp:49152' "${adb_calls}"

(
  cd "${test_repo}"
  bash tools/check-m1-run-logs.sh >/dev/null
  bash tools/check-m1-run-logs.sh --log "${valid_log}" >/dev/null
)

privacy_log="${test_repo}/fixtures/m1-runs/privacy-invalid.md"
cp "${valid_log}" "${privacy_log}"
printf '%s\n' 'PASSWORD=UPPERCASE-PRIVATE-VALUE' >>"${privacy_log}"
set +e
privacy_output="$(
  cd "${test_repo}"
  bash tools/check-m1-run-logs.sh --log "${privacy_log}" 2>&1
)"
privacy_status=$?
set -e
[[ "${privacy_status}" -ne 0 ]]
[[ "${privacy_output}" != *'UPPERCASE-PRIVATE-VALUE'* ]]
rm "${privacy_log}"

control_log="${test_repo}/fixtures/m1-runs/control-invalid.md"
cp "${valid_log}" "${control_log}"
printf 'control probe:\tinvalid\n' >>"${control_log}"
if (cd "${test_repo}" && bash tools/check-m1-run-logs.sh --log "${control_log}" \
    >/dev/null 2>&1); then
  printf '%s\n' 'profile validator accepted a control character' >&2
  exit 1
fi
rm "${control_log}"

set +e
grep_failure_output="$(
  cd "${test_repo}"
  PATH="${fake_bin}:${PATH}" \
  REAL_GREP="${real_grep}" \
  FAKE_GREP_CONTROL_FAILURE=1 \
    bash tools/check-m1-run-logs.sh --log "${valid_log}" 2>&1
)"
grep_failure_status=$?
set -e
[[ "${grep_failure_status}" -ne 0 ]]
grep -Fq 'could not be privacy-scanned' <<<"${grep_failure_output}"

set +e
grep_count_failure_output="$(
  cd "${test_repo}"
  PATH="${fake_bin}:${PATH}" \
  REAL_GREP="${real_grep}" \
  FAKE_GREP_COUNT_FAILURE=1 \
    bash tools/check-m1-run-logs.sh --log "${valid_log}" 2>&1
)"
grep_count_failure_status=$?
set -e
[[ "${grep_count_failure_status}" -ne 0 ]]
grep -Fq 'could not be scanned' <<<"${grep_count_failure_output}"

# Profile validation is conditional: mutating a strict field must fail without
# changing the legacy global field contract.
sed 's/profile upload observed mib per second: 25.00/profile upload observed mib per second: 19.99/' \
  "${valid_log}" >"${test_repo}/fixtures/m1-runs/invalid.md"
if (cd "${test_repo}" && bash tools/check-m1-run-logs.sh >/dev/null 2>&1); then
  printf '%s\n' 'profile validator accepted sub-threshold upload evidence' >&2
  exit 1
fi
rm "${test_repo}/fixtures/m1-runs/invalid.md"

sed 's/profile upload elapsed ms: 4000/profile upload elapsed ms: 9223372036854775808/' \
  "${valid_log}" >"${test_repo}/fixtures/m1-runs/overflow-profile-elapsed.md"
if (cd "${test_repo}" && bash tools/check-m1-run-logs.sh \
    --log fixtures/m1-runs/overflow-profile-elapsed.md >/dev/null 2>&1); then
  printf '%s\n' 'profile validator accepted an overflowing elapsed value' >&2
  exit 1
fi
rm "${test_repo}/fixtures/m1-runs/overflow-profile-elapsed.md"

sed 's/profile warm list elapsed ms: 42/profile warm list elapsed ms: 9223372036854775808/' \
  "${valid_log}" >"${test_repo}/fixtures/m1-runs/overflow-profile-list.md"
if (cd "${test_repo}" && bash tools/check-m1-run-logs.sh \
    --log fixtures/m1-runs/overflow-profile-list.md >/dev/null 2>&1); then
  printf '%s\n' 'profile validator accepted an overflowing list elapsed value' >&2
  exit 1
fi
rm "${test_repo}/fixtures/m1-runs/overflow-profile-list.md"

cp "${valid_log}" "${test_repo}/fixtures/m1-runs/contradictory.md"
printf '%s\n' \
  'status: failed' \
  'device slot: B' \
  'handshake attempts: 0/20 passed via `m1-smoke` (minimum 19)' \
  >>"${test_repo}/fixtures/m1-runs/contradictory.md"
if (cd "${test_repo}" && bash tools/check-m1-run-logs.sh >/dev/null 2>&1); then
  printf '%s\n' 'profile validator accepted contradictory base evidence' >&2
  exit 1
fi
rm "${test_repo}/fixtures/m1-runs/contradictory.md"

sed 's@100MB download: .*@100MB download: failed@' \
  "${valid_log}" >"${test_repo}/fixtures/m1-runs/contradictory-download.md"
if (cd "${test_repo}" && bash tools/check-m1-run-logs.sh \
    --log fixtures/m1-runs/contradictory-download.md >/dev/null 2>&1); then
  printf '%s\n' 'profile validator accepted a contradictory download summary' >&2
  exit 1
fi
rm "${test_repo}/fixtures/m1-runs/contradictory-download.md"

sed '/^100MB download:/ s/throughput 25.00 MiB\/s over 4000 ms/throughput 0.01 MiB\/s over 999999 ms/' \
  "${valid_log}" >"${test_repo}/fixtures/m1-runs/contradictory-download-metrics.md"
if (cd "${test_repo}" && bash tools/check-m1-run-logs.sh \
    --log fixtures/m1-runs/contradictory-download-metrics.md >/dev/null 2>&1); then
  printf '%s\n' 'profile validator accepted contradictory download summary metrics' >&2
  exit 1
fi
rm "${test_repo}/fixtures/m1-runs/contradictory-download-metrics.md"

sed '/^100MB upload:/ s/throughput 25.00 MiB\/s over 4000 ms/throughput 0.01 MiB\/s over 999999 ms/' \
  "${valid_log}" >"${test_repo}/fixtures/m1-runs/contradictory-upload-metrics.md"
if (cd "${test_repo}" && bash tools/check-m1-run-logs.sh \
    --log fixtures/m1-runs/contradictory-upload-metrics.md >/dev/null 2>&1); then
  printf '%s\n' 'profile validator accepted contradictory upload summary metrics' >&2
  exit 1
fi
rm "${test_repo}/fixtures/m1-runs/contradictory-upload-metrics.md"

sed 's@^first list time: 42 ms@first list time: 43 ms@' \
  "${valid_log}" >"${test_repo}/fixtures/m1-runs/contradictory-list-summary.md"
if (cd "${test_repo}" && bash tools/check-m1-run-logs.sh \
    --log fixtures/m1-runs/contradictory-list-summary.md >/dev/null 2>&1); then
  printf '%s\n' 'profile validator accepted a contradictory warm-list summary' >&2
  exit 1
fi
rm "${test_repo}/fixtures/m1-runs/contradictory-list-summary.md"

cp "${valid_log}" "${test_repo}/fixtures/m1-runs/unknown-profile-field.md"
printf '%s\n' 'profile unexpected field: value' \
  >>"${test_repo}/fixtures/m1-runs/unknown-profile-field.md"
if (cd "${test_repo}" && bash tools/check-m1-run-logs.sh \
    --log fixtures/m1-runs/unknown-profile-field.md >/dev/null 2>&1); then
  printf '%s\n' 'profile validator accepted an unknown profile field' >&2
  exit 1
fi
rm "${test_repo}/fixtures/m1-runs/unknown-profile-field.md"

# Remove the published evidence so the repository returns to its required clean
# provenance before each negative wrapper case.
rm "${valid_log}"

rm -f "${git_status_calls}"
set +e
git_preflight_output="$(
  run_profile git-status-preflight.md env FAKE_GIT_STATUS_FAIL_ON=1 2>&1
)"
git_preflight_status=$?
set -e
if [[ "${git_preflight_status}" -eq 0 ]]; then
  printf '%s\n' 'profile accepted a failed pre-run git status check' >&2
  exit 1
fi
grep -Fq 'could not verify the pre-run worktree state' <<<"${git_preflight_output}"
grep -Fqx '1' "${git_status_calls}"
[[ ! -e "${test_repo}/fixtures/m1-runs/git-status-preflight.md" ]]

rm -f "${git_status_calls}"
set +e
git_postflight_output="$(
  run_profile git-status-postflight.md env FAKE_GIT_STATUS_FAIL_ON=2 2>&1
)"
git_postflight_status=$?
set -e
if [[ "${git_postflight_status}" -eq 0 ]]; then
  printf '%s\n' 'profile accepted a failed post-run git status check' >&2
  exit 1
fi
grep -Fq 'could not verify the post-run worktree state' <<<"${git_postflight_output}"
grep -Fqx '2' "${git_status_calls}"
[[ ! -e "${test_repo}/fixtures/m1-runs/git-status-postflight.md" ]]

set +e
duplicate_output="$(run_profile duplicate-status.md env FAKE_DUPLICATE_STATUS=1 2>&1)"
duplicate_status=$?
set -e
[[ "${duplicate_status}" -ne 0 ]]
[[ "${duplicate_output}" != *'M1 throughput evidence passed'* ]]
[[ ! -e "${test_repo}/fixtures/m1-runs/duplicate-status.md" ]]

set +e
serial_scan_output="$(
  run_profile serial-scan-failure.md env FAKE_GREP_SERIAL_FAILURE=1 2>&1
)"
serial_scan_status=$?
set -e
[[ "${serial_scan_status}" -ne 0 ]]
[[ "${serial_scan_output}" == *'could not scan the staged log for the raw serial'* ]]
[[ "${serial_scan_output}" != *"${raw_serial}"* ]]
[[ ! -e "${test_repo}/fixtures/m1-runs/serial-scan-failure.md" ]]

set +e
sensitive_scan_output="$(
  run_profile sensitive-scan-failure.md env FAKE_GREP_SENSITIVE_FAILURE=1 2>&1
)"
sensitive_scan_status=$?
set -e
[[ "${sensitive_scan_status}" -ne 0 ]]
[[ "${sensitive_scan_output}" == *'could not privacy-scan the staged evidence log'* ]]
[[ "${sensitive_scan_output}" != *"${raw_serial}"* ]]
[[ ! -e "${test_repo}/fixtures/m1-runs/sensitive-scan-failure.md" ]]

set +e
race_output="$(run_profile publish-race.md env FAKE_LN_RACE=1 2>&1)"
race_status=$?
set -e
[[ "${race_status}" -ne 0 ]]
[[ "${race_output}" != *'M1 throughput evidence passed'* ]]
grep -Fqx 'concurrent-writer-sentinel' \
  "${test_repo}/fixtures/m1-runs/publish-race.md"
rm "${test_repo}/fixtures/m1-runs/publish-race.md"

set +e
symlink_race_output="$(
  run_profile publish-symlink-race.md env FAKE_LN_SYMLINK_RACE=1 2>&1
)"
symlink_race_status=$?
set -e
[[ "${symlink_race_status}" -ne 0 ]]
[[ "${symlink_race_output}" != *'M1 throughput evidence passed'* ]]
symlink_race_path="${test_repo}/fixtures/m1-runs/publish-symlink-race.md"
[[ -L "${symlink_race_path}" ]]
[[ -d "${symlink_race_path}.directory" ]]
if find "${symlink_race_path}.directory" -mindepth 1 -print -quit | grep -q .; then
  printf '%s\n' 'profile followed a concurrent target symlink during publication' >&2
  exit 1
fi
rm "${symlink_race_path}"
rmdir "${symlink_race_path}.directory"

printf '%s\n' dirty >"${test_repo}/untracked.txt"
if run_profile dirty.md env >/dev/null 2>&1; then
  printf '%s\n' 'profile accepted a dirty worktree' >&2
  exit 1
fi
rm "${test_repo}/untracked.txt"
[[ ! -e "${test_repo}/fixtures/m1-runs/dirty.md" ]]

if (
  cd "${test_repo}"
  bash tools/run-m1-throughput-gate.sh \
    --serial "${raw_serial}" \
    --expected-main-sha 0000000000000000000000000000000000000000 \
    --adb "${fake_adb}" >/dev/null 2>&1
); then
  printf '%s\n' 'profile accepted a mismatched expected SHA' >&2
  exit 1
fi

rm -f "${cleanup_marker}"
set +e
chunk_failure_output="$(run_profile chunk-failure.md env FAKE_NEGOTIATED_CHUNK=524288 2>&1)"
chunk_failure_status=$?
set -e
[[ "${chunk_failure_status}" -ne 0 ]]
[[ "${chunk_failure_output}" != *"${raw_serial}"* ]]
[[ "${chunk_failure_output}" != *'M1 throughput evidence passed'* ]]
[[ ! -e "${test_repo}/fixtures/m1-runs/chunk-failure.md" ]]

set +e
bytes_failure_output="$(run_profile bytes-failure.md env FAKE_TRANSFER_BYTES=104857599 2>&1)"
bytes_failure_status=$?
set -e
[[ "${bytes_failure_status}" -ne 0 ]]
[[ "${bytes_failure_output}" != *"${raw_serial}"* ]]
[[ "${bytes_failure_output}" != *'M1 throughput evidence passed'* ]]
[[ ! -e "${test_repo}/fixtures/m1-runs/bytes-failure.md" ]]

set +e
reservation_failure_output="$(run_profile reservation-failure.md env FAKE_SKIP_RESERVATION_MARKER=1 2>&1)"
reservation_failure_status=$?
set -e
[[ "${reservation_failure_status}" -ne 0 ]]
[[ "${reservation_failure_output}" != *"${raw_serial}"* ]]
[[ "${reservation_failure_output}" != *'M1 throughput evidence passed'* ]]
[[ ! -e "${test_repo}/fixtures/m1-runs/reservation-failure.md" ]]

set +e
elapsed_failure_output="$(run_profile elapsed-failure.md env FAKE_ELAPSED_MS=5001 2>&1)"
elapsed_failure_status=$?
set -e
[[ "${elapsed_failure_status}" -ne 0 ]]
[[ "${elapsed_failure_output}" != *"${raw_serial}"* ]]
[[ "${elapsed_failure_output}" != *'M1 throughput evidence passed'* ]]
[[ ! -e "${test_repo}/fixtures/m1-runs/elapsed-failure.md" ]]

set +e
overflow_elapsed_output="$(
  run_profile overflow-elapsed.md env FAKE_ELAPSED_MS=9223372036854775808 2>&1
)"
overflow_elapsed_status=$?
set -e
[[ "${overflow_elapsed_status}" -ne 0 ]]
[[ "${overflow_elapsed_output}" != *'M1 throughput evidence passed'* ]]
[[ ! -e "${test_repo}/fixtures/m1-runs/overflow-elapsed.md" ]]

set +e
overflow_list_output="$(
  run_profile overflow-list.md env FAKE_LIST_ELAPSED_MS=9223372036854775808 2>&1
)"
overflow_list_status=$?
set -e
[[ "${overflow_list_status}" -ne 0 ]]
[[ "${overflow_list_output}" != *'M1 throughput evidence passed'* ]]
[[ ! -e "${test_repo}/fixtures/m1-runs/overflow-list.md" ]]

set +e
sensitive_failure_output="$(run_profile sensitive-failure.md env FAKE_SENSITIVE_LOG=1 2>&1)"
sensitive_failure_status=$?
set -e
[[ "${sensitive_failure_status}" -ne 0 ]]
[[ "${sensitive_failure_output}" != *'/Users/private/'* ]]
[[ "${sensitive_failure_output}" != *'secret-file'* ]]
[[ ! -e "${test_repo}/fixtures/m1-runs/sensitive-failure.md" ]]

rm -f "${cleanup_marker}"
set +e
cleanup_failure_output="$(run_profile cleanup-failure.md env FAKE_CLEANUP_FAILURE=1 2>&1)"
cleanup_failure_status=$?
set -e
[[ "${cleanup_failure_status}" -ne 0 ]]
[[ "${cleanup_failure_output}" != *"${raw_serial}"* ]]
[[ "${cleanup_failure_output}" != *'M1 throughput evidence passed'* ]]
[[ ! -e "${test_repo}/fixtures/m1-runs/cleanup-failure.md" ]]

set +e
api_failure_output="$(run_profile api-failure.md env FAKE_SDK=30 2>&1)"
api_failure_status=$?
set -e
[[ "${api_failure_status}" -ne 0 ]]
[[ "${api_failure_output}" != *"${raw_serial}"* ]]
[[ ! -e "${test_repo}/fixtures/m1-runs/api-failure.md" ]]

set +e
forward_failure_output="$(run_profile forward-failure.md env FAKE_EXISTING_PROFILE_FORWARD=1 2>&1)"
forward_failure_status=$?
set -e
[[ "${forward_failure_status}" -ne 0 ]]
[[ "${forward_failure_output}" != *"${raw_serial}"* ]]
[[ ! -e "${test_repo}/fixtures/m1-runs/forward-failure.md" ]]

set +e
snapshot_failure_output="$(run_profile snapshot-failure.md env FAKE_FORWARD_LIST_FAILURE=1 2>&1)"
snapshot_failure_status=$?
set -e
[[ "${snapshot_failure_status}" -ne 0 ]]
[[ "${snapshot_failure_output}" != *"${raw_serial}"* ]]
[[ ! -e "${test_repo}/fixtures/m1-runs/snapshot-failure.md" ]]

set +e
advance_failure_output="$(run_profile advanced-main.md env FAKE_ADVANCE_REMOTE=1 2>&1)"
advance_failure_status=$?
set -e
[[ "${advance_failure_status}" -ne 0 ]]
[[ "${advance_failure_output}" != *"${raw_serial}"* ]]
[[ "${advance_failure_output}" != *'M1 throughput evidence passed'* ]]
[[ ! -e "${test_repo}/fixtures/m1-runs/advanced-main.md" ]]

set +e
unknown_output="$(
  cd "${test_repo}"
  bash tools/run-m1-throughput-gate.sh --serial="${raw_serial}" 2>&1
)"
unknown_status=$?
set -e
[[ "${unknown_status}" -ne 0 ]]
[[ "${unknown_output}" != *"${raw_serial}"* ]]

if find "${private_tmp}" -mindepth 1 -print -quit | grep -q .; then
  printf '%s\n' 'profile left private temporary artifacts behind' >&2
  exit 1
fi

printf '%s\n' 'M1 ADB throughput evidence profile offline tests passed.'
printf '%s\n' '中文：M1 ADB 吞吐证据 profile 离线测试通过。'
