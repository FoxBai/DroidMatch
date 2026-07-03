#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

serial="${DROIDMATCH_SERIAL:-}"
remote_port="${DROIDMATCH_ANDROID_PORT:-39001}"
local_port="${DROIDMATCH_LOCAL_PORT:-0}"
timeout_seconds="${DROIDMATCH_SMOKE_TIMEOUT_SECONDS:-10}"
result_log="${DROIDMATCH_RESULT_LOG:-}"
device_slot="${DROIDMATCH_DEVICE_SLOT:-unclassified}"
notes="${DROIDMATCH_RUN_NOTES:-}"
resume_partial_bytes="${DROIDMATCH_RESUME_PARTIAL_BYTES:-1}"
upload_partial_bytes="${DROIDMATCH_UPLOAD_PARTIAL_BYTES:-1}"
min_download_bytes="${DROIDMATCH_MIN_DOWNLOAD_BYTES:-0}"
min_upload_bytes="${DROIDMATCH_MIN_UPLOAD_BYTES:-0}"
prepare_app_sandbox_file="${DROIDMATCH_PREPARE_APP_SANDBOX_FILE:-}"
prepare_app_sandbox_bytes="${DROIDMATCH_PREPARE_APP_SANDBOX_BYTES:-104857600}"
handshake_attempts="${DROIDMATCH_HANDSHAKE_ATTEMPTS:-1}"
min_handshake_passes="${DROIDMATCH_MIN_HANDSHAKE_PASSES:-}"
list_path="${DROIDMATCH_LIST_PATH:-}"
skip_build=0
download_source_path=""
download_destination=""
upload_source_file="${DROIDMATCH_UPLOAD_SOURCE_FILE:-}"
upload_destination_path="${DROIDMATCH_UPLOAD_DESTINATION_PATH:-}"
cleanup_upload_destination=0
open_launcher=0
record_log=1
resume_check=0
cancel_check=0
pause_check=0
upload_resume_check=0
upload_resume_unsupported_check=0
keep_prepared_app_sandbox_file=0
final_status="passed"
failure_stage=""
failure_output=""
allocated_local_port=""
install_output=""
launcher_output=""
activity_output=""
forward_output=""
m1_smoke_output=""
m1_smoke_passes=0
m1_smoke_failures=0
list_time_ms=""
list_output=""
partial_download_output=""
resume_download_output=""
download_output=""
cancel_download_output=""
pause_download_output=""
upload_output=""
partial_upload_output=""
resume_upload_output=""
upload_resume_unsupported_output=""
download_bytes_received=""
upload_bytes_sent=""
prepare_app_sandbox_output=""
prepared_app_sandbox_source_path=""
prepared_app_sandbox_created=0

