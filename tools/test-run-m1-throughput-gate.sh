#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_wrapper="${repo_root}/tools/run-m1-throughput-gate.sh"
source_checker="${repo_root}/tools/check-m1-run-logs.sh"
source_common="${repo_root}/tools/m1-run-log-common.sh"
source_profile="${repo_root}/tools/m1-run-log-profile.sh"
source_staging_helper="${repo_root}/tools/app-sandbox-upload-staging.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-throughput-profile-test.XXXXXX")"
current_case_file="${test_root}/current-case"

cleanup_test_root() {
  local status="$1" case_name='setup'
  if [[ "${status}" -ne 0 ]]; then
    [[ ! -s "${current_case_file}" ]] || case_name="$(<"${current_case_file}")"
    printf 'M1 throughput offline test failed near case: %s\n' "${case_name}" >&2
  fi
  rm -rf "${test_root}"
  exit "${status}"
}
trap 'cleanup_test_root "$?"' EXIT

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
real_rm="$(command -v rm)"
real_shasum="$(command -v shasum)"

# Shared shell/Java vector for destination-scoped private staging cleanup.
source "${repo_root}/tools/app-sandbox-upload-staging.sh"
[[ "$(droidmatch_app_sandbox_upload_destination_key 'uploads/payload.bin')" == \
  '0288faa2e1495ced41d8de4deeac3c4299ad8c4b24d1f9ea4b8dc5c45498d032' ]]

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
cp "${source_common}" "${test_repo}/tools/m1-run-log-common.sh"
cp "${source_profile}" "${test_repo}/tools/m1-run-log-profile.sh"
cp "${source_staging_helper}" "${test_repo}/tools/app-sandbox-upload-staging.sh"
chmod +x "${test_repo}/tools/"*.sh

cat >"${fake_bin}/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${FAKE_TOOL_TMP_ARTIFACT:-0}" == "1" ]]; then
  : >"${TMPDIR:?}/xcrun_db"
fi

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
    && "${1:-}" == "-Eiq" \
    && "${2:-}" == *'Authorization:'* \
    && "${3:-}" == */.throughput-* ]]; then
  exit 75
fi
exec "${REAL_GREP:?}" "$@"
FAKE_GREP

cat >"${fake_bin}/rm" <<'FAKE_RM'
#!/usr/bin/env bash
set -euo pipefail

for argument in "$@"; do
  if [[ "${FAKE_RM_STAGED_FAILURE:-0}" == 1 \
      && "${argument}" == *'/.throughput-evidence.'* ]]; then
    exit 76
  fi
done
exec "${REAL_RM:?}" "$@"
FAKE_RM

cat >"${fake_bin}/shasum" <<'FAKE_SHASUM'
#!/usr/bin/env bash
set -euo pipefail

