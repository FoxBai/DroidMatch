#!/usr/bin/env bash

set -euo pipefail
umask 077

# Only explicit, privacy-bounded diagnostics use the original stderr. Tool
# failures stay private so remote URLs, serial-bearing arguments, and temporary
# paths cannot escape through an otherwise allowlisted evidence command.
exec 3>&2
exec 2>/dev/null

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

readonly profile="m1-adb-throughput-v1"
readonly exact_bytes=104857600
readonly chunk_bytes=1048576
readonly minimum_mib_per_second=20
readonly maximum_transfer_elapsed_ms=5000
readonly remote_port=39001

serial=""
expected_main_sha=""
adb_bin="${DROIDMATCH_ADB:-}"
result_log=""

usage() {
  printf '%s\n' \
    'Run the fail-closed current-main ADB throughput evidence profile.' \
    '' \
    'Usage:' \
    '  tools/run-m1-throughput-gate.sh --serial <adb-serial> --expected-main-sha <40-hex> [options]' \
    '' \
    'Options:' \
    '  --adb <path>          adb executable; otherwise use DROIDMATCH_ADB or SDK discovery.' \
    '  --result-log <path>   Final repository-relative log under fixtures/m1-runs/.' \
    '  -h, --help            Show this help.' \
    '' \
    'The profile requires a clean HEAD equal to the freshly fetched origin/main and' \
    'the caller-provided full SHA. It always rebuilds, requests and negotiates 1 MiB' \
    'chunks, transfers exactly 100 MiB in both directions, requires >=20 MiB/s,' \
    'records a same-source raw ADB baseline, and verifies cleanup before publishing' \
    'a passing log. It never guesses a device and never prints the raw serial.' \
    '' \
    '中文：该 profile 要求 clean HEAD、最新 origin/main 与调用方提供的完整 SHA' \
    '完全一致；固定重建并验证双向精确 100 MiB、请求/协商 1 MiB chunk、双向' \
    '>=20 MiB/s、同源 ADB baseline，且只在清理验证后发布通过日志。'
}

fail() {
  printf 'throughput evidence refused: %s\n' "$1" >&3
  exit 1
}