usage() {
  cat <<'USAGE'
Run the M1 debug APK on one adb-visible Android device and execute the Mac smoke harness.

Usage:
  tools/run-m1-device-smoke.sh [options]

Options:
  --serial <serial>              adb device serial. Required when multiple devices are ready.
  --remote-port <port>           Android endpoint port. Default: 39001.
  --local-port <port>            Mac forward port, or 0 for adb-allocated. Default: 0.
  --timeout-seconds <seconds>    Harness TCP timeout. Default: 10.
  --handshake-attempts <count>   Number of m1-smoke attempts to run. Default: 1.
  --min-handshake-passes <count> Minimum successful m1-smoke attempts. Default: handshake-attempts.
  --list-path <dm-path>          Optional logical path to list and time after m1-smoke.
  --source-path <dm-path>        Optional logical path to download after m1-smoke.
  --destination <path>           Destination for --source-path download.
  --resume-check                 Run a partial download, then resume it. Requires --source-path.
  --cancel-check                 Open a download transfer, read one chunk, then cancel it. Requires --source-path.
  --pause-check                  Open a download transfer, read one chunk, then pause it. Requires --source-path.
  --upload-source <path>         Local file to upload after m1-smoke.
  --upload-destination-path <dm-path>
                                  Logical DroidMatch destination for --upload-source.
  --upload-resume-check          Run a partial upload, then resume it. Requires upload source/destination.
  --upload-resume-unsupported-check
                                  Open a non-zero-offset upload and require unsupported-capability.
                                  Intended for fresh-only MediaStore or SAF destinations.
  --upload-partial-bytes <bytes> Bytes to upload before the intentional partial stop. Default: 1.
  --min-upload-bytes <bytes>     Require uploaded bytes to be at least this value.
  --cleanup-upload-destination   Remove uploaded app-sandbox or single-file MediaStore destination on exit.
                                  SAF upload cleanup is not supported by this script.
  --partial-bytes <bytes>        Bytes to write before the intentional partial stop. Default: 1.
  --min-download-bytes <bytes>   Require full/resume download bytes to be at least this value.
  --prepare-app-sandbox-file <name>
                                  Create an app-private zero-filled file before smoke.
  --prepare-app-sandbox-bytes <bytes>
                                  Size for --prepare-app-sandbox-file. Default: 104857600.
  --keep-prepared-app-sandbox-file
                                  Do not remove the prepared app sandbox file on exit.
  --device-slot <slot>           M1 matrix slot label for the result log. Default: unclassified.
  --notes <text>                 Notes to include in the result log.
  --result-log <path>            Result log path. Default: fixtures/m1-runs/<timestamp>-adb-<serial-hash>.md.
  --no-result-log                Do not write a result log.
  --open-launcher                Also launch the app through the launcher entry after install.
  --skip-build                   Use the existing debug APK instead of running check-m1-skeleton.
  -h, --help                     Show this help.

Environment:
  DROIDMATCH_ADB                 adb executable path.
  DROIDMATCH_SERIAL              Default serial.
  DROIDMATCH_ANDROID_PORT        Default remote port.
  DROIDMATCH_LOCAL_PORT          Default local port.
  DROIDMATCH_SMOKE_TIMEOUT_SECONDS
  DROIDMATCH_DEVICE_SLOT         Default matrix slot label.
  DROIDMATCH_RESULT_LOG          Default result log path.
  DROIDMATCH_RUN_NOTES           Default result log notes.
  DROIDMATCH_RESUME_PARTIAL_BYTES
  DROIDMATCH_UPLOAD_PARTIAL_BYTES
  DROIDMATCH_MIN_DOWNLOAD_BYTES
  DROIDMATCH_MIN_UPLOAD_BYTES
  DROIDMATCH_UPLOAD_SOURCE_FILE
  DROIDMATCH_UPLOAD_DESTINATION_PATH
  DROIDMATCH_PREPARE_APP_SANDBOX_FILE
  DROIDMATCH_PREPARE_APP_SANDBOX_BYTES
  DROIDMATCH_HANDSHAKE_ATTEMPTS
  DROIDMATCH_MIN_HANDSHAKE_PASSES
  DROIDMATCH_LIST_PATH
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      serial="${2:?missing value for --serial}"
      shift 2
      ;;
    --remote-port)
      remote_port="${2:?missing value for --remote-port}"
      shift 2
      ;;
    --local-port)
      local_port="${2:?missing value for --local-port}"
      shift 2
      ;;
    --timeout-seconds)
      timeout_seconds="${2:?missing value for --timeout-seconds}"
      shift 2
      ;;
    --handshake-attempts)
      handshake_attempts="${2:?missing value for --handshake-attempts}"
      shift 2
      ;;
    --min-handshake-passes)
      min_handshake_passes="${2:?missing value for --min-handshake-passes}"
      shift 2
      ;;
    --list-path)
      list_path="${2:?missing value for --list-path}"
      shift 2
      ;;
    --source-path)
      download_source_path="${2:?missing value for --source-path}"
      shift 2
      ;;
    --destination)
      download_destination="${2:?missing value for --destination}"
      shift 2
      ;;
    --resume-check)
      resume_check=1
      shift
      ;;
    --cancel-check)
      cancel_check=1
      shift
      ;;
    --pause-check)
      pause_check=1
      shift
      ;;
    --partial-bytes)
      resume_partial_bytes="${2:?missing value for --partial-bytes}"
      shift 2
      ;;
    --min-download-bytes)
      min_download_bytes="${2:?missing value for --min-download-bytes}"
      shift 2
      ;;
    --upload-source)
      upload_source_file="${2:?missing value for --upload-source}"
      shift 2
      ;;
    --upload-destination-path)
      upload_destination_path="${2:?missing value for --upload-destination-path}"
      shift 2
      ;;
    --upload-resume-check)
      upload_resume_check=1
      shift
      ;;
    --upload-resume-unsupported-check)
      upload_resume_unsupported_check=1
      shift
      ;;
    --upload-partial-bytes)
      upload_partial_bytes="${2:?missing value for --upload-partial-bytes}"
      shift 2
      ;;
    --min-upload-bytes)
      min_upload_bytes="${2:?missing value for --min-upload-bytes}"
      shift 2
      ;;
    --cleanup-upload-destination)
      cleanup_upload_destination=1
      shift
      ;;
    --prepare-app-sandbox-file)
      prepare_app_sandbox_file="${2:?missing value for --prepare-app-sandbox-file}"
      shift 2
      ;;
    --prepare-app-sandbox-bytes)
      prepare_app_sandbox_bytes="${2:?missing value for --prepare-app-sandbox-bytes}"
      shift 2
      ;;
    --keep-prepared-app-sandbox-file)
      keep_prepared_app_sandbox_file=1
      shift
      ;;
    --device-slot)
      device_slot="${2:?missing value for --device-slot}"
      shift 2
      ;;
    --notes)
      notes="${2:?missing value for --notes}"
      shift 2
      ;;
    --result-log)
      result_log="${2:?missing value for --result-log}"
      shift 2
      ;;
    --no-result-log)
      record_log=0
      shift
      ;;
    --open-launcher)
      open_launcher=1
      shift
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "${prepare_app_sandbox_file}" ]]; then
  if ! [[ "${prepare_app_sandbox_file}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    printf '%s\n' "--prepare-app-sandbox-file must be a simple file name: ${prepare_app_sandbox_file}" >&2
    exit 2
  fi
  if ! [[ "${prepare_app_sandbox_bytes}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "--prepare-app-sandbox-bytes must be a positive integer: ${prepare_app_sandbox_bytes}" >&2
    exit 2
  fi
  if (( prepare_app_sandbox_bytes % 1048576 != 0 )); then
    printf '%s\n' '--prepare-app-sandbox-bytes must be a multiple of 1048576 for the current dd-based seed path.' >&2
    exit 2
  fi
  prepared_app_sandbox_source_path="dm://app-sandbox/${prepare_app_sandbox_file}"
  if [[ -z "${download_source_path}" ]]; then
    download_source_path="${prepared_app_sandbox_source_path}"
  elif [[ "${download_source_path}" != "${prepared_app_sandbox_source_path}" ]]; then
    printf '%s\n' "--source-path must match prepared app sandbox file: ${prepared_app_sandbox_source_path}" >&2
    exit 2
  fi
  if [[ -z "${list_path}" ]]; then
    list_path="dm://app-sandbox/"
  fi
  if [[ "${min_download_bytes}" == "0" ]]; then
    if (( resume_check == 1 || (cancel_check != 1 && pause_check != 1) )); then
      min_download_bytes="${prepare_app_sandbox_bytes}"
    fi
  fi
fi

if [[ -n "${download_source_path}" && -z "${download_destination}" ]]; then
  download_destination="/tmp/droidmatch-device-smoke-download.bin"
fi
if [[ "${resume_check}" -eq 1 && -z "${download_source_path}" ]]; then
  printf '%s\n' '--resume-check requires --source-path.' >&2
  exit 2
fi
if [[ "${cancel_check}" -eq 1 && -z "${download_source_path}" ]]; then
  printf '%s\n' '--cancel-check requires --source-path.' >&2
  exit 2
fi
if [[ "${pause_check}" -eq 1 && -z "${download_source_path}" ]]; then
  printf '%s\n' '--pause-check requires --source-path.' >&2
  exit 2
fi
if ! [[ "${resume_partial_bytes}" =~ ^[1-9][0-9]*$ ]]; then
  printf '%s\n' "--partial-bytes must be a positive integer: ${resume_partial_bytes}" >&2
  exit 2
fi
if ! [[ "${upload_partial_bytes}" =~ ^[1-9][0-9]*$ ]]; then
  printf '%s\n' "--upload-partial-bytes must be a positive integer: ${upload_partial_bytes}" >&2
  exit 2
fi
if ! [[ "${min_download_bytes}" =~ ^[0-9]+$ ]]; then
  printf '%s\n' "--min-download-bytes must be a non-negative integer: ${min_download_bytes}" >&2
  exit 2
fi
if ! [[ "${min_upload_bytes}" =~ ^[0-9]+$ ]]; then
  printf '%s\n' "--min-upload-bytes must be a non-negative integer: ${min_upload_bytes}" >&2
  exit 2
fi
if (( min_download_bytes > 0 && (cancel_check == 1 || pause_check == 1) && resume_check == 0 )); then
  printf '%s\n' '--min-download-bytes requires a full download or --resume-check, not only --cancel-check/--pause-check.' >&2
  exit 2
fi
if [[ -n "${upload_source_file}" && -z "${upload_destination_path}" ]]; then
  printf '%s\n' '--upload-source requires --upload-destination-path.' >&2
  exit 2
fi
if [[ -z "${upload_source_file}" && -n "${upload_destination_path}" ]]; then
  printf '%s\n' '--upload-destination-path requires --upload-source.' >&2
  exit 2
fi
if [[ -n "${upload_source_file}" && ! -f "${upload_source_file}" ]]; then
  printf '%s\n' "--upload-source must identify a readable local file: ${upload_source_file}" >&2
  exit 2
fi
if (( min_upload_bytes > 0 )) && [[ -z "${upload_source_file}" ]]; then
  printf '%s\n' '--min-upload-bytes requires --upload-source and --upload-destination-path.' >&2
  exit 2
fi
if (( upload_resume_check == 1 )) && [[ -z "${upload_source_file}" ]]; then
  printf '%s\n' '--upload-resume-check requires --upload-source and --upload-destination-path.' >&2
  exit 2
fi
if (( upload_resume_unsupported_check == 1 )) && [[ -z "${upload_source_file}" ]]; then
  printf '%s\n' '--upload-resume-unsupported-check requires --upload-source and --upload-destination-path.' >&2
  exit 2
fi
if (( upload_resume_check == 1 && upload_resume_unsupported_check == 1 )); then
  printf '%s\n' '--upload-resume-check cannot be combined with --upload-resume-unsupported-check.' >&2
  exit 2
fi
if (( upload_resume_check == 1 )) && [[ "${upload_destination_path}" != dm://app-sandbox/* ]]; then
  printf '%s\n' '--upload-resume-check currently requires a dm://app-sandbox/ upload destination.' >&2
  exit 2
fi
if (( upload_resume_unsupported_check == 1 )) && [[ "${upload_destination_path}" == dm://app-sandbox/* ]]; then
  printf '%s\n' '--upload-resume-unsupported-check is intended for fresh-only MediaStore or SAF upload destinations.' >&2
  exit 2
fi
if (( upload_resume_unsupported_check == 1 )); then
  upload_source_bytes="$(wc -c < "${upload_source_file}" | tr -d '[:space:]')"
  if (( upload_source_bytes < 1 )); then
    printf '%s\n' '--upload-resume-unsupported-check requires a non-empty upload source.' >&2
    exit 2
  fi
fi
cleanup_supported_upload_destination() {
  local destination="$1" media_name
  case "${destination}" in
    dm://app-sandbox/*)
      return 0
      ;;
    dm://media-images/*|dm://media-videos/*)
      media_name="${destination#dm://media-images/}"
      media_name="${media_name#dm://media-videos/}"
      [[ -n "${media_name}" && "${media_name}" != *"/"* && "${media_name}" != *"'"* ]]
      return
      ;;
    *)
      return 1
      ;;
  esac
}

if (( cleanup_upload_destination == 1 )) && ! cleanup_supported_upload_destination "${upload_destination_path}"; then
  printf '%s\n' "--cleanup-upload-destination currently supports dm://app-sandbox/ and single-file dm://media-images/ or dm://media-videos/ upload destinations without apostrophes." >&2
  exit 2
fi
if ! [[ "${handshake_attempts}" =~ ^[1-9][0-9]*$ ]]; then
  printf '%s\n' "--handshake-attempts must be a positive integer: ${handshake_attempts}" >&2
  exit 2
fi
if [[ -z "${min_handshake_passes}" ]]; then
  min_handshake_passes="${handshake_attempts}"
fi
if ! [[ "${min_handshake_passes}" =~ ^[1-9][0-9]*$ ]]; then
  printf '%s\n' "--min-handshake-passes must be a positive integer: ${min_handshake_passes}" >&2
  exit 2
fi
if (( min_handshake_passes > handshake_attempts )); then
  printf '%s\n' "--min-handshake-passes cannot exceed --handshake-attempts." >&2
  exit 2
fi

adb_bin="${DROIDMATCH_ADB:-}"
if [[ -z "${adb_bin}" ]]; then
  android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}"
  if [[ -x "${android_sdk}/platform-tools/adb" ]]; then
    adb_bin="${android_sdk}/platform-tools/adb"
  else
    adb_bin="adb"
  fi
fi

select_serial() {
  if [[ -n "${serial}" ]]; then
    return
  fi

  local ready=()
  local line device_serial device_state
  while IFS= read -r line; do
    [[ -z "${line}" || "${line}" == "List of devices attached"* ]] && continue
    device_serial="$(awk '{print $1}' <<<"${line}")"
    device_state="$(awk '{print $2}' <<<"${line}")"
    if [[ "${device_state}" == "device" ]]; then
      ready+=("${device_serial}")
    fi
  done < <("${adb_bin}" devices -l)

  if [[ "${#ready[@]}" -eq 1 ]]; then
    serial="${ready[0]}"
    return
  fi

  if [[ "${#ready[@]}" -eq 0 ]]; then
    printf 'No adb device is in "device" state. Check USB cable, Android USB debugging authorization, and `adb devices -l`.\n' >&2
    exit 1
  fi

  printf 'Multiple adb devices are ready; pass --serial. Ready serials:\n' >&2
  printf '  %s\n' "${ready[@]}" >&2
  exit 1
}

run_swift_harness() {
  swift run --package-path mac droidmatch-harness "$@"
}

device_prop() {
  local prop="$1"
  ("${adb_bin}" -s "${serial}" shell getprop "${prop}" 2>/dev/null || true) | tr -d '\r' | tail -1
}

redacted_output() {
  SERIAL="${serial}" SERIAL_TAG="${serial_tag}" DOWNLOAD_DESTINATION="${download_destination}" UPLOAD_SOURCE_FILE="${upload_source_file}" \
    perl -0pe 's/\Q$ENV{SERIAL}\E/<serial-redacted:$ENV{SERIAL_TAG}>/g; if ($ENV{DOWNLOAD_DESTINATION} ne "") { s/\Q$ENV{DOWNLOAD_DESTINATION}\E/<download-destination>/g; } if ($ENV{UPLOAD_SOURCE_FILE} ne "") { s/\Q$ENV{UPLOAD_SOURCE_FILE}\E/<upload-source>/g; }'
}

redacted_list_output() {
  awk '
    /^file / || /^directory / {
      redacted += 1
      next
    }
    { print }
    END {
      if (redacted > 0) {
        printf "entries redacted: %d\n", redacted
      }
    }
  ' | redacted_output
}

capture_or_exit() {
  local label="$1"
  shift
  local output
  if ! output="$("$@" 2>&1)"; then
    fail_with_log "${label}" "${output}"
  fi
  printf '%s\n' "${output}"
}

fail_with_log() {
  local stage="$1"
  local output="$2"
  final_status="failed"
  failure_stage="${stage}"
  failure_output="${output}"
  if [[ -n "${result_log}" ]]; then
    write_result_log || true
  fi
  printf '%s failed:\n%s\n' "${stage}" "${output}" >&2
  exit 1
}

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

download_bytes_from_output() {
  local output observed
  output="$(cat)"
  observed="$(printf '%s\n' "${output}" | sed -n 's/.*download passed .*final_offset=\([0-9][0-9]*\).*/\1/p' | tail -1)"
  if [[ -z "${observed}" ]]; then
    observed="$(printf '%s\n' "${output}" | sed -n 's/.*download passed .*total=\([0-9][0-9]*\).*/\1/p' | tail -1)"
  fi
  if [[ -z "${observed}" ]]; then
    observed="$(printf '%s\n' "${output}" | sed -n 's/.*download passed .*bytes=\([0-9][0-9]*\).*/\1/p' | tail -1)"
  fi
  printf '%s\n' "${observed}"
}

upload_bytes_from_output() {
  local output observed
  output="$(cat)"
  observed="$(printf '%s\n' "${output}" | sed -n 's/.*upload passed .*final_offset=\([0-9][0-9]*\).*/\1/p' | tail -1)"
  if [[ -z "${observed}" ]]; then
    observed="$(printf '%s\n' "${output}" | sed -n 's/.*upload passed .*bytes=\([0-9][0-9]*\).*/\1/p' | tail -1)"
  fi
  printf '%s\n' "${observed}"
}

assert_min_download_bytes() {
  if (( min_download_bytes == 0 )); then
    return
  fi
  if [[ -z "${download_bytes_received}" ]]; then
    fail_with_log "download size assertion" \
      "Could not parse downloaded byte count from harness output."
  fi
  if (( download_bytes_received < min_download_bytes )); then
    fail_with_log "download size assertion" \
      "downloaded ${download_bytes_received} byte(s), below required minimum ${min_download_bytes}."
  fi
}

assert_min_upload_bytes() {
  if (( min_upload_bytes == 0 )); then
    return
  fi
  if [[ -z "${upload_bytes_sent}" ]]; then
    fail_with_log "upload size assertion" \
      "Could not parse uploaded byte count from harness output."
  fi
  if (( upload_bytes_sent < min_upload_bytes )); then
    fail_with_log "upload size assertion" \
      "uploaded ${upload_bytes_sent} byte(s), below required minimum ${min_upload_bytes}."
  fi
}

prepare_app_sandbox_file_on_device() {
  [[ -n "${prepare_app_sandbox_file}" ]] || return 0

  local mebibytes mkdir_output dd_output stat_output
  mebibytes=$((prepare_app_sandbox_bytes / 1048576))
  mkdir_output="$(capture_or_exit "prepare app sandbox directory" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch mkdir -p files/droidmatch-sandbox)"
  dd_output="$(capture_or_exit "prepare app sandbox file" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch dd \
      if=/dev/zero \
      "of=files/droidmatch-sandbox/${prepare_app_sandbox_file}" \
      bs=1048576 \
      "count=${mebibytes}")"
  stat_output="$(capture_or_exit "verify app sandbox file" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch ls -l \
      "files/droidmatch-sandbox/${prepare_app_sandbox_file}")"
  prepared_app_sandbox_created=1
  prepare_app_sandbox_output="$(
    {
      printf 'mkdir:\n%s\n' "${mkdir_output}"
      printf 'dd:\n%s\n' "${dd_output}"
      printf 'verify:\n%s\n' "${stat_output}"
    }
  )"
  printf '%s\n' "${prepare_app_sandbox_output}"
}

write_result_log() {
  [[ "${record_log}" -eq 1 ]] || return 0

  mkdir -p "$(dirname "${result_log}")"
  {
    printf '# %s ADB Device Smoke\n\n' "${run_started_utc}"
    printf 'status: %s\n' "${final_status}"
    if [[ "${final_status}" == "failed" ]]; then
      printf 'failure stage: %s\n' "${failure_stage}"
    fi
    printf 'date: %s\n' "${run_started_utc}"
    printf 'device slot: %s\n' "${device_slot}"
    printf 'manufacturer/model: %s %s\n' "${device_manufacturer}" "${device_model}"
    printf 'android version/api: Android %s / API %s\n' "${android_release}" "${sdk_int}"
    printf 'build channel: local debug APK from git %s\n' "${git_commit}"
    printf 'transport: ADB forward to debug harness Activity endpoint\n'
    printf 'handshake attempts: %s/%s passed via `m1-smoke` (minimum %s)\n' "${m1_smoke_passes}" "${handshake_attempts}" "${min_handshake_passes}"
    printf 'visible time: device already authorized over USB before script start\n'
    if [[ -n "${list_path}" && -n "${list_time_ms}" ]]; then
      printf 'first list time: %s ms for `%s`\n' "${list_time_ms}" "${list_path}"
    elif [[ -n "${list_path}" ]]; then
      printf 'first list time: not completed for `%s`\n' "${list_path}"
    else
      printf 'first list time: not measured by this script\n'
    fi
    if [[ "${resume_check}" -eq 1 && "${final_status}" == "passed" && "${min_download_bytes}" -gt 0 ]]; then
      printf '100MB download: partial download plus resume passed for `%s`; bytes %s >= required %s\n' "${download_source_path}" "${download_bytes_received:-unknown}" "${min_download_bytes}"
    elif [[ "${resume_check}" -eq 1 && "${final_status}" == "passed" ]]; then
      printf '100MB download: partial download plus resume passed for `%s`; 100MB size not asserted\n' "${download_source_path}"
    elif [[ "${resume_check}" -eq 1 ]]; then
      printf '100MB download: resume-check requested for `%s` but did not complete; 100MB size not asserted\n' "${download_source_path}"
    elif [[ "${cancel_check}" -eq 1 && "${final_status}" == "passed" ]]; then
      printf '100MB download: cancel-check passed for `%s`; 100MB size not asserted\n' "${download_source_path}"
    elif [[ "${cancel_check}" -eq 1 ]]; then
      printf '100MB download: cancel-check requested for `%s` but did not complete; 100MB size not asserted\n' "${download_source_path}"
    elif [[ "${pause_check}" -eq 1 && "${final_status}" == "passed" ]]; then
      printf '100MB download: pause-check passed for `%s`; 100MB size not asserted\n' "${download_source_path}"
    elif [[ "${pause_check}" -eq 1 ]]; then
      printf '100MB download: pause-check requested for `%s` but did not complete; 100MB size not asserted\n' "${download_source_path}"
    elif [[ -n "${download_source_path}" && "${final_status}" == "passed" && "${min_download_bytes}" -gt 0 ]]; then
      printf '100MB download: `download` command passed for `%s`; bytes %s >= required %s\n' "${download_source_path}" "${download_bytes_received:-unknown}" "${min_download_bytes}"
    elif [[ -n "${download_source_path}" && "${final_status}" == "passed" ]]; then
      printf '100MB download: `download` command passed for `%s`; 100MB size not asserted\n' "${download_source_path}"
    elif [[ -n "${download_source_path}" ]]; then
      printf '100MB download: `download` requested for `%s` but did not complete; 100MB size not asserted\n' "${download_source_path}"
    else
      printf '100MB download: not run\n'
    fi
    if [[ "${upload_resume_check}" -eq 1 && "${final_status}" == "passed" && "${min_upload_bytes}" -gt 0 ]]; then
      printf '100MB upload: partial upload plus resume passed to `%s`; bytes %s >= required %s\n' "${upload_destination_path}" "${upload_bytes_sent:-unknown}" "${min_upload_bytes}"
    elif [[ "${upload_resume_check}" -eq 1 && "${final_status}" == "passed" ]]; then
      printf '100MB upload: partial upload plus resume passed to `%s`; 100MB size not asserted\n' "${upload_destination_path}"
    elif [[ "${upload_resume_check}" -eq 1 ]]; then
      printf '100MB upload: upload-resume-check requested to `%s` but did not complete; 100MB size not asserted\n' "${upload_destination_path}"
    elif [[ "${upload_resume_unsupported_check}" -eq 1 && -n "${upload_source_file}" && "${final_status}" == "passed" && "${min_upload_bytes}" -gt 0 ]]; then
      printf '100MB upload: fresh-only resume unsupported check and `upload` passed to `%s`; bytes %s >= required %s\n' "${upload_destination_path}" "${upload_bytes_sent:-unknown}" "${min_upload_bytes}"
    elif [[ "${upload_resume_unsupported_check}" -eq 1 && -n "${upload_source_file}" && "${final_status}" == "passed" ]]; then
      printf '100MB upload: fresh-only resume unsupported check and `upload` passed to `%s`; 100MB size not asserted\n' "${upload_destination_path}"
    elif [[ "${upload_resume_unsupported_check}" -eq 1 && -n "${upload_source_file}" ]]; then
      printf '100MB upload: fresh-only resume unsupported check requested for `%s` but did not complete; 100MB size not asserted\n' "${upload_destination_path}"
    elif [[ -n "${upload_source_file}" && "${final_status}" == "passed" && "${min_upload_bytes}" -gt 0 ]]; then
      printf '100MB upload: `upload` command passed to `%s`; bytes %s >= required %s\n' "${upload_destination_path}" "${upload_bytes_sent:-unknown}" "${min_upload_bytes}"
    elif [[ -n "${upload_source_file}" && "${final_status}" == "passed" ]]; then
      printf '100MB upload: `upload` command passed to `%s`; 100MB size not asserted\n' "${upload_destination_path}"
    elif [[ -n "${upload_source_file}" ]]; then
      printf '100MB upload: `upload` requested to `%s` but did not complete; 100MB size not asserted\n' "${upload_destination_path}"
    else
      printf '100MB upload: not run\n'
    fi
    if [[ "${resume_check}" -eq 1 && "${final_status}" == "passed" ]]; then
      printf 'resume result: partial stop after at least %s byte(s), then `download --resume` passed\n' "${resume_partial_bytes}"
    elif [[ "${resume_check}" -eq 1 ]]; then
      printf 'resume result: resume-check requested but did not complete\n'
    else
      printf 'resume result: not run\n'
    fi
    if [[ "${cancel_check}" -eq 1 && "${final_status}" == "passed" ]]; then
      printf 'cancel result: `download-cancel` passed after the first chunk for `%s`\n' "${download_source_path}"
    elif [[ "${cancel_check}" -eq 1 ]]; then
      printf 'cancel result: cancel-check requested but did not complete\n'
    else
      printf 'cancel result: not run\n'
    fi
    if [[ "${pause_check}" -eq 1 && "${final_status}" == "passed" ]]; then
      printf 'pause result: `download-pause` passed after the first chunk for `%s`\n' "${download_source_path}"
    elif [[ "${pause_check}" -eq 1 ]]; then
      printf 'pause result: pause-check requested but did not complete\n'
    else
      printf 'pause result: not run\n'
    fi
    printf 'permission cases: launcher entry resolved to `DiagnosticsActivity`; detailed permission-denied cases not run\n'
    printf 'diagnostics bundle: `m1-smoke` output included below\n'
    printf 'notes:\n\n'
    printf '%s\n' "- serial redaction tag: \`<serial-redacted:${serial_tag}>\`"
    printf '%s\n' "- remote port: \`${remote_port}\`"
    printf '%s\n' "- local port: \`${allocated_local_port}\`"
    printf '%s\n' '- launcher: `app.droidmatch/app.droidmatch.m1.DiagnosticsActivity`'
    printf '%s\n' "- m1-smoke failures: \`${m1_smoke_failures}\`"
    if [[ -n "${list_path}" ]]; then
      printf '%s\n' "- timed list path: \`${list_path}\`"
    fi
    if [[ -n "${notes}" ]]; then
      printf '%s\n' "- ${notes}"
    fi
    if [[ -n "${prepare_app_sandbox_file}" ]]; then
      printf '%s\n' "- prepared app sandbox file: \`${prepare_app_sandbox_file}\`"
      printf '%s\n' "- prepared app sandbox bytes: \`${prepare_app_sandbox_bytes}\`"
      if [[ "${keep_prepared_app_sandbox_file}" -eq 1 ]]; then
        printf '%s\n' '- prepared app sandbox cleanup: kept on device'
      else
        printf '%s\n' '- prepared app sandbox cleanup: scheduled on script exit'
      fi
    fi
    if [[ "${min_download_bytes}" -gt 0 ]]; then
      printf '%s\n' "- min download bytes: \`${min_download_bytes}\`"
      printf '%s\n' "- observed download bytes: \`${download_bytes_received:-unknown}\`"
    fi
    if [[ -n "${upload_source_file}" ]]; then
      printf '%s\n' "- upload destination: \`${upload_destination_path}\`"
      if [[ "${upload_resume_check}" -eq 1 ]]; then
        printf '%s\n' "- upload partial bytes: \`${upload_partial_bytes}\`"
      fi
      if [[ "${upload_resume_unsupported_check}" -eq 1 ]]; then
        printf '%s\n' '- upload resume unsupported check: requested offset `1`, expected `unsupportedCapability`'
      fi
      if [[ "${cleanup_upload_destination}" -eq 1 ]]; then
        printf '%s\n' '- upload destination cleanup: scheduled on script exit'
      fi
    fi
    if [[ "${min_upload_bytes}" -gt 0 ]]; then
      printf '%s\n' "- min upload bytes: \`${min_upload_bytes}\`"
      printf '%s\n' "- observed upload bytes: \`${upload_bytes_sent:-unknown}\`"
    fi
    if [[ "${final_status}" == "failed" ]]; then
      printf '%s\n' "- failure stage: \`${failure_stage}\`"
    fi

    printf '\n## Install Output\n\n```text\n'
    printf '%s\n' "${install_output}" | redacted_output
    if [[ -n "${prepare_app_sandbox_output}" ]]; then
      printf '```\n\n## Prepare App Sandbox Output\n\n```text\n'
      printf '%s\n' "${prepare_app_sandbox_output}" | redacted_output
    fi
    printf '```\n\n## Launcher Resolve Output\n\n```text\n'
    printf '%s\n' "${launcher_output}" | redacted_output
    printf '```\n\n## Activity Start Output\n\n```text\n'
    printf '%s\n' "${activity_output}" | redacted_output
    printf '```\n\n## Forward Output\n\n```text\n'
    printf '%s\n' "${forward_output}" | redacted_output
    printf '```\n\n## M1 Smoke Output\n\n```text\n'
    printf '%s\n' "${m1_smoke_output}" | redacted_output
    printf '```\n'
    if [[ -n "${list_path}" ]]; then
      printf '\n## Timed ListDir Output\n\n```text\n'
      printf '%s\n' "${list_output}" | redacted_list_output
      printf '```\n'
    fi
    if [[ "${resume_check}" -eq 1 ]]; then
      printf '\n## Partial Download Output\n\n```text\n'
      printf '%s\n' "${partial_download_output}" | redacted_output
      printf '```\n\n## Resume Download Output\n\n```text\n'
      printf '%s\n' "${resume_download_output}" | redacted_output
      printf '```\n'
    elif [[ -n "${download_output}" ]]; then
      printf '\n## Download Output\n\n```text\n'
      printf '%s\n' "${download_output}" | redacted_output
      printf '```\n'
    fi
    if [[ "${cancel_check}" -eq 1 ]]; then
      printf '\n## Cancel Download Output\n\n```text\n'
      printf '%s\n' "${cancel_download_output}" | redacted_output
      printf '```\n'
    fi
    if [[ "${pause_check}" -eq 1 ]]; then
      printf '\n## Pause Download Output\n\n```text\n'
      printf '%s\n' "${pause_download_output}" | redacted_output
      printf '```\n'
    fi
    if [[ "${upload_resume_check}" -eq 1 ]]; then
      printf '\n## Partial Upload Output\n\n```text\n'
      printf '%s\n' "${partial_upload_output}" | redacted_output
      printf '```\n\n## Resume Upload Output\n\n```text\n'
      printf '%s\n' "${resume_upload_output}" | redacted_output
      printf '```\n'
    elif [[ "${upload_resume_unsupported_check}" -eq 1 ]]; then
      printf '\n## Upload Resume Unsupported Output\n\n```text\n'
      printf '%s\n' "${upload_resume_unsupported_output}" | redacted_output
      printf '```\n'
      if [[ -n "${upload_output}" ]]; then
        printf '\n## Upload Output\n\n```text\n'
        printf '%s\n' "${upload_output}" | redacted_output
        printf '```\n'
      fi
    elif [[ -n "${upload_output}" ]]; then
      printf '\n## Upload Output\n\n```text\n'
      printf '%s\n' "${upload_output}" | redacted_output
      printf '```\n'
    fi
    if [[ "${final_status}" == "failed" ]]; then
      printf '\n## Failure Output\n\n```text\n'
      printf '%s\n' "${failure_output}" | redacted_output
      printf '```\n'
    fi
  } > "${result_log}"

  printf 'Result log written: %s\n' "${result_log}"
}

cleanup_mediastore_upload_destination() {
  local destination="$1" collection_uri display_name relative_path sdk_int where_clause
  case "${destination}" in
    dm://media-images/*)
      collection_uri="content://media/external/images/media"
      display_name="${destination#dm://media-images/}"
      relative_path="Pictures/DroidMatch/"
      ;;
    dm://media-videos/*)
      collection_uri="content://media/external/video/media"
      display_name="${destination#dm://media-videos/}"
      relative_path="Movies/DroidMatch/"
      ;;
    *)
      return 0
      ;;
  esac

  if [[ -z "${display_name}" || "${display_name}" == *"/"* || "${display_name}" == *"'"* ]]; then
    return 0
  fi

  sdk_int="$(device_prop ro.build.version.sdk)"
  if [[ "${sdk_int}" =~ ^[0-9]+$ && "${sdk_int}" -ge 29 ]]; then
    where_clause="\"_display_name='${display_name}' AND relative_path='${relative_path}'\""
  else
    where_clause="\"_display_name='${display_name}'\""
  fi
  "${adb_bin}" -s "${serial}" shell content delete \
    --uri "${collection_uri}" \
    --where "${where_clause}" >/dev/null 2>&1 || true
}

cleanup() {
  if [[ -n "${allocated_local_port:-}" ]]; then
    "${adb_bin}" -s "${serial}" forward --remove "tcp:${allocated_local_port}" >/dev/null 2>&1 || true
  fi
  if [[ "${prepared_app_sandbox_created:-0}" -eq 1 \
      && "${keep_prepared_app_sandbox_file:-0}" -ne 1 \
      && -n "${serial:-}" \
      && -n "${prepare_app_sandbox_file:-}" ]]; then
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch rm -f \
      "files/droidmatch-sandbox/${prepare_app_sandbox_file}" >/dev/null 2>&1 || true
  fi
  if [[ "${cleanup_upload_destination:-0}" -eq 1 \
      && -n "${serial:-}" \
      && "${upload_destination_path:-}" == dm://app-sandbox/* ]]; then
    local_relative="${upload_destination_path#dm://app-sandbox/}"
    if [[ -n "${local_relative}" && "${local_relative}" != *".."* && "${local_relative}" != /* ]]; then
      "${adb_bin}" -s "${serial}" shell run-as app.droidmatch rm -f \
        "files/droidmatch-sandbox/${local_relative}" >/dev/null 2>&1 || true
    fi
  fi
  if [[ "${cleanup_upload_destination:-0}" -eq 1 \
      && -n "${serial:-}" \
      && ( "${upload_destination_path:-}" == dm://media-images/* \
        || "${upload_destination_path:-}" == dm://media-videos/* ) ]]; then
    cleanup_mediastore_upload_destination "${upload_destination_path}"
  fi
}
trap cleanup EXIT

if [[ "${skip_build}" -eq 0 ]]; then
  bash tools/check-m1-skeleton.sh
fi

apk_path="android/app/build/outputs/apk/debug/app-debug.apk"
if [[ ! -s "${apk_path}" ]]; then
  printf 'Missing debug APK: %s. Run tools/check-m1-skeleton.sh first or omit --skip-build.\n' "${apk_path}" >&2
  exit 1
fi

select_serial
printf 'Using adb device serial=%s\n' "${serial}"

run_started_utc="$(date -u '+%Y-%m-%d %H:%M:%SZ')"
run_started_slug="$(date -u '+%Y-%m-%dT%H-%M-%SZ')"
serial_tag="$(printf '%s' "${serial}" | shasum -a 256 | awk '{print substr($1, 1, 8)}')"
if [[ -z "${result_log}" ]]; then
  result_log="fixtures/m1-runs/${run_started_slug}-adb-${serial_tag}.md"
fi
git_commit="$(git rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
if [[ "${git_commit}" != "unknown" && -n "$(git status --porcelain 2>/dev/null)" ]]; then
  git_commit="${git_commit}-dirty"
fi
device_manufacturer="$(device_prop ro.product.manufacturer)"
device_model="$(device_prop ro.product.model)"
android_release="$(device_prop ro.build.version.release)"
sdk_int="$(device_prop ro.build.version.sdk)"

install_output="$(capture_or_exit "adb install" "${adb_bin}" -s "${serial}" install -r -g "${apk_path}")"
printf '%s\n' "${install_output}"

prepare_app_sandbox_file_on_device

launcher_output="$("${adb_bin}" -s "${serial}" shell cmd package resolve-activity --brief \
  -a android.intent.action.MAIN \
  -c android.intent.category.LAUNCHER \
  app.droidmatch 2>/dev/null | tr -d '\r')"
if ! grep -Eq 'app\.droidmatch/(app\.droidmatch)?\.m1\.DiagnosticsActivity' <<<"${launcher_output}"; then
  fail_with_log "launcher resolve" \
    "Installed APK does not resolve DroidMatch DiagnosticsActivity as the launcher entry.
${launcher_output}"
fi
printf 'Launcher entry verified: app.droidmatch/app.droidmatch.m1.DiagnosticsActivity\n'

if [[ "${open_launcher}" -eq 1 ]]; then
  "${adb_bin}" -s "${serial}" shell monkey -p app.droidmatch -c android.intent.category.LAUNCHER 1
fi

"${adb_bin}" -s "${serial}" logcat -c >/dev/null || true
"${adb_bin}" -s "${serial}" shell am force-stop app.droidmatch >/dev/null || true
activity_output="$(capture_or_exit "debug harness Activity start" "${adb_bin}" -s "${serial}" shell am start -W \
  -n app.droidmatch/app.droidmatch.m1.DebugHarnessActivity \
  --ei port "${remote_port}")"
printf '%s\n' "${activity_output}"

forward_output="$(capture_or_exit "adb forward" run_swift_harness forward --serial "${serial}" --local-port "${local_port}" --remote-port "${remote_port}")"
printf '%s\n' "${forward_output}"
allocated_local_port="$(sed -n 's/.*local_port=\([0-9][0-9]*\).*/\1/p' <<<"${forward_output}" | tail -1)"
if [[ -z "${allocated_local_port}" ]]; then
  fail_with_log "adb forward parse" "Could not parse allocated local_port from forward output.
${forward_output}"
fi

m1_smoke_output=""
m1_smoke_passes=0
m1_smoke_failures=0
for ((attempt = 1; attempt <= handshake_attempts; attempt += 1)); do
  if attempt_output="$(run_swift_harness m1-smoke --port "${allocated_local_port}" --timeout-seconds "${timeout_seconds}" 2>&1)"; then
    attempt_status="passed"
    m1_smoke_passes=$((m1_smoke_passes + 1))
  else
    attempt_status="failed"
    m1_smoke_failures=$((m1_smoke_failures + 1))
  fi
  printf '%s\n' "${attempt_output}"
  if [[ -n "${m1_smoke_output}" ]]; then
    m1_smoke_output+=$'\n'
  fi
  m1_smoke_output+="## attempt ${attempt}/${handshake_attempts} ${attempt_status}"$'\n'"${attempt_output}"
done
if (( m1_smoke_passes < min_handshake_passes )); then
  fail_with_log "m1-smoke threshold" \
    "m1-smoke passed ${m1_smoke_passes}/${handshake_attempts} attempts, below required minimum ${min_handshake_passes}."
fi

if [[ -n "${list_path}" ]]; then
  list_started_ms="$(now_ms)"
  list_output="$(capture_or_exit "list-dir" \
    run_swift_harness list-dir --port "${allocated_local_port}" --timeout-seconds "${timeout_seconds}" --path "${list_path}")"
  list_finished_ms="$(now_ms)"
  list_time_ms=$((list_finished_ms - list_started_ms))
  printf '%s\n' "${list_output}"
fi

if [[ "${resume_check}" -eq 1 ]]; then
  partial_download_output="$(capture_or_exit "partial download" run_swift_harness download \
    --port "${allocated_local_port}" \
    --timeout-seconds "${timeout_seconds}" \
    --source-path "${download_source_path}" \
    --destination "${download_destination}" \
    --stop-after-bytes "${resume_partial_bytes}")"
  printf '%s\n' "${partial_download_output}"

  resume_download_output="$(capture_or_exit "resume download" run_swift_harness download \
    --port "${allocated_local_port}" \
    --timeout-seconds "${timeout_seconds}" \
    --source-path "${download_source_path}" \
    --destination "${download_destination}" \
    --resume)"
  printf '%s\n' "${resume_download_output}"
  download_bytes_received="$(printf '%s\n' "${resume_download_output}" | download_bytes_from_output)"
  assert_min_download_bytes
elif [[ -n "${download_source_path}" && "${cancel_check}" -ne 1 && "${pause_check}" -ne 1 ]]; then
  download_output="$(capture_or_exit "download" run_swift_harness download \
    --port "${allocated_local_port}" \
    --timeout-seconds "${timeout_seconds}" \
    --source-path "${download_source_path}" \
    --destination "${download_destination}")"
  printf '%s\n' "${download_output}"
  download_bytes_received="$(printf '%s\n' "${download_output}" | download_bytes_from_output)"
  assert_min_download_bytes
fi

if [[ "${cancel_check}" -eq 1 ]]; then
  cancel_download_output="$(capture_or_exit "download-cancel" run_swift_harness download-cancel \
    --port "${allocated_local_port}" \
    --timeout-seconds "${timeout_seconds}" \
    --source-path "${download_source_path}")"
  printf '%s\n' "${cancel_download_output}"
fi

if [[ "${pause_check}" -eq 1 ]]; then
  pause_download_output="$(capture_or_exit "download-pause" run_swift_harness download-pause \
    --port "${allocated_local_port}" \
    --timeout-seconds "${timeout_seconds}" \
    --source-path "${download_source_path}")"
  printf '%s\n' "${pause_download_output}"
fi

if [[ -n "${upload_source_file}" && "${upload_resume_unsupported_check}" -eq 1 ]]; then
  upload_resume_unsupported_output="$(capture_or_exit "upload resume unsupported" run_swift_harness upload-open-expect-error \
    --port "${allocated_local_port}" \
    --timeout-seconds "${timeout_seconds}" \
    --source "${upload_source_file}" \
    --destination-path "${upload_destination_path}" \
    --requested-offset 1 \
    --expected-error-code unsupportedCapability \
    --expected-message-contains "upload resume is not supported")"
  printf '%s\n' "${upload_resume_unsupported_output}"
fi

if [[ -n "${upload_source_file}" && "${upload_resume_check}" -eq 1 ]]; then
  partial_upload_output="$(capture_or_exit "partial upload" run_swift_harness upload \
    --port "${allocated_local_port}" \
    --timeout-seconds "${timeout_seconds}" \
    --source "${upload_source_file}" \
    --destination-path "${upload_destination_path}" \
    --stop-after-bytes "${upload_partial_bytes}")"
  printf '%s\n' "${partial_upload_output}"

  resume_upload_output="$(capture_or_exit "resume upload" run_swift_harness upload \
    --port "${allocated_local_port}" \
    --timeout-seconds "${timeout_seconds}" \
    --source "${upload_source_file}" \
    --destination-path "${upload_destination_path}" \
    --resume)"
  printf '%s\n' "${resume_upload_output}"
  upload_bytes_sent="$(printf '%s\n' "${resume_upload_output}" | upload_bytes_from_output)"
  assert_min_upload_bytes
elif [[ -n "${upload_source_file}" ]]; then
  upload_output="$(capture_or_exit "upload" run_swift_harness upload \
    --port "${allocated_local_port}" \
    --timeout-seconds "${timeout_seconds}" \
    --source "${upload_source_file}" \
    --destination-path "${upload_destination_path}")"
  printf '%s\n' "${upload_output}"
  upload_bytes_sent="$(printf '%s\n' "${upload_output}" | upload_bytes_from_output)"
  assert_min_upload_bytes
fi

write_result_log

printf 'M1 device smoke passed serial=%s local_port=%s remote_port=%s\n' \
  "${serial}" "${allocated_local_port}" "${remote_port}"
