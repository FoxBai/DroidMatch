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
runner_args="${test_root}/runner-args"
adb_calls="${test_root}/adb-calls"
cleanup_marker="${test_root}/cleanup-called"
raw_serial="RAW-SERIAL-DO-NOT-LEAK"

git init --bare -q "${remote_repo}"
git init -q "${test_repo}"
git -C "${test_repo}" config user.name 'DroidMatch Offline Test'
git -C "${test_repo}" config user.email 'offline-test@droidmatch.invalid'
mkdir -p "${test_repo}/tools" "${test_repo}/fixtures/m1-runs" "${private_tmp}"
cp "${source_wrapper}" "${test_repo}/tools/run-m1-throughput-gate.sh"
cp "${source_checker}" "${test_repo}/tools/check-m1-run-logs.sh"
chmod +x "${test_repo}/tools/"*.sh

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
first list time: 42 ms for \`dm://media-images/\` (max 1000 ms)
100MB download: fresh exact test
100MB upload: fresh exact test
resume result: not run
permission cases: not run
diagnostics bundle: fake offline runner
notes:

- serial redaction tag: \`<serial-redacted:offline>\`
EOF_LOG

if [[ "${FAKE_SENSITIVE_LOG:-0}" == 1 ]]; then
  printf '%s\n' 'private path: /Users/private/secret-file' >>"${result_log}"
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
)

# Profile validation is conditional: mutating a strict field must fail without
# changing the legacy global field contract.
sed 's/profile upload observed mib per second: 25.00/profile upload observed mib per second: 19.99/' \
  "${valid_log}" >"${test_repo}/fixtures/m1-runs/invalid.md"
if (cd "${test_repo}" && bash tools/check-m1-run-logs.sh >/dev/null 2>&1); then
  printf '%s\n' 'profile validator accepted sub-threshold upload evidence' >&2
  exit 1
fi
rm "${test_repo}/fixtures/m1-runs/invalid.md"

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

# Remove the published evidence so the repository returns to its required clean
# provenance before each negative wrapper case.
rm "${valid_log}"

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