usage_error() {
  printf 'throughput evidence refused: invalid or incomplete option.\n' >&3
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) [[ $# -ge 2 ]] || usage_error; serial="$2"; shift 2 ;;
    --expected-main-sha) [[ $# -ge 2 ]] || usage_error; expected_main_sha="$2"; shift 2 ;;
    --adb) [[ $# -ge 2 ]] || usage_error; adb_bin="$2"; shift 2 ;;
    --result-log) [[ $# -ge 2 ]] || usage_error; result_log="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error ;;
  esac
done

serial_tag_for() {
  printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 8)}'
}

resolve_adb() {
  if [[ -n "${adb_bin}" ]]; then
    return
  fi
  if command -v adb >/dev/null 2>&1; then
    adb_bin="$(command -v adb)"
    return
  fi
  local candidate
  for candidate in \
    "${ANDROID_HOME:-}/platform-tools/adb" \
    "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
    "${HOME}/Library/Android/sdk/platform-tools/adb"; do
    if [[ -x "${candidate}" ]]; then
      adb_bin="${candidate}"
      return
    fi
  done
}

[[ -n "${serial}" ]] || fail '--serial is required; this evidence profile never guesses a device.'
[[ "${#serial}" -ge 6 ]] || fail '--serial must contain at least six characters.'
[[ "${serial}" =~ ^[A-Za-z0-9._:-]+$ ]] \
  || fail '--serial contains unsupported characters.'
[[ "${expected_main_sha}" =~ ^[0-9a-f]{40}$ ]] \
  || fail '--expected-main-sha must be a lowercase 40-hex commit.'
for command_name in git shasum awk perl dd mktemp wc tr sort cp ln rm mkdir date; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "required command is unavailable: ${command_name}"
done
resolve_adb
[[ -n "${adb_bin}" && -x "${adb_bin}" ]] || fail 'adb executable was not found.'

# Evidence must name the remote revision the operator actually reviewed. Fetching
# here closes the gap between a stale local origin/main and the asserted current tip.
GIT_TERMINAL_PROMPT=0 git fetch --quiet origin \
  refs/heads/main:refs/remotes/origin/main \
  || fail 'could not refresh origin/main.'
head_sha="$(git rev-parse HEAD 2>/dev/null)" || fail 'HEAD is unavailable.'
origin_main_sha="$(git rev-parse refs/remotes/origin/main 2>/dev/null)" \
  || fail 'origin/main is unavailable.'
[[ "${head_sha}" == "${expected_main_sha}" ]] \
  || fail 'HEAD does not match --expected-main-sha.'
[[ "${origin_main_sha}" == "${expected_main_sha}" ]] \
  || fail 'origin/main does not match --expected-main-sha.'
pre_run_git_status="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null)" \
  || fail 'could not verify the pre-run worktree state.'
[[ -z "${pre_run_git_status}" ]] || fail 'the worktree is not clean.'

device_state="$("${adb_bin}" -s "${serial}" get-state 2>/dev/null || true)"
[[ "${device_state//$'\r'/}" == "device" ]] \
  || fail 'the selected redacted device is not in adb device state.'

run_started_utc="$(date -u '+%Y-%m-%d %H:%M:%SZ')"
run_slug="$(date -u '+%Y-%m-%dT%H-%M-%SZ')"
serial_tag="$(serial_tag_for "${serial}")"
serial_label="<serial-redacted:${serial_tag}>"
if [[ -z "${result_log}" ]]; then
  result_log="fixtures/m1-runs/${run_slug}-adb-${serial_tag}.md"
fi
[[ "${result_log}" =~ ^fixtures/m1-runs/[A-Za-z0-9._-]+[.]md$ ]] \
  || fail '--result-log must be a simple repository-relative Markdown path under fixtures/m1-runs/.'
[[ ! -e "${result_log}" ]] || fail 'the requested result log already exists.'
if ! forward_snapshot_before="$("${adb_bin}" forward --list 2>/dev/null \
    | awk -v serial="${serial}" '$1 == serial { print }' | LC_ALL=C sort)"; then
  fail 'could not snapshot the selected device ADB forwards.'
fi
if awk -v remote="tcp:${remote_port}" '$3 == remote { found = 1 } END { exit !found }' \
    <<<"${forward_snapshot_before}"; then
  fail 'the selected device already has a forward to the profile remote port.'
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-throughput-evidence.XXXXXX")" \
  || fail 'could not create a private evidence workspace.'
runner_log="${work}/runner-result.md"
runner_output="${work}/runner-output.txt"
upload_source="${work}/upload-source.bin"
download_destination="${work}/download.bin"
remote_nonce="${work##*.}"
remote_stem="dm-slot-a-${run_slug}-${serial_tag}-$$-${remote_nonce}"
prepared_name="${remote_stem}-source.bin"
upload_name="${remote_stem}-upload.bin"
upload_destination="dm://app-sandbox/${upload_name}"
local_port=""
cleanup_verified=0
remote_artifacts_owned=0
staged_log=""

remove_remote_artifacts() {
  local path
  for path in \
    "files/droidmatch-sandbox/${prepared_name}" \
    "files/droidmatch-sandbox/${upload_name}" \
    "files/droidmatch-sandbox/.${upload_name}.droidmatch-upload-part"; do
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch rm -f "${path}" \
      >/dev/null 2>&1 || return 1
  done
}

verify_remote_artifacts_absent() {
  local path
  for path in \
    "files/droidmatch-sandbox/${prepared_name}" \
    "files/droidmatch-sandbox/${upload_name}" \
    "files/droidmatch-sandbox/.${upload_name}.droidmatch-upload-part"; do
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch test ! -e "${path}" \
      >/dev/null 2>&1 || return 1
  done
}

remove_and_verify_forward() {
  local forward_snapshot_after
  [[ -n "${local_port}" ]] || return 1
  "${adb_bin}" -s "${serial}" forward --remove "tcp:${local_port}" >/dev/null 2>&1 || true
  forward_snapshot_after="$("${adb_bin}" forward --list 2>/dev/null \
    | awk -v serial="${serial}" '$1 == serial { print }' | LC_ALL=C sort)"
  [[ "${forward_snapshot_after}" == "${forward_snapshot_before}" ]]
}

remove_and_verify_local_artifacts() {
  local path
  rm -f \
    "${download_destination}" \
    "${download_destination}.droidmatch-part" \
    "${download_destination}.droidmatch-transfer.json" \
    "${upload_source}" \
    "${upload_source}.droidmatch-upload-transfer.json" || return 1
  for path in \
    "${download_destination}" \
    "${download_destination}.droidmatch-part" \
    "${download_destination}.droidmatch-transfer.json" \
    "${upload_source}" \
    "${upload_source}.droidmatch-upload-transfer.json"; do
    [[ ! -e "${path}" ]] || return 1
  done
}

best_effort_cleanup() {
  if [[ "${remote_artifacts_owned}" -eq 1 ]]; then
    remove_remote_artifacts || true
  fi
  if [[ -n "${local_port}" ]]; then
    "${adb_bin}" -s "${serial}" forward --remove "tcp:${local_port}" >/dev/null 2>&1 || true
  fi
  rm -f \
    "${download_destination}" \
    "${download_destination}.droidmatch-part" \
    "${download_destination}.droidmatch-transfer.json" \
    "${upload_source}" \
    "${upload_source}.droidmatch-upload-transfer.json" >/dev/null 2>&1 || true
}

cleanup() {
  if [[ "${cleanup_verified}" -ne 1 ]]; then
    best_effort_cleanup
  fi
  if [[ -n "${staged_log}" ]]; then
    rm -f "${staged_log}" >/dev/null 2>&1 || true
  fi
  rm -rf "${work}"
}
trap cleanup EXIT

dd if=/dev/zero of="${upload_source}" bs=1048576 count=100 status=none \
  || fail 'could not create the managed 100 MiB upload source.'
[[ "$(wc -c < "${upload_source}" | tr -d ' ')" == "${exact_bytes}" ]] \
  || fail 'managed upload source is not exactly 100 MiB.'

sdk_int="$("${adb_bin}" -s "${serial}" shell getprop ro.build.version.sdk 2>/dev/null \
  | tr -d '\r[:space:]')"
[[ "${sdk_int}" =~ ^(26|27|28|29)$ ]] \
  || fail 'the selected redacted device is not in the required Slot A API 26-29 range.'

set +e
env \
  -u DROIDMATCH_SERIAL \
  -u DROIDMATCH_ANDROID_PORT \
  -u DROIDMATCH_LOCAL_PORT \
  -u DROIDMATCH_SMOKE_TIMEOUT_SECONDS \
  -u DROIDMATCH_DEVICE_SLOT \
  -u DROIDMATCH_RESULT_LOG \
  -u DROIDMATCH_RUN_NOTES \
  -u DROIDMATCH_RESUME_PARTIAL_BYTES \
  -u DROIDMATCH_UPLOAD_PARTIAL_BYTES \
  -u DROIDMATCH_MAX_RETRY_ATTEMPTS \
  -u DROIDMATCH_RETRY_BACKOFF_MS \
  -u DROIDMATCH_MIN_DOWNLOAD_BYTES \
  -u DROIDMATCH_MIN_DOWNLOAD_MIB_PER_SECOND \
  -u DROIDMATCH_MIN_UPLOAD_BYTES \
  -u DROIDMATCH_MIN_UPLOAD_MIB_PER_SECOND \
  -u DROIDMATCH_UPLOAD_SOURCE_FILE \
  -u DROIDMATCH_UPLOAD_DESTINATION_PATH \
  -u DROIDMATCH_TRANSFER_CHUNK_SIZE_BYTES \
  -u DROIDMATCH_PREPARE_APP_SANDBOX_FILE \
  -u DROIDMATCH_PREPARE_APP_SANDBOX_BYTES \
  -u DROIDMATCH_HANDSHAKE_ATTEMPTS \
  -u DROIDMATCH_MIN_HANDSHAKE_PASSES \
  -u DROIDMATCH_LIST_PATH \
  -u DROIDMATCH_MAX_LIST_MS \
  -u DROIDMATCH_LIST_EXPECT_ERROR_PATH \
  -u DROIDMATCH_LIST_EXPECT_ERROR_CODE \
  -u DROIDMATCH_LIST_EXPECT_ERROR_MESSAGE_CONTAINS \
  -u DROIDMATCH_MEDIA_PERMISSION_REVOKED_CHECK \
  -u DROIDMATCH_MEDIA_PERMISSION_REVOKED_DURING_DOWNLOAD_CHECK \
  -u DROIDMATCH_ADB_BASELINE_DOWNLOAD_CHECK \
  -u DROIDMATCH_DOWNLOAD_RESUME_SOURCE_MUTATION_CHECK \
  -u DROIDMATCH_DOWNLOAD_RESUME_SOURCE_DELETION_CHECK \
  -u DROIDMATCH_DOWNLOAD_RESUME_SOURCE_REPLACEMENT_CHECK \
  -u DROIDMATCH_DUAL_DOWNLOAD_CHECK \
  -u DROIDMATCH_MIXED_TRANSFER_CHECK \
  -u DROIDMATCH_MIXED_UPLOAD_DESTINATION_PATH \
  -u DROIDMATCH_DOWNLOAD_OPEN_EXPECT_ERROR_PATH \
  -u DROIDMATCH_DOWNLOAD_OPEN_EXPECT_ERROR_CODE \
  -u DROIDMATCH_DOWNLOAD_OPEN_EXPECT_ERROR_MESSAGE_CONTAINS \
  DROIDMATCH_ADB="${adb_bin}" bash "${repo_root}/tools/run-m1-device-smoke.sh" \
  --serial "${serial}" \
  --device-slot A \
  --notes "${profile}; expected origin/main ${expected_main_sha}" \
  --handshake-attempts 20 \
  --min-handshake-passes 19 \
  --list-path dm://media-images/ \
  --max-list-ms 1000 \
  --prepare-app-sandbox-file "${prepared_name}" \
  --prepare-app-sandbox-bytes "${exact_bytes}" \
  --require-disposable-app-sandbox-paths \
  --adb-baseline-download-check \
  --destination "${download_destination}" \
  --min-download-bytes "${exact_bytes}" \
  --min-download-mib-per-second "${minimum_mib_per_second}" \
  --chunk-size-bytes "${chunk_bytes}" \
  --upload-source "${upload_source}" \
  --upload-destination-path "${upload_destination}" \
  --min-upload-bytes "${exact_bytes}" \
  --min-upload-mib-per-second "${minimum_mib_per_second}" \
  --result-log "${runner_log}" >"${runner_output}" 2>&1
runner_status=$?
set -e

local_port="$(sed -n 's/.*local_port=\([0-9][0-9]*\).*/\1/p' "${runner_output}" | tail -1)"
if grep -Fqx 'disposable app-sandbox paths reserved' "${runner_output}"; then
  remote_artifacts_owned=1
fi
if [[ "${runner_status}" -ne 0 ]]; then
  fail "underlying device runner failed with status ${runner_status}; private output was withheld and cleanup remains best effort."
fi
[[ "${remote_artifacts_owned}" -eq 1 ]] \
  || fail 'the underlying runner did not reserve fresh disposable app-sandbox paths.'
[[ -s "${runner_log}" ]] || fail 'the underlying runner did not produce a result log.'

field_from_line() {
  local line="$1" key="$2"
  awk -v key="${key}" '{
    for (field_index = 1; field_index <= NF; field_index++) {
      split($field_index, pair, "=")
      if (pair[1] == key) { print pair[2]; exit }
    }
  }' <<<"${line}"
}

require_exact_line() {
  local prefix="$1" count
  count="$(grep -c "^${prefix}" "${runner_output}" || true)"
  [[ "${count}" == "1" ]] || fail "expected exactly one ${prefix} result line."
  grep "^${prefix}" "${runner_output}"
}

download_line="$(require_exact_line 'download passed ')"
upload_line="$(require_exact_line 'upload passed ')"
baseline_line="$(require_exact_line 'adb baseline download passed ')"

download_bytes="$(field_from_line "${download_line}" bytes)"
download_total="$(field_from_line "${download_line}" total)"
download_final_offset="$(field_from_line "${download_line}" final_offset)"
download_requested_chunk="$(field_from_line "${download_line}" requested_chunk_size_bytes)"
download_negotiated_chunk="$(field_from_line "${download_line}" chunk_size_bytes)"
download_throughput="$(field_from_line "${download_line}" throughput_mib_per_sec)"
download_elapsed_ms="$(field_from_line "${download_line}" elapsed_ms)"
download_chunks="$(field_from_line "${download_line}" chunks)"
download_resume="$(field_from_line "${download_line}" resume)"
download_retry_attempts="$(field_from_line "${download_line}" retry_attempts)"
download_recovered="$(field_from_line "${download_line}" recovered)"
upload_bytes="$(field_from_line "${upload_line}" bytes)"
upload_total="$(field_from_line "${upload_line}" total)"
upload_final_offset="$(field_from_line "${upload_line}" final_offset)"
upload_requested_chunk="$(field_from_line "${upload_line}" requested_chunk_size_bytes)"
upload_negotiated_chunk="$(field_from_line "${upload_line}" chunk_size_bytes)"
upload_throughput="$(field_from_line "${upload_line}" throughput_mib_per_sec)"
upload_elapsed_ms="$(field_from_line "${upload_line}" elapsed_ms)"
upload_chunks="$(field_from_line "${upload_line}" chunks)"
upload_resume="$(field_from_line "${upload_line}" resume)"
upload_retry_attempts="$(field_from_line "${upload_line}" retry_attempts)"
upload_recovered="$(field_from_line "${upload_line}" recovered)"
baseline_bytes="$(field_from_line "${baseline_line}" bytes)"
baseline_expected_bytes="$(field_from_line "${baseline_line}" expected_bytes)"
baseline_elapsed_ms="$(field_from_line "${baseline_line}" elapsed_ms)"
baseline_throughput="$(field_from_line "${baseline_line}" throughput_mib_per_sec)"

for value in \
  "${download_bytes}" "${download_total}" "${download_final_offset}" \
  "${upload_bytes}" "${upload_total}" "${upload_final_offset}" \
  "${baseline_bytes}" "${baseline_expected_bytes}"; do
  [[ "${value}" == "${exact_bytes}" ]] || fail 'a transfer or baseline byte count is not exactly 100 MiB.'
done
for value in "${download_chunks}" "${upload_chunks}"; do
  [[ "${value}" == "100" ]] || fail 'a 100 MiB transfer did not use exactly 100 negotiated 1 MiB chunks.'
done
for value in "${download_elapsed_ms}" "${upload_elapsed_ms}"; do
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] \
    || fail 'a transfer elapsed_ms field is missing or non-positive.'
  awk -v value="${value}" -v maximum="${maximum_transfer_elapsed_ms}" \
    'BEGIN { exit !(value <= maximum) }' \
      || fail 'exact 100 MiB transfer elapsed time exceeds the 20 MiB/s boundary.'
done
[[ "${download_resume}" == "false" && "${upload_resume}" == "false" \
    && "${download_retry_attempts}" == "1" && "${upload_retry_attempts}" == "1" \
    && "${download_recovered}" == "false" && "${upload_recovered}" == "false" ]] \
  || fail 'the profile requires fresh, single-attempt, non-recovered transfers.'
for value in \
  "${download_requested_chunk}" "${download_negotiated_chunk}" \
  "${upload_requested_chunk}" "${upload_negotiated_chunk}"; do
  [[ "${value}" == "${chunk_bytes}" ]] || fail 'requested and negotiated chunk sizes are not both exactly 1 MiB.'
done
[[ "${baseline_elapsed_ms}" =~ ^[1-9][0-9]*$ ]] || fail 'ADB baseline elapsed_ms is missing or non-positive.'
for value in "${download_throughput}" "${upload_throughput}" "${baseline_throughput}"; do
  [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail 'a throughput field is missing or malformed.'
done
awk -v value="${download_throughput}" -v minimum="${minimum_mib_per_second}" \
  'BEGIN { exit !(value >= minimum) }' || fail 'download throughput is below 20 MiB/s.'
awk -v value="${upload_throughput}" -v minimum="${minimum_mib_per_second}" \
  'BEGIN { exit !(value >= minimum) }' || fail 'upload throughput is below 20 MiB/s.'

for base_field in \
  'status:' 'date:' 'device slot:' 'manufacturer/model:' 'android version/api:' \
  'build channel:' 'transport:' 'handshake attempts:' 'visible time:' \
  'first list time:' '100MB download:' '100MB upload:' 'resume result:' \
  'permission cases:' 'diagnostics bundle:' 'notes:'; do
  [[ "$(grep -c "^${base_field}" "${runner_log}" || true)" == "1" ]] \
    || fail 'the underlying result contains a missing or ambiguous base field.'
done
[[ "$(grep -c '^status:' "${runner_log}" || true)" == "1" \
    && "$(grep -Fxc 'status: passed' "${runner_log}" || true)" == "1" ]] \
  || fail 'the underlying result does not contain one unambiguous passed status.'
[[ "$(grep -c '^device slot:' "${runner_log}" || true)" == "1" \
    && "$(grep -Fxc 'device slot: A' "${runner_log}" || true)" == "1" ]] \
  || fail 'the underlying result does not contain one unambiguous Slot A field.'
[[ "$(grep -c '^build channel:' "${runner_log}" || true)" == "1" ]] \
  || fail 'the underlying result does not contain one build channel.'
runner_build_sha="$(sed -n 's/^build channel: local release Swift harness [+] debug APK from git \([0-9a-f][0-9a-f]*\)$/\1/p' "${runner_log}")"
[[ "${runner_build_sha}" =~ ^[0-9a-f]{7,40}$ \
    && "${head_sha}" == "${runner_build_sha}"* ]] \
  || fail 'the underlying result does not identify the expected release harness revision.'
[[ "$(grep -c '^android version/api:' "${runner_log}" || true)" == "1" ]] \
  || fail 'the underlying result does not contain one Android API field.'
runner_api="$(sed -n 's/^android version\/api: .* API \([0-9][0-9]*\)$/\1/p' "${runner_log}")"
[[ "${runner_api}" == "${sdk_int}" ]] \
  || fail 'the underlying result Android API does not match the selected device.'
[[ "$(grep -c '^handshake attempts:' "${runner_log}" || true)" == "1" \
    && "$(grep -Fxc 'handshake attempts: 20/20 passed via `m1-smoke` (minimum 19)' "${runner_log}" || true)" == "1" ]] \
  || fail 'the 20-attempt handshake contract was not satisfied.'
list_elapsed_ms="$(sed -n 's/^first list time: \([0-9][0-9]*\) ms .*/\1/p' "${runner_log}")"
[[ "${list_elapsed_ms}" =~ ^[0-9]+$ ]] || fail 'warm list elapsed time is missing.'
awk -v value="${list_elapsed_ms}" 'BEGIN { exit !(value <= 1000) }' \
  || fail 'warm list elapsed time exceeds 1000 ms.'

[[ -f "${download_destination}" ]] || fail 'the committed local download is missing.'
[[ "$(wc -c < "${download_destination}" | tr -d ' ')" == "${exact_bytes}" ]] \
  || fail 'the committed local download is not exactly 100 MiB.'
remote_upload_bytes="$("${adb_bin}" -s "${serial}" shell run-as app.droidmatch stat -c %s \
  "files/droidmatch-sandbox/${upload_name}" 2>/dev/null | tr -d '\r[:space:]' || true)"
[[ "${remote_upload_bytes}" == "${exact_bytes}" ]] \
  || fail 'the committed remote upload is not exactly 100 MiB.'
"${adb_bin}" -s "${serial}" shell run-as app.droidmatch test ! -e \
  "files/droidmatch-sandbox/.${upload_name}.droidmatch-upload-part" \
  >/dev/null 2>&1 || fail 'a hidden upload partial remains after successful commit.'

remove_remote_artifacts || fail 'remote disposable artifact cleanup failed.'
verify_remote_artifacts_absent || fail 'remote disposable artifacts remain after cleanup.'
remove_and_verify_forward || fail 'the owned ADB forward remains after cleanup.'
remove_and_verify_local_artifacts || fail 'managed local artifacts remain after cleanup.'
cleanup_verified=1

GIT_TERMINAL_PROMPT=0 git fetch --quiet origin \
  refs/heads/main:refs/remotes/origin/main \
  || fail 'could not refresh origin/main after the device run.'
post_head_sha="$(git rev-parse HEAD 2>/dev/null)" || fail 'post-run HEAD is unavailable.'
post_origin_main_sha="$(git rev-parse refs/remotes/origin/main 2>/dev/null)" \
  || fail 'post-run origin/main is unavailable.'
[[ "${post_head_sha}" == "${expected_main_sha}" \
    && "${post_origin_main_sha}" == "${expected_main_sha}" ]] \
  || fail 'repository provenance changed during the run.'
post_run_git_status="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null)" \
  || fail 'could not verify the post-run worktree state.'
[[ -z "${post_run_git_status}" ]] || fail 'the worktree changed during the run.'

mkdir -p "$(dirname "${result_log}")" \
  || fail 'could not prepare the evidence-log directory.'
staged_log="$(mktemp "$(dirname "${result_log}")/.throughput-evidence.XXXXXX")" \
  || fail 'could not stage the evidence log.'
cp "${runner_log}" "${staged_log}" || fail 'could not stage the private runner result.'
{
  printf '\n'
  printf 'evidence profile: %s\n' "${profile}"
  printf 'profile result: passed\n'
  printf 'profile source revision: %s\n' "${head_sha}"
  printf 'profile expected main revision: %s\n' "${expected_main_sha}"
  printf 'profile origin main revision: %s\n' "${origin_main_sha}"
  printf 'profile handshake attempts: 20\n'
  printf 'profile handshake passed: 20\n'
  printf 'profile handshake minimum: 19\n'
  printf 'profile warm list elapsed ms: %s\n' "${list_elapsed_ms}"
  printf 'profile warm list maximum ms: 1000\n'
  printf 'profile adb baseline bytes: %s\n' "${baseline_bytes}"
  printf 'profile adb baseline elapsed ms: %s\n' "${baseline_elapsed_ms}"
  printf 'profile adb baseline throughput mib per second: %s\n' "${baseline_throughput}"
  printf 'profile download bytes: %s\n' "${download_bytes}"
  printf 'profile download mode: fresh\n'
  printf 'profile download chunks: %s\n' "${download_chunks}"
  printf 'profile download requested chunk bytes: %s\n' "${download_requested_chunk}"
  printf 'profile download negotiated chunk bytes: %s\n' "${download_negotiated_chunk}"
  printf 'profile download minimum mib per second: %s\n' "${minimum_mib_per_second}"
  printf 'profile download observed mib per second: %s\n' "${download_throughput}"
  printf 'profile download elapsed ms: %s\n' "${download_elapsed_ms}"
  printf 'profile upload bytes: %s\n' "${upload_bytes}"
  printf 'profile upload mode: fresh\n'
  printf 'profile upload chunks: %s\n' "${upload_chunks}"
  printf 'profile upload requested chunk bytes: %s\n' "${upload_requested_chunk}"
  printf 'profile upload negotiated chunk bytes: %s\n' "${upload_negotiated_chunk}"
  printf 'profile upload minimum mib per second: %s\n' "${minimum_mib_per_second}"
  printf 'profile upload observed mib per second: %s\n' "${upload_throughput}"
  printf 'profile upload elapsed ms: %s\n' "${upload_elapsed_ms}"
  printf 'profile cleanup remote prepared source: absent\n'
  printf 'profile cleanup remote upload final: absent\n'
  printf 'profile cleanup remote upload partial: absent\n'
  printf 'profile cleanup local transfer artifacts: absent\n'
  printf 'profile cleanup adb forward: absent\n'
  printf 'profile cleanup verified before pass: true\n'
} >>"${staged_log}" || fail 'could not append the strict evidence profile.'

scan_status=0
grep -Fq -- "${serial}" "${staged_log}" || scan_status=$?
case "${scan_status}" in
  0) rm -f "${staged_log}"; fail 'raw serial crossed the evidence-log boundary.' ;;
  1) ;;
  *) rm -f "${staged_log}"; fail 'could not scan the staged log for the raw serial.' ;;