# Remote upload verification hashes an adb byte stream. Keep the offline suite
# fast by representing the managed 100 MiB zero stream with a private token;
# regular files still use the real shasum and exercise the production path.
if [[ $# -eq 2 && "$1" == "-a" && "$2" == "256" ]]; then
  payload="$(cat)"
  if [[ "${payload}" == '__DROIDMATCH_FAKE_100_MIB_ZERO__' ]]; then
    printf '%s  -\n' '20492a4d0d84f8beb1767f6616229f85d44c2827b64bdbfb260ee12fa1109e0e'
    exit 0
  fi
  printf '%s' "${payload}" | "${REAL_SHASUM:?}" "$@"
  exit
fi
exec "${REAL_SHASUM:?}" "$@"
FAKE_SHASUM
chmod +x \
  "${fake_bin}/git" \
  "${fake_bin}/grep" \
  "${fake_bin}/ln" \
  "${fake_bin}/rm" \
  "${fake_bin}/shasum"

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
if [[ "${FAKE_DOWNLOAD_CONTENT_MISMATCH:-0}" == 1 ]]; then
  printf 'X' | dd of="${download_destination}" conv=notrunc 2>/dev/null
fi

short_sha="$(git rev-parse --short HEAD)"
full_sha="$(git rev-parse HEAD)"
runner_status="${FAKE_RUNNER_EXIT_STATUS:-0}"
producer_download_elapsed="${FAKE_DOWNLOAD_ELAPSED_MS:-4000}"
producer_download_rate="${FAKE_DOWNLOAD_THROUGHPUT:-25.00}"
producer_upload_elapsed="${FAKE_UPLOAD_ELAPSED_MS:-4000}"
producer_upload_rate="${FAKE_UPLOAD_THROUGHPUT:-25.00}"
cat >"${result_log}" <<EOF_LOG
# 2026-07-13 00:00:00Z ADB Device Smoke

evidence profile: m1-device-smoke-v1
device profile result: passed
device profile archive class: device-evidence
device profile source revision: ${full_sha}
device profile source state: clean
device profile build mode: rebuilt
device profile apk sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
device profile harness configuration: release
device profile device slot: A
device profile android api: 28
device profile checks requested: m1-smoke,adb-baseline,list-dir,download,upload
device profile checks passed: m1-smoke,adb-baseline,list-dir,download,upload
device profile checks incomplete: none
device profile failure stage: none
device profile handshake attempts: 20
device profile handshake passed: 20
device profile handshake minimum: 19
device profile list elapsed ms: ${FAKE_LIST_ELAPSED_MS:-42}
device profile list maximum ms: 1000
device profile download bytes: 104857600
device profile download measured bytes: 104857600
device profile download elapsed ms: ${producer_download_elapsed}
device profile download observed mib per second: ${producer_download_rate}
device profile download minimum bytes: 104857600
device profile download minimum mib per second: 20
device profile upload bytes: 104857600
device profile upload measured bytes: 104857600
device profile upload elapsed ms: ${producer_upload_elapsed}
device profile upload observed mib per second: ${producer_upload_rate}
device profile upload minimum bytes: 104857600
device profile upload minimum mib per second: 20
device profile cleanup: scheduled-on-exit
status: passed
date: 2026-07-13 00:00:00Z
device slot: A
manufacturer/model: test legacy-device
android version/api: Android 9 / API 28
build channel: local release Swift harness + debug APK from git ${short_sha}
transport: ADB forward to debug harness Activity endpoint
handshake attempts: 20/20 passed via \`m1-smoke\` (minimum 19)
dual-stream download: not run
mixed-stream transfer: not run
visible time: device already authorized over USB before script start
first list time: ${FAKE_LIST_ELAPSED_MS:-42} ms for \`dm://media-images/\` (max 1000 ms)
adb baseline download: \`exec-out run-as cat\` read \`dm://app-sandbox/fake-source.bin\`; bytes 104857600 expected 104857600; throughput 25.00 MiB/s over 4000 ms
100MB download: \`download\` command passed for \`dm://app-sandbox/fake-source.bin\`; bytes 104857600 >= required 104857600; throughput ${producer_download_rate} MiB/s over ${producer_download_elapsed} ms (required >= 20 MiB/s)
100MB upload: \`upload\` command passed to \`dm://app-sandbox/fake-upload.bin\`; bytes 104857600 >= required 104857600; throughput ${producer_upload_rate} MiB/s over ${producer_upload_elapsed} ms (required >= 20 MiB/s)
resume result: not run
cancel result: not run
pause result: not run
permission cases: launcher entry resolved to \`DroidMatchActivity\`; detailed permission-denied cases not run
diagnostics bundle: \`m1-smoke\` output included below
notes:

- serial redaction tag: \`<serial-redacted:deadbeef>\`
- ADB baseline download: enabled via \`adb exec-out run-as app.droidmatch cat\`
- upload destination: \`dm://app-sandbox/fake-upload.bin\`
EOF_LOG

if [[ "${runner_status}" -ne 0 ]]; then
  failed_log="${result_log}.failed"
  sed \
    -e 's/device profile result: passed/device profile result: failed/' \
    -e 's/device profile archive class: device-evidence/device profile archive class: failed-diagnostic/' \
    -e 's/device profile checks passed: .*/device profile checks passed: none/' \
    -e 's/device profile checks incomplete: none/device profile checks incomplete: m1-smoke,adb-baseline,list-dir,download,upload/' \
    -e "s/device profile failure stage: none/device profile failure stage: ${FAKE_RUNNER_FAILURE_STAGE:-throughput assertion}/" \
    -e 's/^status: passed/status: failed/' \
    -e 's/command passed/command transferred/' \
    -e 's/ (required >= 20 MiB\/s)$/ (required >= 20 MiB\/s); final status failed after transfer/' \
    "${result_log}" >"${failed_log}"
  mv "${failed_log}" "${result_log}"
  printf 'failure stage: %s\n' \
    "${FAKE_RUNNER_FAILURE_STAGE:-throughput assertion}" >>"${result_log}"
  if [[ "${FAKE_UPLOAD_NOT_RUN:-0}" == 1 ]]; then
    failed_log="${result_log}.failed"
    sed \
      -e 's/device profile upload bytes: .*/device profile upload bytes: not-run/' \
      -e 's/device profile upload measured bytes: .*/device profile upload measured bytes: not-run/' \
      -e 's/device profile upload elapsed ms: .*/device profile upload elapsed ms: not-run/' \
      -e 's/device profile upload observed mib per second: .*/device profile upload observed mib per second: not-run/' \
      -e 's/^100MB upload: .*/100MB upload: not run/' \
      "${result_log}" >"${failed_log}"
    mv "${failed_log}" "${result_log}"
  fi
fi

if [[ "${FAKE_SENSITIVE_LOG:-0}" == 1 ]]; then
  printf '%s\n' 'private path: /Users/private/secret-file' >>"${result_log}"
fi
if [[ "${FAKE_DUPLICATE_STATUS:-0}" == 1 ]]; then
  printf '%s\n' 'status: passed' >>"${result_log}"
fi

bytes="${FAKE_TRANSFER_BYTES:-104857600}"
chunk="${FAKE_NEGOTIATED_CHUNK:-1048576}"
elapsed_ms="${FAKE_ELAPSED_MS:-4000}"
output_download_rate="${FAKE_DOWNLOAD_THROUGHPUT:-25.00}"
output_upload_rate="${FAKE_UPLOAD_THROUGHPUT:-25.00}"
printf 'private runner diagnostic serial=%s path=%s\n' "${serial}" "${download_destination}"
if [[ -n "${FAKE_RUNNER_PRIVATE_OUTPUT:-}" ]]; then
  printf '%s\n' "${FAKE_RUNNER_PRIVATE_OUTPUT}"
fi
printf 'adb baseline download passed bytes=104857600 expected_bytes=104857600 elapsed_ms=4000 throughput_mib_per_sec=25.00\n'
if [[ "${FAKE_SKIP_RESERVATION_MARKER:-0}" != 1 ]]; then
  printf '%s\n' 'disposable app-sandbox paths reserved'
fi
printf 'serial=%s local_port=49152 remote_port=39001\n' "${serial}"
printf 'download passed transfer_id=d chunks=100 bytes=%s total=%s requested_chunk_size_bytes=1048576 chunk_size_bytes=%s final_offset=%s elapsed_ms=%s throughput_mib_per_sec=%s resume=false retry_attempts=1 recovered=false destination=<local-file>\n' \
  "${bytes}" "${bytes}" "${chunk}" "${bytes}" "${elapsed_ms}" "${output_download_rate}"
printf 'upload passed transfer_id=u chunks=100 bytes=%s total=%s requested_chunk_size_bytes=1048576 chunk_size_bytes=%s final_offset=%s elapsed_ms=%s throughput_mib_per_sec=%s resume=false retry_attempts=1 recovered=false source=<local-file> destination=dm://app-sandbox/fake.bin\n' \
  "${bytes}" "${bytes}" "${chunk}" "${bytes}" "${elapsed_ms}" "${output_upload_rate}"
printf 'M1 device smoke passed serial=%s local_port=49152 remote_port=39001\n' "${serial}"
if [[ "${FAKE_ADVANCE_REMOTE:-0}" == 1 ]]; then
  git -C "${FAKE_ADVANCE_REPO}" commit --allow-empty -qm 'concurrent main advance'
  git -C "${FAKE_ADVANCE_REPO}" push -q origin main
fi
exit "${runner_status}"
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
elif [[ "${joined}" == *'exec-out run-as app.droidmatch cat files/droidmatch-sandbox/'* ]]; then
  if [[ "${FAKE_REMOTE_CONTENT_MISMATCH:-0}" == 1 ]]; then
    printf '%s' '__DROIDMATCH_FAKE_CORRUPTED_UPLOAD__'
  else
    printf '%s' '__DROIDMATCH_FAKE_100_MIB_ZERO__'
  fi
elif [[ "${joined}" == *' run-as app.droidmatch stat -c %s '* ]]; then
  printf '104857600\n'
elif [[ "${joined}" == *' run-as app.droidmatch rm -f '* ]]; then
  : >"${FAKE_CLEANUP_MARKER}"
elif [[ "${joined}" == *'test ! -e '* && "${joined}" == *'test ! -L '* ]]; then
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
  printf '%s\n' "${log_name}" >"${current_case_file}"
  (
    cd "${test_repo}"
    TMPDIR="${private_tmp}" \
    FAKE_RUNNER_ARGS="${runner_args}" \
    FAKE_ADB_CALLS="${adb_calls}" \
    FAKE_CLEANUP_MARKER="${cleanup_marker}" \
    FAKE_SERIAL="${raw_serial}" \
    FAKE_ADVANCE_REPO="${advance_repo}" \
    FAKE_GIT_STATUS_CALLS="${git_status_calls}" \
    FAKE_TOOL_TMP_ARTIFACT=1 \
    REAL_GIT="${real_git}" \
    REAL_GREP="${real_grep}" \
    REAL_LN="${real_ln}" \
    REAL_RM="${real_rm}" \
    REAL_SHASUM="${real_shasum}" \
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
[[ "${success_output}" == *'M1 throughput evidence passed profile=m1-adb-throughput-v2'* ]]
[[ "${success_output}" != *"${raw_serial}"* ]]
! grep -Fq "${raw_serial}" "${valid_log}"
grep -Fqx 'evidence profile: m1-adb-throughput-v2' "${valid_log}"
[[ "$(grep -c '^evidence profile:' "${valid_log}")" -eq 1 ]]
grep -Fqx 'evidence producer profile: m1-device-smoke-v1' "${valid_log}"
[[ "$(grep -c '^evidence producer profile:' "${valid_log}")" -eq 1 ]]
! grep -Fqx 'evidence profile: m1-device-smoke-v1' "${valid_log}"
grep -Fqx 'profile cleanup verified before pass: true' "${valid_log}"
grep -Fqx 'profile download negotiated chunk bytes: 1048576' "${valid_log}"
grep -Fqx 'profile upload negotiated chunk bytes: 1048576' "${valid_log}"
grep -Fqx 'profile source revision: '"${expected_sha}" "${valid_log}"
for payload_field in managed download upload; do
  grep -Fqx \
    "profile ${payload_field} payload sha256: 20492a4d0d84f8beb1767f6616229f85d44c2827b64bdbfb260ee12fa1109e0e" \
    "${valid_log}"
done

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
grep -Fq '.droidmatch-sandbox.droidmatch-upload-staging' "${adb_calls}"
grep -Fq 'forward --remove tcp:49152' "${adb_calls}"

(
  cd "${test_repo}"
  bash tools/check-m1-run-logs.sh --log "${valid_log}" >/dev/null
)
"${repo_root}/tools/test-m1-throughput-profile-validator.sh" \
  "${test_repo}" "${valid_log}" "${fake_bin}" "${real_grep}"

# Remove the published evidence so the repository returns to its required clean
# provenance before each negative wrapper case.
rm "${valid_log}"

expect_diagnostic() {
  local log_name="$1" expected_stage="$2" expected_producer="$3"
  local path="${test_repo}/fixtures/m1-runs/${log_name}"
  [[ -s "${path}" && ! -L "${path}" ]]
  (
    cd "${test_repo}"
    bash tools/check-m1-run-logs.sh --log "fixtures/m1-runs/${log_name}" >/dev/null
  )
  grep -Fqx 'evidence profile: m1-adb-throughput-diagnostic-v1' "${path}"
  grep -Fqx "diagnostic failure stage: ${expected_stage}" "${path}"
  grep -Fqx "diagnostic producer result: ${expected_producer}" "${path}"
  ! grep -Fq "${raw_serial}" "${path}"
  rm "${path}"
}

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
grep -Fqx '3' "${git_status_calls}"
expect_diagnostic git-status-postflight.md post-run-provenance passed

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
expect_diagnostic chunk-failure.md wrapper-contract passed

set +e
bytes_failure_output="$(run_profile bytes-failure.md env FAKE_TRANSFER_BYTES=104857599 2>&1)"
bytes_failure_status=$?
set -e
[[ "${bytes_failure_status}" -ne 0 ]]
[[ "${bytes_failure_output}" != *"${raw_serial}"* ]]
[[ "${bytes_failure_output}" != *'M1 throughput evidence passed'* ]]
expect_diagnostic bytes-failure.md wrapper-contract passed

set +e
download_content_output="$(
  run_profile download-content-mismatch.md env FAKE_DOWNLOAD_CONTENT_MISMATCH=1 2>&1
)"
download_content_status=$?
set -e
[[ "${download_content_status}" -ne 0 ]]
[[ "${download_content_output}" != *"${raw_serial}"* ]]
[[ "${download_content_output}" != *'M1 throughput evidence passed'* ]]
expect_diagnostic download-content-mismatch.md download-content-integrity passed

set +e
upload_content_output="$(
  run_profile upload-content-mismatch.md env FAKE_REMOTE_CONTENT_MISMATCH=1 2>&1
)"
upload_content_status=$?
set -e
[[ "${upload_content_status}" -ne 0 ]]
[[ "${upload_content_output}" != *"${raw_serial}"* ]]
[[ "${upload_content_output}" != *'M1 throughput evidence passed'* ]]
expect_diagnostic upload-content-mismatch.md upload-content-integrity passed

rm -f "${cleanup_marker}"
set +e
reservation_failure_output="$(run_profile reservation-failure.md env FAKE_SKIP_RESERVATION_MARKER=1 2>&1)"
reservation_failure_status=$?
set -e
[[ "${reservation_failure_status}" -ne 0 ]]
[[ "${reservation_failure_output}" != *"${raw_serial}"* ]]
[[ "${reservation_failure_output}" != *'M1 throughput evidence passed'* ]]
[[ ! -e "${cleanup_marker}" ]]
expect_diagnostic reservation-failure.md wrapper-contract passed

set +e
download_threshold_output="$({
  run_profile download-threshold.md env \
    FAKE_RUNNER_EXIT_STATUS=1 \
    'FAKE_RUNNER_FAILURE_STAGE=download throughput assertion' \
    FAKE_DOWNLOAD_ELAPSED_MS=6250 \
    FAKE_DOWNLOAD_THROUGHPUT=16.00 \
    FAKE_UPLOAD_NOT_RUN=1 \
    'FAKE_RUNNER_PRIVATE_OUTPUT=/Users/private/raw ghp_12345678901234567890'
} 2>&1)"
download_threshold_status=$?
set -e
[[ "${download_threshold_status}" -eq 1 ]]
[[ "${download_threshold_output}" != *"${raw_serial}"* \
    && "${download_threshold_output}" != *'/Users/private/'* \
    && "${download_threshold_output}" != *'ghp_'* ]]
download_threshold_log="${test_repo}/fixtures/m1-runs/download-threshold.md"
grep -Fqx 'device profile download observed mib per second: 16.00' \
  "${download_threshold_log}"
grep -Fqx 'device profile upload observed mib per second: not-run' \
  "${download_threshold_log}"
grep -Fqx 'diagnostic producer exit status: 1' "${download_threshold_log}"
expect_diagnostic download-threshold.md producer-exit failed

set +e
upload_threshold_output="$({
  run_profile upload-threshold.md env \
    FAKE_RUNNER_EXIT_STATUS=37 \
    'FAKE_RUNNER_FAILURE_STAGE=upload throughput assertion' \
    FAKE_UPLOAD_ELAPSED_MS=6250 \
    FAKE_UPLOAD_THROUGHPUT=16.00
} 2>&1)"
upload_threshold_status=$?
set -e
[[ "${upload_threshold_status}" -eq 1 ]]
[[ "${upload_threshold_output}" != *"${raw_serial}"* ]]
upload_threshold_log="${test_repo}/fixtures/m1-runs/upload-threshold.md"
grep -Fqx 'device profile download observed mib per second: 25.00' \
  "${upload_threshold_log}"
grep -Fqx 'device profile upload observed mib per second: 16.00' \
  "${upload_threshold_log}"
grep -Fqx 'diagnostic producer exit status: 37' "${upload_threshold_log}"
expect_diagnostic upload-threshold.md producer-exit failed

set +e
elapsed_failure_output="$(run_profile elapsed-failure.md env FAKE_ELAPSED_MS=5001 2>&1)"
elapsed_failure_status=$?
set -e
[[ "${elapsed_failure_status}" -ne 0 ]]
[[ "${elapsed_failure_output}" != *"${raw_serial}"* ]]
[[ "${elapsed_failure_output}" != *'M1 throughput evidence passed'* ]]
expect_diagnostic elapsed-failure.md wrapper-contract passed

set +e
overflow_elapsed_output="$(
  run_profile overflow-elapsed.md env FAKE_ELAPSED_MS=9223372036854775808 2>&1
)"
overflow_elapsed_status=$?
set -e
[[ "${overflow_elapsed_status}" -ne 0 ]]
[[ "${overflow_elapsed_output}" != *'M1 throughput evidence passed'* ]]
expect_diagnostic overflow-elapsed.md wrapper-contract passed

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
expect_diagnostic cleanup-failure.md cleanup passed

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

# A hard-link publication is not a successful command until its staging link is
# removed. Leave the published target untouched, return nonzero, and let the
# operator inspect it rather than deleting a path that could race another writer.
set +e
staged_rm_output="$(run_profile staged-rm-failure.md env FAKE_RM_STAGED_FAILURE=1 2>&1)"
staged_rm_status=$?
set -e
[[ "${staged_rm_status}" -eq 1 ]]
[[ "${staged_rm_output}" == *'could not remove the staged evidence link after publication'* \
    && "${staged_rm_output}" != *'M1 throughput evidence passed'* ]]
[[ -s "${test_repo}/fixtures/m1-runs/staged-rm-failure.md" ]]
staged_rm_path="$(find "${test_repo}/fixtures/m1-runs" \
  -maxdepth 1 -type f -name '.throughput-evidence.*' -print -quit)"
[[ -n "${staged_rm_path}" ]]
"${real_rm}" -f \
  "${test_repo}/fixtures/m1-runs/staged-rm-failure.md" \
  "${staged_rm_path}"

set +e
advance_failure_output="$(run_profile advanced-main.md env FAKE_ADVANCE_REMOTE=1 2>&1)"
advance_failure_status=$?
set -e
[[ "${advance_failure_status}" -ne 0 ]]
[[ "${advance_failure_output}" != *"${raw_serial}"* ]]
[[ "${advance_failure_output}" != *'M1 throughput evidence passed'* ]]
expect_diagnostic advanced-main.md post-run-provenance passed

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