esac
scan_status=0
grep -Eiq '/Users/|/home/[^/[:space:]]+/|content://|Authorization:|Bearer[[:space:]]+|access[_-]?token|refresh[_-]?token|password|secret|(^|[^[:alnum:]_])(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,})' "${staged_log}" \
  || scan_status=$?
case "${scan_status}" in
  0) rm -f "${staged_log}"; fail 'sensitive-looking content crossed the evidence-log boundary.' ;;
  1) ;;
  *) rm -f "${staged_log}"; fail 'could not privacy-scan the staged evidence log.' ;;
esac
bash tools/check-m1-run-logs.sh --log "${staged_log}" >/dev/null \
  || fail 'the staged evidence log failed strict profile validation.'
ln -n "${staged_log}" "${result_log}" \
  || fail 'could not publish the evidence log without overwriting an existing file.'
if ! rm -f "${staged_log}"; then
  fail 'could not remove the staged evidence link after publication.'
fi
staged_log=""

printf 'M1 throughput evidence passed profile=%s serial=%s result_log=%s download_mib_per_sec=%s upload_mib_per_sec=%s baseline_mib_per_sec=%s\n' \
  "${profile}" "${serial_label}" "${result_log}" \
  "${download_throughput}" "${upload_throughput}" "${baseline_throughput}"
