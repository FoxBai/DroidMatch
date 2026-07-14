#!/usr/bin/env bash

set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
# shellcheck source=tools/m1-output-redaction.sh
source "${repo_root}/tools/m1-output-redaction.sh"

serial="${DROIDMATCH_SERIAL:-}"
serial_tag=""
remote_port="${DROIDMATCH_ANDROID_PORT:-39001}"
local_port="${DROIDMATCH_LOCAL_PORT:-0}"
timeout_seconds="${DROIDMATCH_SMOKE_TIMEOUT_SECONDS:-10}"
result_log="${DROIDMATCH_RESULT_LOG:-}"
device_slot="${DROIDMATCH_DEVICE_SLOT:-unclassified}"
notes="${DROIDMATCH_RUN_NOTES:-}"
resume_partial_bytes="${DROIDMATCH_RESUME_PARTIAL_BYTES:-1}"
upload_partial_bytes="${DROIDMATCH_UPLOAD_PARTIAL_BYTES:-1}"
retry_max_attempts="${DROIDMATCH_MAX_RETRY_ATTEMPTS:-}"
retry_backoff_ms="${DROIDMATCH_RETRY_BACKOFF_MS:-}"
min_download_bytes="${DROIDMATCH_MIN_DOWNLOAD_BYTES:-0}"
min_upload_bytes="${DROIDMATCH_MIN_UPLOAD_BYTES:-0}"
min_download_mib_per_second="${DROIDMATCH_MIN_DOWNLOAD_MIB_PER_SECOND:-0}"
min_upload_mib_per_second="${DROIDMATCH_MIN_UPLOAD_MIB_PER_SECOND:-0}"
transfer_chunk_size_bytes="${DROIDMATCH_TRANSFER_CHUNK_SIZE_BYTES:-}"
prepare_app_sandbox_file="${DROIDMATCH_PREPARE_APP_SANDBOX_FILE:-}"
prepare_app_sandbox_bytes="${DROIDMATCH_PREPARE_APP_SANDBOX_BYTES:-104857600}"
handshake_attempts="${DROIDMATCH_HANDSHAKE_ATTEMPTS:-1}"
min_handshake_passes="${DROIDMATCH_MIN_HANDSHAKE_PASSES:-}"
list_path="${DROIDMATCH_LIST_PATH:-}"
max_list_ms="${DROIDMATCH_MAX_LIST_MS:-0}"
list_expect_error_path="${DROIDMATCH_LIST_EXPECT_ERROR_PATH:-}"
list_expect_error_code="${DROIDMATCH_LIST_EXPECT_ERROR_CODE:-}"
list_expect_error_message_contains="${DROIDMATCH_LIST_EXPECT_ERROR_MESSAGE_CONTAINS:-}"
media_permission_revoked_check="${DROIDMATCH_MEDIA_PERMISSION_REVOKED_CHECK:-0}"
media_permission_revoked_during_download_check="${DROIDMATCH_MEDIA_PERMISSION_REVOKED_DURING_DOWNLOAD_CHECK:-0}"
adb_baseline_download_check="${DROIDMATCH_ADB_BASELINE_DOWNLOAD_CHECK:-0}"
download_resume_source_mutation_check="${DROIDMATCH_DOWNLOAD_RESUME_SOURCE_MUTATION_CHECK:-0}"
download_resume_source_deletion_check="${DROIDMATCH_DOWNLOAD_RESUME_SOURCE_DELETION_CHECK:-0}"
dual_download_check="${DROIDMATCH_DUAL_DOWNLOAD_CHECK:-0}"
mixed_transfer_check="${DROIDMATCH_MIXED_TRANSFER_CHECK:-0}"
mixed_upload_destination_path="${DROIDMATCH_MIXED_UPLOAD_DESTINATION_PATH:-}"
download_open_expect_error_path="${DROIDMATCH_DOWNLOAD_OPEN_EXPECT_ERROR_PATH:-}"
download_open_expect_error_code="${DROIDMATCH_DOWNLOAD_OPEN_EXPECT_ERROR_CODE:-}"
download_open_expect_error_message_contains="${DROIDMATCH_DOWNLOAD_OPEN_EXPECT_ERROR_MESSAGE_CONTAINS:-}"
skip_build=0
download_source_path=""
download_destination=""
upload_source_file="${DROIDMATCH_UPLOAD_SOURCE_FILE:-}"
upload_destination_path="${DROIDMATCH_UPLOAD_DESTINATION_PATH:-}"
cleanup_upload_destination=0
require_disposable_app_sandbox_paths=0
open_launcher=0
record_log=1
resume_check=0
cancel_check=0
pause_check=0
upload_resume_check=0
upload_resume_unsupported_check=0
download_retry_on_transport_loss=0
upload_retry_on_transport_loss=0
retry_max_attempts_explicit=0
retry_backoff_ms_explicit=0
download_retry_fault_check=0
upload_retry_fault_check=0
upload_retry_ack_loss_check=0
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
list_wall_time_ms=""
list_output=""
list_expect_error_output=""
media_permission_mutation_output=""
media_permission_restore_read_external_storage=0
media_permission_restore_read_media_images=0
media_permission_restore_read_media_video=0
media_permission_restore_read_media_visual_user_selected=0
media_permission_restored=0
media_permission_revoke_hook_script=""
media_permission_revoke_download_outcome=""
download_open_expect_error_output=""
download_source_mutation_output=""
download_source_deletion_output=""
download_source_resume_restore_output=""
partial_download_output=""
resume_download_output=""
download_output=""
dual_download_output=""
mixed_transfer_output=""
mixed_download_destination=""
cancel_download_output=""
pause_download_output=""
upload_output=""
partial_upload_output=""
resume_upload_output=""
upload_resume_unsupported_output=""
download_bytes_received=""
upload_bytes_sent=""
download_elapsed_ms=""
upload_elapsed_ms=""
download_throughput_mib_per_second=""
upload_throughput_mib_per_second=""
prepare_app_sandbox_output=""
prepared_app_sandbox_source_path=""
prepared_app_sandbox_created=0
adb_baseline_download_output=""
adb_baseline_download_bytes=""
adb_baseline_download_elapsed_ms=""
adb_baseline_download_throughput_mib_per_second=""
adb_baseline_download_temp_file=""

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
  --max-list-ms <ms>             Optional maximum elapsed time for --list-path. Default: 0 (record only).
  --list-expect-error-path <dm-path>
                                  Optional logical path to list while requiring an error response.
  --list-expect-error-code <code> Expected error code for --list-expect-error-path.
  --list-expect-error-message-contains <text>
                                  Optional error message substring for --list-expect-error-path.
  --media-permission-revoked-check
                                  Revoke media read permission, then require a media ListDir permission error.
  --media-permission-revoked-during-download-check
                                  Revoke media read permission after the first proxied media download chunk,
                                  require a completed download or expected transport loss, then restore prior grants.
  --download-open-expect-error-path <dm-path>
                                  Optional source path to open as a download while requiring an error response.
  --download-open-expect-error-code <code>
                                  Expected error code for --download-open-expect-error-path.
  --download-open-expect-error-message-contains <text>
                                  Optional error message substring for --download-open-expect-error-path.
  --source-path <dm-path>        Optional logical path to download after m1-smoke.
  --destination <path>           Destination for --source-path download.
  --chunk-size-bytes <bytes>     Preferred transfer chunk size passed to harness download/upload commands.
  --resume-check                 Run a partial download, then resume it. Requires --source-path.
  --download-resume-source-mutation-check
                                  After the partial download, append one byte to a script-created app-sandbox
                                  source and require resume rejection for its changed source fingerprint.
  --download-resume-source-deletion-check
                                  After the partial download, remove a script-created app-sandbox source and
                                  require the resume attempt to return not-found.
  --download-retry-on-transport-loss
                                  Pass download --retry-on-transport-loss to the resume/full download command.
  --max-retry-attempts <count>    Optional extra reconnect attempts for download/upload transport-loss retry.
                                  Only applies with --*-retry-on-transport-loss or --*-retry-fault-check.
  --retry-backoff-ms <ms>         Optional base backoff for configurable recovery. Default harness value: 500.
  --download-retry-fault-check    Run the resume/full download through a local fault proxy and require recovery.
                                  Implies --download-retry-on-transport-loss.
  --dual-download-check          Open two concurrent download streams for --source-path and verify multiplexed
                                  chunks plus a responsive heartbeat. Requires --source-path.
  --mixed-transfer-check         Verify heartbeat with download/upload open, then complete both on one async
                                  session. Requires --source-path, --upload-source, and a distinct mixed target.
  --mixed-upload-destination-path <dm-path>
                                  Fresh remote upload target used only by --mixed-transfer-check.
  --cancel-check                 Open a download transfer, read one chunk, then cancel it. Requires --source-path.
  --pause-check                  Open a download transfer, read one chunk, then pause it. Requires --source-path.
  --upload-source <path>         Local file to upload after m1-smoke.
  --upload-destination-path <dm-path>
                                  Logical DroidMatch destination for --upload-source.
  --upload-resume-check          Run a partial upload, then resume it. Requires upload source/destination.
  --upload-retry-on-transport-loss
                                  Pass upload --retry-on-transport-loss to app-sandbox/SAF resume/full upload.
  --upload-retry-fault-check      Run app-sandbox/SAF resume/full upload through a local fault proxy and require recovery.
                                  Implies --upload-retry-on-transport-loss. The source must extend beyond the
                                  partial boundary plus the first 4-chunk/2 MiB upload window.
  --upload-retry-ack-loss-check   Run app-sandbox resume upload through a proxy that drops the first chunk ACK.
                                  Implies --upload-retry-on-transport-loss and requires --upload-resume-check.
                                  The source must extend beyond the partial boundary plus the first 4-chunk/2 MiB window.
  --upload-resume-unsupported-check
                                  Open a non-zero-offset upload and require unsupported-capability.
                                  Intended for fresh-only MediaStore destinations.
  --upload-partial-bytes <bytes> Bytes to upload before the intentional partial stop. Default: 1.
  --min-upload-bytes <bytes>     Require uploaded bytes to be at least this value.
  --min-upload-mib-per-second <mibps>
                                  Require measured upload throughput to be at least this value.
  --cleanup-upload-destination   Remove uploaded app-sandbox, direct-root SAF single-file, or single-file MediaStore destination on exit.
                                  Nested SAF document-token targets remain manual because their tokens are session-local.
  --require-disposable-app-sandbox-paths
                                  Refuse unless the prepared source, upload final, and hidden partial are absent.
  --partial-bytes <bytes>        Bytes to write before the intentional partial stop. Default: 1.
  --min-download-bytes <bytes>   Require full/resume download bytes to be at least this value.
  --min-download-mib-per-second <mibps>
                                  Require measured download throughput to be at least this value.
  --prepare-app-sandbox-file <name>
                                  Create an app-private zero-filled file before smoke.
  --prepare-app-sandbox-bytes <bytes>
                                  Size for --prepare-app-sandbox-file. Default: 104857600.
  --adb-baseline-download-check
                                  Time a raw adb exec-out read of the prepared app-sandbox file.
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
  DROIDMATCH_MAX_RETRY_ATTEMPTS
  DROIDMATCH_RETRY_BACKOFF_MS
  DROIDMATCH_MIN_DOWNLOAD_BYTES
  DROIDMATCH_MIN_DOWNLOAD_MIB_PER_SECOND
  DROIDMATCH_MIN_UPLOAD_BYTES
  DROIDMATCH_MIN_UPLOAD_MIB_PER_SECOND
  DROIDMATCH_TRANSFER_CHUNK_SIZE_BYTES
  DROIDMATCH_UPLOAD_SOURCE_FILE
  DROIDMATCH_UPLOAD_DESTINATION_PATH
  DROIDMATCH_PREPARE_APP_SANDBOX_FILE
  DROIDMATCH_PREPARE_APP_SANDBOX_BYTES
  DROIDMATCH_ADB_BASELINE_DOWNLOAD_CHECK
  DROIDMATCH_DOWNLOAD_RESUME_SOURCE_MUTATION_CHECK
  DROIDMATCH_DOWNLOAD_RESUME_SOURCE_DELETION_CHECK
  DROIDMATCH_DUAL_DOWNLOAD_CHECK
  DROIDMATCH_MIXED_TRANSFER_CHECK
  DROIDMATCH_MIXED_UPLOAD_DESTINATION_PATH
  DROIDMATCH_HANDSHAKE_ATTEMPTS
  DROIDMATCH_MIN_HANDSHAKE_PASSES
  DROIDMATCH_LIST_PATH
  DROIDMATCH_MAX_LIST_MS
  DROIDMATCH_LIST_EXPECT_ERROR_PATH
  DROIDMATCH_LIST_EXPECT_ERROR_CODE
  DROIDMATCH_LIST_EXPECT_ERROR_MESSAGE_CONTAINS
  DROIDMATCH_MEDIA_PERMISSION_REVOKED_CHECK
  DROIDMATCH_MEDIA_PERMISSION_REVOKED_DURING_DOWNLOAD_CHECK
  DROIDMATCH_DOWNLOAD_OPEN_EXPECT_ERROR_PATH
  DROIDMATCH_DOWNLOAD_OPEN_EXPECT_ERROR_CODE
  DROIDMATCH_DOWNLOAD_OPEN_EXPECT_ERROR_MESSAGE_CONTAINS
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
    --max-list-ms)
      max_list_ms="${2:?missing value for --max-list-ms}"
      shift 2
      ;;
    --list-expect-error-path)
      list_expect_error_path="${2:?missing value for --list-expect-error-path}"
      shift 2
      ;;
    --list-expect-error-code)
      list_expect_error_code="${2:?missing value for --list-expect-error-code}"
      shift 2
      ;;
    --list-expect-error-message-contains)
      list_expect_error_message_contains="${2:?missing value for --list-expect-error-message-contains}"
      shift 2
      ;;
    --media-permission-revoked-check)
      media_permission_revoked_check=1
      shift
      ;;
    --media-permission-revoked-during-download-check)
      media_permission_revoked_during_download_check=1
      shift
      ;;
    --download-open-expect-error-path)
      download_open_expect_error_path="${2:?missing value for --download-open-expect-error-path}"
      shift 2
      ;;
    --download-open-expect-error-code)
      download_open_expect_error_code="${2:?missing value for --download-open-expect-error-code}"
      shift 2
      ;;
    --download-open-expect-error-message-contains)
      download_open_expect_error_message_contains="${2:?missing value for --download-open-expect-error-message-contains}"
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
    --chunk-size-bytes)
      transfer_chunk_size_bytes="${2:?missing value for --chunk-size-bytes}"
      shift 2
      ;;
    --resume-check)
      resume_check=1
      shift
      ;;
    --download-resume-source-mutation-check)
      download_resume_source_mutation_check=1
      shift
      ;;
    --download-resume-source-deletion-check)
      download_resume_source_deletion_check=1
      shift
      ;;
    --download-retry-on-transport-loss)
      download_retry_on_transport_loss=1
      shift
      ;;
    --max-retry-attempts)
      retry_max_attempts="${2:?missing value for --max-retry-attempts}"
      retry_max_attempts_explicit=1
      shift 2
      ;;
    --retry-backoff-ms)
      retry_backoff_ms="${2:?missing value for --retry-backoff-ms}"
      retry_backoff_ms_explicit=1
      shift 2
      ;;
    --download-retry-fault-check)
      download_retry_fault_check=1
      download_retry_on_transport_loss=1
      shift
      ;;
    --dual-download-check)
      dual_download_check=1
      shift
      ;;
    --mixed-transfer-check)
      mixed_transfer_check=1
      shift
      ;;
    --mixed-upload-destination-path)
      mixed_upload_destination_path="${2:?missing value for --mixed-upload-destination-path}"
      shift 2
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
    --min-download-mib-per-second)
      min_download_mib_per_second="${2:?missing value for --min-download-mib-per-second}"
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
    --upload-retry-on-transport-loss)
      upload_retry_on_transport_loss=1
      shift
      ;;
    --upload-retry-fault-check)
      upload_retry_fault_check=1
      upload_retry_on_transport_loss=1
      shift
      ;;
    --upload-retry-ack-loss-check)
      upload_retry_ack_loss_check=1
      upload_retry_on_transport_loss=1
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
    --min-upload-mib-per-second)
      min_upload_mib_per_second="${2:?missing value for --min-upload-mib-per-second}"
      shift 2
      ;;
    --cleanup-upload-destination)
      cleanup_upload_destination=1
      shift
      ;;
    --require-disposable-app-sandbox-paths)
      require_disposable_app_sandbox_paths=1
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
    --adb-baseline-download-check)
      adb_baseline_download_check=1
      shift
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
    printf '%s\n' '--prepare-app-sandbox-file must be a simple file name: <name-redacted>' >&2
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
    printf '%s\n' '--source-path must match prepared app sandbox file: <dm-path-redacted>' >&2
    exit 2
  fi
  if [[ -z "${list_path}" ]]; then
    list_path="dm://app-sandbox/"
  fi
  if [[ "${min_download_bytes}" == "0" \
      && "${download_resume_source_mutation_check}" -ne 1 \
      && "${download_resume_source_deletion_check}" -ne 1 ]]; then
    if (( resume_check == 1 || (cancel_check != 1 && pause_check != 1) )); then
      min_download_bytes="${prepare_app_sandbox_bytes}"
    fi
  fi
fi

if [[ "${media_permission_revoked_check}" != "0" && "${media_permission_revoked_check}" != "1" ]]; then
  printf '%s\n' "--media-permission-revoked-check must be 0 or 1 when set through DROIDMATCH_MEDIA_PERMISSION_REVOKED_CHECK: ${media_permission_revoked_check}" >&2
  exit 2
fi
if [[ "${media_permission_revoked_during_download_check}" != "0" && "${media_permission_revoked_during_download_check}" != "1" ]]; then
  printf '%s\n' "--media-permission-revoked-during-download-check must be 0 or 1 when set through DROIDMATCH_MEDIA_PERMISSION_REVOKED_DURING_DOWNLOAD_CHECK: ${media_permission_revoked_during_download_check}" >&2
  exit 2
fi
if [[ "${media_permission_revoked_check}" -eq 1 && "${media_permission_revoked_during_download_check}" -eq 1 ]]; then
  printf '%s\n' '--media-permission-revoked-check and --media-permission-revoked-during-download-check must be run separately.' >&2
  exit 2
fi
if [[ "${adb_baseline_download_check}" != "0" && "${adb_baseline_download_check}" != "1" ]]; then
  printf '%s\n' "--adb-baseline-download-check must be 0 or 1 when set through DROIDMATCH_ADB_BASELINE_DOWNLOAD_CHECK: ${adb_baseline_download_check}" >&2
  exit 2
fi
if [[ "${adb_baseline_download_check}" -eq 1 && -z "${prepare_app_sandbox_file}" ]]; then
  printf '%s\n' '--adb-baseline-download-check requires --prepare-app-sandbox-file.' >&2
  exit 2
fi
if ! [[ "${max_list_ms}" =~ ^[0-9]+$ ]]; then
  printf '%s\n' "--max-list-ms must be a non-negative integer: ${max_list_ms}" >&2
  exit 2
fi
if [[ "${media_permission_revoked_check}" -eq 1 ]]; then
  if [[ -z "${list_expect_error_path}" ]]; then
    list_expect_error_path="dm://media-images/"
  fi
  if [[ -z "${list_expect_error_code}" ]]; then
    list_expect_error_code="permissionRequired"
  fi
  if [[ -z "${list_expect_error_message_contains}" ]]; then
    list_expect_error_message_contains="media permission"
  fi
  if [[ "${list_expect_error_path}" != "dm://media-images/" \
      && "${list_expect_error_path}" != "dm://media-videos/" ]]; then
    printf '%s\n' '--media-permission-revoked-check requires a media root list expected-error path.' >&2
    exit 2
  fi
fi
if [[ -n "${list_expect_error_path}" && -z "${list_expect_error_code}" ]]; then
  printf '%s\n' '--list-expect-error-path requires --list-expect-error-code.' >&2
  exit 2
fi
if [[ -n "${list_expect_error_code}" && -z "${list_expect_error_path}" ]]; then
  printf '%s\n' '--list-expect-error-code requires --list-expect-error-path.' >&2
  exit 2
fi
if [[ -n "${list_expect_error_message_contains}" && -z "${list_expect_error_path}" ]]; then
  printf '%s\n' '--list-expect-error-message-contains requires --list-expect-error-path.' >&2
  exit 2
fi
if [[ -n "${download_open_expect_error_path}" && -z "${download_open_expect_error_code}" ]]; then
  printf '%s\n' '--download-open-expect-error-path requires --download-open-expect-error-code.' >&2
  exit 2
fi
if [[ -n "${download_open_expect_error_code}" && -z "${download_open_expect_error_path}" ]]; then
  printf '%s\n' '--download-open-expect-error-code requires --download-open-expect-error-path.' >&2
  exit 2
fi
if [[ -n "${download_open_expect_error_message_contains}" && -z "${download_open_expect_error_path}" ]]; then
  printf '%s\n' '--download-open-expect-error-message-contains requires --download-open-expect-error-path.' >&2
  exit 2
fi

if [[ -n "${download_source_path}" && -z "${download_destination}" ]]; then
  download_destination="/tmp/droidmatch-device-smoke-download.bin"
fi
if [[ "${download_resume_source_mutation_check}" != "0" && "${download_resume_source_mutation_check}" != "1" ]]; then
  printf '%s\n' "--download-resume-source-mutation-check must be 0 or 1 when set through DROIDMATCH_DOWNLOAD_RESUME_SOURCE_MUTATION_CHECK: ${download_resume_source_mutation_check}" >&2
  exit 2
fi
if [[ "${download_resume_source_deletion_check}" != "0" && "${download_resume_source_deletion_check}" != "1" ]]; then
  printf '%s\n' "--download-resume-source-deletion-check must be 0 or 1 when set through DROIDMATCH_DOWNLOAD_RESUME_SOURCE_DELETION_CHECK: ${download_resume_source_deletion_check}" >&2
  exit 2
fi
if [[ "${download_resume_source_mutation_check}" -eq 1 && "${download_resume_source_deletion_check}" -eq 1 ]]; then
  printf '%s\n' '--download-resume-source-mutation-check and --download-resume-source-deletion-check must be run separately.' >&2
  exit 2
fi
if [[ "${dual_download_check}" != "0" && "${dual_download_check}" != "1" ]]; then
  printf '%s\n' "--dual-download-check must be 0 or 1 when set through DROIDMATCH_DUAL_DOWNLOAD_CHECK: ${dual_download_check}" >&2
  exit 2
fi
if [[ "${mixed_transfer_check}" != "0" && "${mixed_transfer_check}" != "1" ]]; then
  printf '%s\n' "--mixed-transfer-check must be 0 or 1 when set through DROIDMATCH_MIXED_TRANSFER_CHECK: ${mixed_transfer_check}" >&2
  exit 2
fi
if [[ "${media_permission_revoked_during_download_check}" -eq 1 ]]; then
  if [[ -z "${download_source_path}" ]]; then
    printf '%s\n' '--media-permission-revoked-during-download-check requires --source-path.' >&2
    exit 2
  fi
  if [[ "${download_source_path}" != dm://media-images/media/* \
      && "${download_source_path}" != dm://media-videos/media/* ]]; then
    printf '%s\n' '--media-permission-revoked-during-download-check requires a MediaStore item source path.' >&2
    exit 2
  fi
  if (( resume_check == 1 || cancel_check == 1 || pause_check == 1 || download_retry_fault_check == 1 )); then
    printf '%s\n' '--media-permission-revoked-during-download-check cannot be combined with resume/cancel/pause/download retry fault checks.' >&2
    exit 2
  fi
fi
if [[ "${resume_check}" -eq 1 && -z "${download_source_path}" ]]; then
  printf '%s\n' '--resume-check requires --source-path.' >&2
  exit 2
fi
if [[ "${download_resume_source_mutation_check}" -eq 1 || "${download_resume_source_deletion_check}" -eq 1 ]]; then
  if [[ "${resume_check}" -ne 1 ]]; then
    printf '%s\n' '--download-resume-source-mutation-check/--download-resume-source-deletion-check require --resume-check.' >&2
    exit 2
  fi
  if [[ -z "${prepare_app_sandbox_file}" || "${download_source_path}" != "${prepared_app_sandbox_source_path}" ]]; then
    printf '%s\n' '--download-resume-source-mutation-check/--download-resume-source-deletion-check require --prepare-app-sandbox-file as their --source-path.' >&2
    exit 2
  fi
  if [[ "${download_retry_on_transport_loss}" -eq 1 || "${download_retry_fault_check}" -eq 1 ]]; then
    printf '%s\n' '--download resume source mutation/deletion checks cannot be combined with download transport-loss retry checks.' >&2
    exit 2
  fi
  if (( min_download_bytes > 0 )) \
      || awk -v value="${min_download_mib_per_second}" 'BEGIN { exit !((value + 0) > 0) }'; then
    printf '%s\n' '--download resume source mutation/deletion checks cannot be combined with download size or throughput gates.' >&2
    exit 2
  fi
fi
if [[ "${download_retry_on_transport_loss}" -eq 1 && -z "${download_source_path}" ]]; then
  printf '%s\n' '--download-retry-on-transport-loss requires --source-path.' >&2
  exit 2
fi
if [[ "${download_retry_fault_check}" -eq 1 && -z "${download_source_path}" ]]; then
  printf '%s\n' '--download-retry-fault-check requires --source-path.' >&2
  exit 2
fi
if [[ "${dual_download_check}" -eq 1 && -z "${download_source_path}" ]]; then
  printf '%s\n' '--dual-download-check requires --source-path.' >&2
  exit 2
fi
if [[ "${mixed_transfer_check}" -eq 1 && -z "${download_source_path}" ]]; then
  printf '%s\n' '--mixed-transfer-check requires --source-path.' >&2
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
if [[ -n "${retry_max_attempts}" ]] && ! [[ "${retry_max_attempts}" =~ ^[0-9]+$ ]]; then
  printf '%s\n' "--max-retry-attempts must be a non-negative integer: ${retry_max_attempts}" >&2
  exit 2
fi
if [[ -n "${retry_backoff_ms}" ]] && ! [[ "${retry_backoff_ms}" =~ ^[0-9]+$ ]]; then
  printf '%s\n' "--retry-backoff-ms must be a non-negative integer: ${retry_backoff_ms}" >&2
  exit 2
fi
if (( (retry_max_attempts_explicit == 1 || retry_backoff_ms_explicit == 1) \
    && download_retry_on_transport_loss != 1 \
    && upload_retry_on_transport_loss != 1 )); then
  printf '%s\n' '--max-retry-attempts/--retry-backoff-ms require a transport-loss retry check.' >&2
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
if ! [[ "${min_download_mib_per_second}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf '%s\n' "--min-download-mib-per-second must be a non-negative number: ${min_download_mib_per_second}" >&2
  exit 2
fi
if ! [[ "${min_upload_mib_per_second}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  printf '%s\n' "--min-upload-mib-per-second must be a non-negative number: ${min_upload_mib_per_second}" >&2
  exit 2
fi
if [[ -n "${transfer_chunk_size_bytes}" ]] && ! [[ "${transfer_chunk_size_bytes}" =~ ^[1-9][0-9]*$ ]]; then
  printf '%s\n' "--chunk-size-bytes must be a positive integer: ${transfer_chunk_size_bytes}" >&2
  exit 2
fi
if (( min_download_bytes > 0 && (cancel_check == 1 || pause_check == 1) && resume_check == 0 )); then
  printf '%s\n' '--min-download-bytes requires a full download or --resume-check, not only --cancel-check/--pause-check.' >&2
  exit 2
fi
if awk -v value="${min_download_mib_per_second}" 'BEGIN { exit !((value + 0) > 0) }' \
    && { [[ -z "${download_source_path}" ]] || (( (cancel_check == 1 || pause_check == 1) && resume_check == 0 )); }; then
  printf '%s\n' '--min-download-mib-per-second requires a full download or --resume-check.' >&2
  exit 2
fi
if awk -v value="${min_upload_mib_per_second}" 'BEGIN { exit !((value + 0) > 0) }' \
    && [[ -z "${upload_source_file}" ]]; then
  printf '%s\n' '--min-upload-mib-per-second requires --upload-source and --upload-destination-path.' >&2
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
  printf '%s\n' '--upload-source must identify a readable local file: <upload-source>' >&2
  exit 2
fi
if [[ "${mixed_transfer_check}" -eq 1 && -z "${upload_source_file}" ]]; then
  printf '%s\n' '--mixed-transfer-check requires --upload-source and --upload-destination-path.' >&2
  exit 2
fi
if [[ "${mixed_transfer_check}" -eq 1 && -z "${mixed_upload_destination_path}" ]]; then
  printf '%s\n' '--mixed-transfer-check requires --mixed-upload-destination-path.' >&2
  exit 2
fi
if [[ "${mixed_transfer_check}" -eq 0 && -n "${mixed_upload_destination_path}" ]]; then
  printf '%s\n' '--mixed-upload-destination-path requires --mixed-transfer-check.' >&2
  exit 2
fi
if [[ "${mixed_transfer_check}" -eq 1 \
    && "${mixed_upload_destination_path}" == "${upload_destination_path}" ]]; then
  printf '%s\n' '--mixed-upload-destination-path must differ from --upload-destination-path.' >&2
  exit 2
fi
if [[ "${mixed_transfer_check}" -eq 1 \
    && "${mixed_upload_destination_path}" == "${download_source_path}" ]]; then
  printf '%s\n' '--mixed-upload-destination-path must not overwrite the active download source.' >&2
  exit 2
fi

# A first-ACK fault can occur after Android has already received every chunk in
# its bounded initial window. If that window contains the final chunk, the
# provider may have atomically committed the destination before the Mac-side
# retry starts; the old partial is then intentionally gone and cannot be used
# as a resume checkpoint. Keep fault-injection evidence in the replayable
# prefix case instead of misreporting that valid final-ACK race as a product
# failure. 中文：故障注入必须避开“首窗已完成最终提交”的不可判定窗口。
upload_retry_initial_window_bytes() {
  local chunk_size_bytes="${1:-262144}"
  local window_bytes=2097152
  if (( chunk_size_bytes <= 524288 )); then
    window_bytes=$((chunk_size_bytes * 4))
  fi
  printf '%s\n' "${window_bytes}"
}

validate_upload_retry_source_size() {
  local label="$1"
  local source_bytes="$2"
  local partial_bytes="$3"
  local chunk_size_bytes="${4:-262144}"
  local window_bytes
  window_bytes="$(upload_retry_initial_window_bytes "${chunk_size_bytes}")"
  if (( source_bytes <= partial_bytes + window_bytes )); then
    printf '%s\n' "--${label} requires upload source bytes greater than upload partial bytes plus the first 4-chunk/2 MiB window (source=${source_bytes}, partial=${partial_bytes}, window=${window_bytes})." >&2
    return 1
  fi
}

upload_source_bytes=""
if [[ -n "${upload_source_file}" ]]; then
  upload_source_bytes="$(wc -c < "${upload_source_file}" | tr -d '[:space:]')"
fi
if (( min_upload_bytes > 0 )) && [[ -z "${upload_source_file}" ]]; then
  printf '%s\n' '--min-upload-bytes requires --upload-source and --upload-destination-path.' >&2
  exit 2
fi
if (( upload_resume_check == 1 )) && [[ -z "${upload_source_file}" ]]; then
  printf '%s\n' '--upload-resume-check requires --upload-source and --upload-destination-path.' >&2
  exit 2
fi
if (( upload_retry_on_transport_loss == 1 )) && [[ -z "${upload_source_file}" ]]; then
  printf '%s\n' '--upload-retry-on-transport-loss requires --upload-source and --upload-destination-path.' >&2
  exit 2
fi
if (( upload_retry_fault_check == 1 )) && [[ -z "${upload_source_file}" ]]; then
  printf '%s\n' '--upload-retry-fault-check requires --upload-source and --upload-destination-path.' >&2
  exit 2
fi
if (( upload_retry_ack_loss_check == 1 )) && [[ -z "${upload_source_file}" ]]; then
  printf '%s\n' '--upload-retry-ack-loss-check requires --upload-source and --upload-destination-path.' >&2
  exit 2
fi
if (( upload_resume_unsupported_check == 1 )) && [[ -z "${upload_source_file}" ]]; then
  printf '%s\n' '--upload-resume-unsupported-check requires --upload-source and --upload-destination-path.' >&2
  exit 2
fi
if (( upload_retry_ack_loss_check == 1 && upload_resume_check != 1 )); then
  printf '%s\n' '--upload-retry-ack-loss-check requires --upload-resume-check.' >&2
  exit 2
fi
if (( upload_resume_check == 1 && upload_resume_unsupported_check == 1 )); then
  printf '%s\n' '--upload-resume-check cannot be combined with --upload-resume-unsupported-check.' >&2
  exit 2
fi
if (( upload_resume_check == 1 )) \
    && [[ "${upload_destination_path}" != dm://app-sandbox/* ]] \
    && [[ "${upload_destination_path}" != dm://saf-* ]]; then
  printf '%s\n' '--upload-resume-check currently requires a dm://app-sandbox/ or dm://saf- upload destination.' >&2
  exit 2
fi
if (( upload_retry_on_transport_loss == 1 )) \
    && [[ "${upload_destination_path}" != dm://app-sandbox/* ]] \
    && [[ "${upload_destination_path}" != dm://saf-* ]]; then
  printf '%s\n' '--upload-retry-on-transport-loss currently requires a dm://app-sandbox/ or dm://saf- upload destination.' >&2
  exit 2
fi
if (( upload_retry_ack_loss_check == 1 )) \
    && [[ "${upload_destination_path}" != dm://app-sandbox/* ]]; then
  printf '%s\n' '--upload-retry-ack-loss-check currently requires a dm://app-sandbox/ upload destination.' >&2
  exit 2
fi
if (( upload_retry_fault_check == 1 || upload_retry_ack_loss_check == 1 )); then
  retry_chunk_size_bytes="${transfer_chunk_size_bytes:-262144}"
  retry_check_label='upload retry fault checks'
  if (( upload_retry_ack_loss_check == 1 )); then
    retry_check_label='upload retry ACK-loss check'
  fi
  if ! validate_upload_retry_source_size \
      "${retry_check_label}" \
      "${upload_source_bytes}" \
      "${upload_partial_bytes}" \
      "${retry_chunk_size_bytes}"; then
    exit 2
  fi
fi
if (( upload_resume_unsupported_check == 1 )) \
    && [[ "${upload_destination_path}" != dm://media-images/* ]] \
    && [[ "${upload_destination_path}" != dm://media-videos/* ]]; then
  printf '%s\n' '--upload-resume-unsupported-check is intended for fresh-only MediaStore upload destinations.' >&2
  exit 2
fi
if (( upload_resume_unsupported_check == 1 )); then
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
    dm://saf-*)
      [[ "${destination}" =~ ^dm://saf-[A-Za-z0-9._-]+/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
      return
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
  printf '%s\n' "--cleanup-upload-destination supports dm://app-sandbox/, direct-root single-file dm://saf-<stable-id>/<name>, and single-file MediaStore destinations without apostrophes." >&2
  exit 2
fi
if (( cleanup_upload_destination == 1 && mixed_transfer_check == 1 )) \
    && ! cleanup_supported_upload_destination "${mixed_upload_destination_path}"; then
  printf '%s\n' '--cleanup-upload-destination cannot clean mixed target <dm-path-redacted>; use app-sandbox, direct-root SAF single-file, or a single-file MediaStore path without apostrophes.' >&2
  exit 2
fi
if (( require_disposable_app_sandbox_paths == 1 )); then
  if ! [[ -n "${prepare_app_sandbox_file}" \
      && "${upload_destination_path}" =~ ^dm://app-sandbox/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    printf '%s\n' '--require-disposable-app-sandbox-paths requires a prepared simple file and a simple app-sandbox upload destination.' >&2
    exit 2
  fi
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

serial_tag_for() {
  printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 8)}'
}

serial_label_for() {
  printf '<serial-redacted:%s>' "$(serial_tag_for "$1")"
}

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

  printf 'Multiple adb devices are ready; pass --serial. Ready device tags:\n' >&2
  for device_serial in "${ready[@]}"; do
    printf '  %s\n' "$(serial_label_for "${device_serial}")" >&2
  done
  exit 1
}

run_swift_harness() {
  # Physical throughput evidence must exercise optimized Core code. A default
  # `swift run` builds with -Onone, which makes the byte-wise CRC path part of
  # the measured transfer time and can misclassify slower devices. SwiftPM
  # caches this release product after the first invocation in a matrix run.
  swift run --package-path mac --configuration release droidmatch-harness "$@"
}

run_swift_harness_with_fault_proxy() {
  local command="$1"
  shift
  local port_file log_file proxy_pid proxy_port output status wait_index proxy_log
  local drop_after_frames="${FAULT_PROXY_DROP_AFTER_FRAMES:-3}"
  local drop_before_frame="${FAULT_PROXY_DROP_BEFORE_FRAME:-0}"
  local hook_after_frames="${FAULT_PROXY_HOOK_AFTER_FRAMES:-0}"
  local hook_command="${FAULT_PROXY_HOOK_COMMAND:-}"
  local hook_timeout_seconds="${FAULT_PROXY_HOOK_TIMEOUT_SECONDS:-30}"
  port_file="$(mktemp /tmp/droidmatch-m1-fault-proxy-port.XXXXXX)"
  log_file="$(mktemp /tmp/droidmatch-m1-fault-proxy-log.XXXXXX)"
  proxy_port=""

  python3 tools/m1-fault-proxy.py \
    --target-host 127.0.0.1 \
    --target-port "${allocated_local_port}" \
    --listen-host 127.0.0.1 \
    --listen-port 0 \
    --port-file "${port_file}" \
    --drop-first-server-frames "${drop_after_frames}" \
    --drop-before-first-server-frame "${drop_before_frame}" \
    --run-command-after-first-server-frames "${hook_after_frames}" \
    --after-first-server-frames-command "${hook_command}" \
    --after-first-server-frames-command-timeout "${hook_timeout_seconds}" \
    --max-connections 2 \
    >/dev/null 2>"${log_file}" &
  proxy_pid=$!

  for ((wait_index = 0; wait_index < 100; wait_index += 1)); do
    if [[ -s "${port_file}" ]]; then
      proxy_port="$(tr -d '[:space:]' < "${port_file}")"
      break
    fi
    if ! kill -0 "${proxy_pid}" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done

  if [[ -z "${proxy_port}" ]]; then
    proxy_log="$(cat "${log_file}" 2>/dev/null || true)"
    kill "${proxy_pid}" >/dev/null 2>&1 || true
    wait "${proxy_pid}" >/dev/null 2>&1 || true
    rm -f "${port_file}" "${log_file}"
    printf 'fault proxy did not publish a listen port.\n%s\n' "${proxy_log}"
    return 1
  fi

  set +e
  output="$(run_swift_harness "${command}" --port "${proxy_port}" "$@" 2>&1)"
  status=$?
  set -e

  kill "${proxy_pid}" >/dev/null 2>&1 || true
  wait "${proxy_pid}" >/dev/null 2>&1 || true
  proxy_log="$(cat "${log_file}" 2>/dev/null || true)"
  rm -f "${port_file}" "${log_file}"

  print_redacted_output "${output}"
  if [[ -n "${proxy_log}" ]]; then
    printf 'fault proxy log:\n%s\n' "${proxy_log}" | redacted_output
  fi
  return "${status}"
}

run_swift_harness_with_ack_loss_fault_proxy() {
  FAULT_PROXY_DROP_AFTER_FRAMES=0 FAULT_PROXY_DROP_BEFORE_FRAME=3 \
    run_swift_harness_with_fault_proxy "$@"
}

run_swift_harness_with_permission_revoke_fault_proxy() {
  FAULT_PROXY_DROP_AFTER_FRAMES=0 \
    FAULT_PROXY_HOOK_AFTER_FRAMES=3 \
    FAULT_PROXY_HOOK_COMMAND="bash ${media_permission_revoke_hook_script}" \
    run_swift_harness_with_fault_proxy "$@"
}

assert_fault_proxy_hook_command_succeeded() {
  local label="$1"
  local output="$2"
  if ! grep -q 'fault proxy hook command status=0' <<<"${output}"; then
    fail_with_log "${label}" \
      "Fault proxy permission hook did not report status=0.
${output}"
  fi
}

is_expected_permission_revoke_download_failure() {
  local output="$1"
  grep -Eq 'connection failed|Socket is not connected|connection closed|transportLost|transport lost|timeout' <<<"${output}"
}

device_prop() {
  local prop="$1"
  ("${adb_bin}" -s "${serial}" shell getprop "${prop}" 2>/dev/null || true) | tr -d '\r' | tail -1
}

run_adb_shell_record() {
  local output status
  set +e
  output="$("${adb_bin}" -s "${serial}" shell "$@" 2>&1 | tr -d '\r')"
  status=$?
  set -e
  {
    printf 'adb shell'
    while [[ $# -gt 0 ]]; do
      printf ' %s' "$1"
      shift
    done
    printf '\nstatus=%s\n' "${status}"
    if [[ -n "${output}" ]]; then
      printf '%s\n' "${output}"
    fi
  } | redacted_output
}

runtime_permission_granted() {
  local permission="$1"
  "${adb_bin}" -s "${serial}" shell dumpsys package app.droidmatch 2>/dev/null \
    | tr -d '\r' \
    | grep -Fq "${permission}: granted=true"
}

runtime_permission_state() {
  local permission="$1"
  if runtime_permission_granted "${permission}"; then
    printf 'granted'
  else
    printf 'denied'
  fi
}

media_permission_state_line() {
  printf 'sdk=%s read_external=%s read_media_images=%s read_media_video=%s read_media_visual_user_selected=%s' \
    "${sdk_int:-unknown}" \
    "$(runtime_permission_state android.permission.READ_EXTERNAL_STORAGE)" \
    "$(runtime_permission_state android.permission.READ_MEDIA_IMAGES)" \
    "$(runtime_permission_state android.permission.READ_MEDIA_VIDEO)" \
    "$(runtime_permission_state android.permission.READ_MEDIA_VISUAL_USER_SELECTED)"
}

media_read_permission_granted_for_sdk() {
  if [[ "${sdk_int:-0}" =~ ^[0-9]+$ && "${sdk_int}" -ge 33 ]]; then
    runtime_permission_granted android.permission.READ_MEDIA_IMAGES \
      || runtime_permission_granted android.permission.READ_MEDIA_VIDEO \
      || runtime_permission_granted android.permission.READ_MEDIA_VISUAL_USER_SELECTED
    return
  fi
  runtime_permission_granted android.permission.READ_EXTERNAL_STORAGE
}

capture_media_permission_restore_state() {
  media_permission_restore_read_external_storage=0
  media_permission_restore_read_media_images=0
  media_permission_restore_read_media_video=0
  media_permission_restore_read_media_visual_user_selected=0
  media_permission_restored=0

  if runtime_permission_granted android.permission.READ_EXTERNAL_STORAGE; then
    media_permission_restore_read_external_storage=1
  fi
  if runtime_permission_granted android.permission.READ_MEDIA_IMAGES; then
    media_permission_restore_read_media_images=1
  fi
  if runtime_permission_granted android.permission.READ_MEDIA_VIDEO; then
    media_permission_restore_read_media_video=1
  fi
  if runtime_permission_granted android.permission.READ_MEDIA_VISUAL_USER_SELECTED; then
    media_permission_restore_read_media_visual_user_selected=1
  fi

  if [[ "${media_permission_restore_read_media_visual_user_selected}" -eq 1 \
      && "${media_permission_restore_read_media_images}" -eq 0 \
      && "${media_permission_restore_read_media_video}" -eq 0 ]]; then
    fail_with_log "media permission revoke guard" \
      "Device has selected-photos-only media access. ADB cannot safely restore the selected media set after revoke; skip --media-permission-revoked-check on this device state."
  fi
}

media_permission_mutation_enabled() {
  [[ "${media_permission_revoked_check}" -eq 1 || "${media_permission_revoked_during_download_check}" -eq 1 ]]
}

revoke_media_permissions_for_check() {
  [[ "${media_permission_revoked_check}" -eq 1 ]] || return 0

  capture_media_permission_restore_state

  media_permission_mutation_output="$(
    {
      printf 'before revoke: %s\n' "$(media_permission_state_line)"
      if [[ "${sdk_int:-0}" =~ ^[0-9]+$ && "${sdk_int}" -ge 33 ]]; then
        run_adb_shell_record pm revoke app.droidmatch android.permission.READ_MEDIA_VISUAL_USER_SELECTED
        run_adb_shell_record pm revoke app.droidmatch android.permission.READ_MEDIA_IMAGES
        run_adb_shell_record pm revoke app.droidmatch android.permission.READ_MEDIA_VIDEO
      else
        run_adb_shell_record pm revoke app.droidmatch android.permission.READ_EXTERNAL_STORAGE
      fi
      printf 'after revoke: %s\n' "$(media_permission_state_line)"
    }
  )"
  print_redacted_output "${media_permission_mutation_output}"

  if media_read_permission_granted_for_sdk; then
    fail_with_log "media permission revoke" \
      "Media read permission remained granted after revoke.
${media_permission_mutation_output}"
  fi

  local restart_output
  restart_output="$(capture_or_exit "debug harness Activity restart after media permission revoke" \
    "${adb_bin}" -s "${serial}" shell am start -W \
      -n app.droidmatch/app.droidmatch.m1.DebugHarnessActivity \
      --ei port "${remote_port}")"
  media_permission_mutation_output+=$'\n'"restart after revoke:"$'\n'"${restart_output}"
  print_redacted_output "${restart_output}"
}

prepare_media_permission_revoke_during_download_check() {
  [[ "${media_permission_revoked_during_download_check}" -eq 1 ]] || return 0

  capture_media_permission_restore_state
  media_permission_mutation_output="$(
    {
      printf 'before revoke during download: %s\n' "$(media_permission_state_line)"
      printf 'revoke trigger: after first proxied media download chunk\n'
    }
  )"

  media_permission_revoke_hook_script="$(mktemp /tmp/droidmatch-media-permission-revoke.XXXXXX)"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'adb_bin=%q\n' "${adb_bin}"
    printf 'serial=%q\n' "${serial}"
    cat <<'HOOK'
run_adb_shell_record() {
  local output status
  set +e
  output="$("${adb_bin}" -s "${serial}" shell "$@" 2>&1 | tr -d '\r')"
  status=$?
  set -e
  {
    printf 'adb shell'
    while [[ $# -gt 0 ]]; do
      printf ' %s' "$1"
      shift
    done
    printf '\n'
    if [[ -n "${output}" ]]; then
      printf '%s\n' "${output}"
    fi
    printf 'status=%s\n' "${status}"
  } | redacted_output
  return "${status}"
}

sdk="$("${adb_bin}" -s "${serial}" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r' | tail -1)"
if [[ "${sdk:-0}" =~ ^[0-9]+$ && "${sdk}" -ge 33 ]]; then
  run_adb_shell_record pm revoke app.droidmatch android.permission.READ_MEDIA_VISUAL_USER_SELECTED
  run_adb_shell_record pm revoke app.droidmatch android.permission.READ_MEDIA_IMAGES
  run_adb_shell_record pm revoke app.droidmatch android.permission.READ_MEDIA_VIDEO
else
  run_adb_shell_record pm revoke app.droidmatch android.permission.READ_EXTERNAL_STORAGE
fi
HOOK
  } > "${media_permission_revoke_hook_script}"
  chmod +x "${media_permission_revoke_hook_script}"
}

record_media_permission_state_after_revoke_during_download() {
  [[ "${media_permission_revoked_during_download_check}" -eq 1 ]] || return 0

  local after_revoke_state
  after_revoke_state="$(media_permission_state_line)"
  media_permission_mutation_output+=$'\n'"after revoke during download: ${after_revoke_state}"
  printf 'after revoke during download: %s\n' "${after_revoke_state}"
  if media_read_permission_granted_for_sdk; then
    restore_media_permissions_after_check 1
    fail_with_log "media permission revoke during download" \
      "Media read permission remained granted after the proxy hook.
${media_permission_mutation_output}"
  fi
}

restore_media_permissions_after_check() {
  local restart_endpoint="${1:-0}"
  media_permission_mutation_enabled || return 0
  [[ "${media_permission_restored}" -eq 0 ]] || return 0
  [[ -n "${serial:-}" ]] || return 0

  local restore_output
  restore_output="$(
    {
      printf 'before restore: %s\n' "$(media_permission_state_line)"
      if [[ "${media_permission_restore_read_external_storage}" -eq 1 ]]; then
        run_adb_shell_record pm grant app.droidmatch android.permission.READ_EXTERNAL_STORAGE
      fi
      if [[ "${media_permission_restore_read_media_images}" -eq 1 ]]; then
        run_adb_shell_record pm grant app.droidmatch android.permission.READ_MEDIA_IMAGES
      fi
      if [[ "${media_permission_restore_read_media_video}" -eq 1 ]]; then
        run_adb_shell_record pm grant app.droidmatch android.permission.READ_MEDIA_VIDEO
      fi
      if [[ "${media_permission_restore_read_media_visual_user_selected}" -eq 1 ]]; then
        run_adb_shell_record pm grant app.droidmatch android.permission.READ_MEDIA_VISUAL_USER_SELECTED
      fi
      printf 'after restore: %s\n' "$(media_permission_state_line)"
    }
  )"
  if [[ -n "${media_permission_mutation_output}" ]]; then
    media_permission_mutation_output+=$'\n'
  fi
  media_permission_mutation_output+="restore permissions:"$'\n'"${restore_output}"
  media_permission_restored=1
  print_redacted_output "${restore_output}"

  if [[ "${restart_endpoint}" -eq 1 ]]; then
    local restart_output
    restart_output="$(capture_or_exit "debug harness Activity restart after media permission restore" \
      "${adb_bin}" -s "${serial}" shell am start -W \
        -n app.droidmatch/app.droidmatch.m1.DebugHarnessActivity \
        --ei port "${remote_port}")"
    media_permission_mutation_output+=$'\n'"restart after restore:"$'\n'"${restart_output}"
    print_redacted_output "${restart_output}"
  fi
}

redacted_output() {
  DROIDMATCH_REDACT_SERIAL="${serial:-}" \
    DROIDMATCH_REDACT_SERIAL_TAG="${serial_tag:-}" \
    DROIDMATCH_REDACT_DOWNLOAD_DESTINATION="${download_destination:-}" \
    DROIDMATCH_REDACT_UPLOAD_SOURCE="${upload_source_file:-}" \
    DROIDMATCH_REDACT_RESULT_LOG="${result_log:-}" \
    DROIDMATCH_REDACT_REPO_ROOT="${redaction_repo_root:-${repo_root:-}}" \
    DROIDMATCH_REDACT_ADB_PATH="${adb_bin:-}" \
    DROIDMATCH_REDACT_NOTES="${notes:-}" \
    DROIDMATCH_REDACT_NAME="${prepare_app_sandbox_file:-}" \
    DROIDMATCH_REDACT_LIST_PATH="${list_path:-}" \
    DROIDMATCH_REDACT_LIST_ERROR_PATH="${list_expect_error_path:-}" \
    DROIDMATCH_REDACT_DOWNLOAD_SOURCE_PATH="${download_source_path:-}" \
    DROIDMATCH_REDACT_DOWNLOAD_ERROR_PATH="${download_open_expect_error_path:-}" \
    DROIDMATCH_REDACT_UPLOAD_DESTINATION_PATH="${upload_destination_path:-}" \
    DROIDMATCH_REDACT_MIXED_DESTINATION_PATH="${mixed_upload_destination_path:-}" \
    DROIDMATCH_REDACT_PREPARED_SOURCE_PATH="${prepared_app_sandbox_source_path:-}" \
    redact_m1_output
}

print_redacted_output() {
  printf '%s\n' "$1" | redacted_output
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
  print_redacted_output "${output}"
}

install_debug_apk() {
  local output
  if output="$("${adb_bin}" -s "${serial}" install -r -g "${apk_path}" 2>&1)"; then
    print_redacted_output "${output}"
    return 0
  fi

  if grep -q 'INSTALL_FAILED_USER_RESTRICTED' <<<"${output}"; then
    fail_with_log "adb install" "${output}

English: the Android device rejected ADB package installation. Unlock the
device, open Developer options, enable USB debugging and Install via USB (some
OEM builds call this USB install or USB debugging security settings), then run
this script again.

中文：Android 设备拒绝通过 ADB 安装 APK。请解锁手机，进入开发者选项，打开
USB 调试和“通过 USB 安装/USB 安装”（部分厂商还叫“USB 调试（安全设置）”），
然后重新运行本脚本。"
  fi

  fail_with_log "adb install" "${output}"
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
  printf '%s failed:\n%s\n' "${stage}" "${output}" | redacted_output >&2
  exit 1
}

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

git_worktree_has_non_evidence_changes() {
  local status_entry status path status_file
  status_file="$(mktemp "${TMPDIR:-/tmp}/droidmatch-git-status.XXXXXX")" || return 2
  if ! git status --porcelain=v1 -z --untracked-files=all >"${status_file}" 2>/dev/null; then
    rm -f "${status_file}"
    return 2
  fi
  while IFS= read -r -d '' status_entry; do
    status="${status_entry:0:2}"
    path="${status_entry:3}"

    # A preceding device-smoke run creates this untracked, redacted evidence
    # after the APK was built. Ignore only that exact generated shape; tracked
    # evidence edits and every other worktree change still make the run dirty.
    if [[ "${status}" == "??" && \
          "${path}" =~ ^fixtures/m1-runs/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z-adb-[0-9a-f]{8}\.md$ ]]; then
      continue
    fi
    rm -f "${status_file}"
    return 0
  done <"${status_file}"
  rm -f "${status_file}"
  return 1
}

git_commit_for_evidence() {
  local commit worktree_state
  commit="$(git rev-parse --short HEAD 2>/dev/null)" || {
    printf '%s\n' 'unknown'
    return
  }
  if git_worktree_has_non_evidence_changes; then
    printf '%s-dirty\n' "${commit}"
    return
  else
    worktree_state=$?
  fi
  if [[ "${worktree_state}" -eq 1 ]]; then
    printf '%s\n' "${commit}"
  else
    printf '%s\n' 'unknown'
  fi
}

throughput_mib_per_second() {
  local bytes="$1" elapsed_ms="$2"
  awk -v bytes="${bytes}" -v elapsed_ms="${elapsed_ms}" 'BEGIN {
    if ((elapsed_ms + 0) <= 0) {
      printf "0.00"
    } else {
      printf "%.2f", (bytes + 0) / 1048576 / ((elapsed_ms + 0) / 1000)
    }
  }'
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

download_elapsed_ms_from_output() {
  local output observed
  output="$(cat)"
  observed="$(printf '%s\n' "${output}" | sed -n 's/.*download passed .*elapsed_ms=\([0-9][0-9]*\).*/\1/p' | tail -1)"
  printf '%s\n' "${observed}"
}

upload_elapsed_ms_from_output() {
  local output observed
  output="$(cat)"
  observed="$(printf '%s\n' "${output}" | sed -n 's/.*upload passed .*elapsed_ms=\([0-9][0-9]*\).*/\1/p' | tail -1)"
  printf '%s\n' "${observed}"
}

list_elapsed_ms_from_output() {
  local output observed
  output="$(cat)"
  observed="$(printf '%s\n' "${output}" | sed -n 's/.*list-dir passed .*elapsed_ms=\([0-9][0-9]*\).*/\1/p' | tail -1)"
  printf '%s\n' "${observed}"
}

download_throughput_from_output() {
  local output observed
  output="$(cat)"
  observed="$(printf '%s\n' "${output}" | sed -n 's/.*download passed .*throughput_mib_per_sec=\([0-9][0-9.]*\).*/\1/p' | tail -1)"
  printf '%s\n' "${observed}"
}

upload_throughput_from_output() {
  local output observed
  output="$(cat)"
  observed="$(printf '%s\n' "${output}" | sed -n 's/.*upload passed .*throughput_mib_per_sec=\([0-9][0-9.]*\).*/\1/p' | tail -1)"
  printf '%s\n' "${observed}"
}

decimal_greater_than_zero() {
  awk -v value="$1" 'BEGIN { exit !((value + 0) > 0) }'
}

decimal_less_than() {
  awk -v observed="$1" -v required="$2" 'BEGIN { exit !((observed + 0) < (required + 0)) }'
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

assert_min_download_throughput() {
  if ! decimal_greater_than_zero "${min_download_mib_per_second}"; then
    return
  fi
  if [[ -z "${download_throughput_mib_per_second}" ]]; then
    fail_with_log "download throughput assertion" \
      "Could not parse download throughput from harness output."
  fi
  if decimal_less_than "${download_throughput_mib_per_second}" "${min_download_mib_per_second}"; then
    fail_with_log "download throughput assertion" \
      "download throughput ${download_throughput_mib_per_second} MiB/s, below required minimum ${min_download_mib_per_second} MiB/s."
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

assert_min_upload_throughput() {
  if ! decimal_greater_than_zero "${min_upload_mib_per_second}"; then
    return
  fi
  if [[ -z "${upload_throughput_mib_per_second}" ]]; then
    fail_with_log "upload throughput assertion" \
      "Could not parse upload throughput from harness output."
  fi
  if decimal_less_than "${upload_throughput_mib_per_second}" "${min_upload_mib_per_second}"; then
    fail_with_log "upload throughput assertion" \
      "upload throughput ${upload_throughput_mib_per_second} MiB/s, below required minimum ${min_upload_mib_per_second} MiB/s."
  fi
}

download_throughput_suffix() {
  if [[ -z "${download_throughput_mib_per_second}" ]]; then
    return
  fi
  printf '; throughput %s MiB/s' "${download_throughput_mib_per_second}"
  if [[ -n "${download_elapsed_ms}" ]]; then
    printf ' over %s ms' "${download_elapsed_ms}"
  fi
  if decimal_greater_than_zero "${min_download_mib_per_second}"; then
    printf ' (required >= %s MiB/s)' "${min_download_mib_per_second}"
  fi
}

upload_throughput_suffix() {
  if [[ -z "${upload_throughput_mib_per_second}" ]]; then
    return
  fi
  printf '; throughput %s MiB/s' "${upload_throughput_mib_per_second}"
  if [[ -n "${upload_elapsed_ms}" ]]; then
    printf ' over %s ms' "${upload_elapsed_ms}"
  fi
  if decimal_greater_than_zero "${min_upload_mib_per_second}"; then
    printf ' (required >= %s MiB/s)' "${min_upload_mib_per_second}"
  fi
}

adb_baseline_download_throughput_suffix() {
  if [[ -z "${adb_baseline_download_throughput_mib_per_second}" ]]; then
    return
  fi
  printf '; throughput %s MiB/s' "${adb_baseline_download_throughput_mib_per_second}"
  if [[ -n "${adb_baseline_download_elapsed_ms}" ]]; then
    printf ' over %s ms' "${adb_baseline_download_elapsed_ms}"
  fi
}

assert_retry_recovered() {
  local label="$1" output="$2"
  if ! grep -q 'recovered=true' <<<"${output}"; then
    fail_with_log "${label}" \
      "Fault proxy was enabled, but harness output did not report recovered=true.
${output}"
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
  print_redacted_output "${prepare_app_sandbox_output}"
}

reserve_disposable_app_sandbox_paths() {
  [[ "${require_disposable_app_sandbox_paths}" -eq 1 ]] || return 0

  local path upload_name
  upload_name="${upload_destination_path#dm://app-sandbox/}"
  for path in \
    "files/droidmatch-sandbox/${prepare_app_sandbox_file}" \
    "files/droidmatch-sandbox/${upload_name}" \
    "files/droidmatch-sandbox/.${upload_name}.droidmatch-upload-part"; do
    if ! "${adb_bin}" -s "${serial}" shell run-as app.droidmatch test ! -e "${path}" \
        >/dev/null 2>&1; then
      fail_with_log "disposable app-sandbox path reservation" \
        "A requested disposable app-sandbox path was not absent before the run."
    fi
  done
  # The strict wrapper treats this private marker as the ownership boundary:
  # cleanup is allowed only after all three paths were proven absent.
  printf '%s\n' 'disposable app-sandbox paths reserved'
}

mutate_prepared_app_sandbox_source_after_partial_download() {
  [[ "${download_resume_source_mutation_check}" -eq 1 ]] || return 0

  local after_bytes append_output before_bytes
  # Only change the disposable file this script created. 仅修改本脚本创建的可清理临时文件。
  before_bytes="$(capture_or_exit "read source size before mutation" \
    "${adb_bin}" -s "${serial}" shell \
      "run-as app.droidmatch sh -c 'wc -c < files/droidmatch-sandbox/${prepare_app_sandbox_file}'")"
  before_bytes="$(printf '%s\n' "${before_bytes}" | awk 'NR == 1 { print $1 }')"
  append_output="$(capture_or_exit "append byte to prepared source" \
    "${adb_bin}" -s "${serial}" shell \
      "run-as app.droidmatch sh -c 'printf x >> files/droidmatch-sandbox/${prepare_app_sandbox_file}'")"
  after_bytes="$(capture_or_exit "read source size after mutation" \
    "${adb_bin}" -s "${serial}" shell \
      "run-as app.droidmatch sh -c 'wc -c < files/droidmatch-sandbox/${prepare_app_sandbox_file}'")"
  after_bytes="$(printf '%s\n' "${after_bytes}" | awk 'NR == 1 { print $1 }')"
  if ! [[ "${before_bytes}" =~ ^[0-9]+$ && "${after_bytes}" =~ ^[0-9]+$ ]] \
      || (( after_bytes != before_bytes + 1 )); then
    fail_with_log "source mutation" \
      "Prepared app-sandbox source size did not grow by one byte (before=${before_bytes:-unknown}, after=${after_bytes:-unknown})."
  fi
  download_source_mutation_output="$(
    {
      printf 'source: dm://app-sandbox/%s\n' "${prepare_app_sandbox_file}"
      printf 'mutation: appended one byte after partial download\n'
      printf 'bytes_before=%s bytes_after=%s\n' "${before_bytes}" "${after_bytes}"
      if [[ -n "${append_output}" ]]; then
        printf 'adb output:\n%s\n' "${append_output}"
      fi
    }
  )"
  print_redacted_output "${download_source_mutation_output}"
}

assert_source_mutation_resume_rejected() {
  local output="$1" status="$2"
  if [[ "${status}" -eq 0 ]]; then
    fail_with_log "source mutation resume" \
      "Resume unexpectedly succeeded after the prepared source changed.\n${output}"
  fi
  # HarnessPrivacy deliberately keeps only the stable wire code in direct CLI
  # failures. Accept the historical detailed form too so archived scripts stay
  # readable, but never require provider text at this boundary.
  if ! grep -Eq 'remote error(:[[:space:]]|[[:space:]])invalidArgument([:[:space:]]|$)' <<<"${output}"; then
    fail_with_log "source mutation resume" \
      "Expected invalidArgument source fingerprint rejection after mutation.\n${output}"
  fi
}

delete_prepared_app_sandbox_source_after_partial_download() {
  [[ "${download_resume_source_deletion_check}" -eq 1 ]] || return 0

  local delete_output verify_output
  # Only delete the disposable file this script created. 仅删除本脚本创建的可清理临时文件。
  delete_output="$(capture_or_exit "delete prepared source" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch rm -f \
      "files/droidmatch-sandbox/${prepare_app_sandbox_file}")"
  verify_output="$(capture_or_exit "verify prepared source deletion" \
    "${adb_bin}" -s "${serial}" shell \
      "run-as app.droidmatch sh -c 'test ! -e files/droidmatch-sandbox/${prepare_app_sandbox_file}'")"
  download_source_deletion_output="$(
    {
      printf 'source: dm://app-sandbox/%s\n' "${prepare_app_sandbox_file}"
      printf 'deletion: removed source after partial download\n'
      if [[ -n "${delete_output}" ]]; then
        printf 'adb delete output:\n%s\n' "${delete_output}"
      fi
      if [[ -n "${verify_output}" ]]; then
        printf 'adb verification output:\n%s\n' "${verify_output}"
      fi
    }
  )"
  print_redacted_output "${download_source_deletion_output}"
}

restore_prepared_app_sandbox_source_after_resume_check() {
  if [[ -z "${prepare_app_sandbox_file}" ]] \
      || ( [[ "${download_resume_source_mutation_check}" -ne 1 ]] \
        && [[ "${download_resume_source_deletion_check}" -ne 1 ]] ); then
    return 0
  fi

  local mebibytes mkdir_output dd_output stat_output
  mebibytes=$((prepare_app_sandbox_bytes / 1048576))
  # Source mutation/deletion checks are intentionally destructive. Restore the
  # disposable source before later cancel/pause probes. 先恢复临时源，避免后续探针互相污染。
  mkdir_output="$(capture_or_exit "restore app sandbox directory" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch mkdir -p files/droidmatch-sandbox)"
  dd_output="$(capture_or_exit "restore app sandbox source" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch dd \
      if=/dev/zero \
      "of=files/droidmatch-sandbox/${prepare_app_sandbox_file}" \
      bs=1048576 \
      "count=${mebibytes}")"
  stat_output="$(capture_or_exit "verify restored app sandbox source" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch ls -l \
      "files/droidmatch-sandbox/${prepare_app_sandbox_file}")"
  download_source_resume_restore_output="$({
    printf 'source: dm://app-sandbox/%s\n' "${prepare_app_sandbox_file}"
    printf 'restore: recreated disposable source before subsequent probes\n'
    printf 'bytes: %s\n' "${prepare_app_sandbox_bytes}"
    if [[ -n "${mkdir_output}" ]]; then
      printf 'adb mkdir output:\n%s\n' "${mkdir_output}"
    fi
    if [[ -n "${dd_output}" ]]; then
      printf 'adb dd output:\n%s\n' "${dd_output}"
    fi
    if [[ -n "${stat_output}" ]]; then
      printf 'adb verification output:\n%s\n' "${stat_output}"
    fi
  })"
  print_redacted_output "${download_source_resume_restore_output}"
}

assert_source_deletion_resume_rejected() {
  local output="$1" status="$2"
  if [[ "${status}" -eq 0 ]]; then
    fail_with_log "source deletion resume" \
      "Resume unexpectedly succeeded after the prepared source was deleted.\n${output}"
  fi
  if ! grep -Eq 'remote error(:[[:space:]]|[[:space:]])notFound([:[:space:]]|$)' <<<"${output}"; then
    fail_with_log "source deletion resume" \
      "Expected notFound download-source rejection after deletion.\n${output}"
  fi
}

run_adb_baseline_download_to_file() {
  local destination="$1"
  "${adb_bin}" -s "${serial}" exec-out run-as app.droidmatch cat \
    "files/droidmatch-sandbox/${prepare_app_sandbox_file}" > "${destination}"
}

run_adb_baseline_download() {
  [[ "${adb_baseline_download_check}" -eq 1 ]] || return 0

  local command_output finished_ms started_ms temp_file
  temp_file="$(mktemp /tmp/droidmatch-adb-baseline-download.XXXXXX)"
  adb_baseline_download_temp_file="${temp_file}"

  started_ms="$(now_ms)"
  command_output="$(capture_or_exit "adb baseline download" run_adb_baseline_download_to_file "${temp_file}")"
  finished_ms="$(now_ms)"

  adb_baseline_download_elapsed_ms=$((finished_ms - started_ms))
  adb_baseline_download_bytes="$(wc -c < "${temp_file}" | tr -d '[:space:]')"
  rm -f "${temp_file}"
  adb_baseline_download_temp_file=""
  adb_baseline_download_throughput_mib_per_second="$(
    throughput_mib_per_second "${adb_baseline_download_bytes}" "${adb_baseline_download_elapsed_ms}"
  )"
  adb_baseline_download_output="$(
    {
      printf 'command: adb exec-out run-as app.droidmatch cat files/droidmatch-sandbox/%s > <temp-file>\n' "${prepare_app_sandbox_file}"
      printf 'source: dm://app-sandbox/%s\n' "${prepare_app_sandbox_file}"
      printf 'adb baseline download passed bytes=%s expected_bytes=%s elapsed_ms=%s throughput_mib_per_sec=%s\n' \
        "${adb_baseline_download_bytes}" \
        "${prepare_app_sandbox_bytes}" \
        "${adb_baseline_download_elapsed_ms}" \
        "${adb_baseline_download_throughput_mib_per_second}"
      if [[ -n "${command_output}" ]]; then
        printf 'adb output:\n%s\n' "${command_output}"
      fi
    }
  )"
  print_redacted_output "${adb_baseline_download_output}"

  if (( adb_baseline_download_bytes != prepare_app_sandbox_bytes )); then
    fail_with_log "adb baseline download size assertion" \
      "adb baseline download copied ${adb_baseline_download_bytes} byte(s), expected ${prepare_app_sandbox_bytes}.
${adb_baseline_download_output}"
  fi
}

write_media_permission_revoke_download_permission_case() {
  local outcome="${media_permission_revoke_download_outcome:-not recorded}"

  if [[ "${final_status}" == "passed" \
      && ( "${outcome}" == "completed_after_revoke" \
        || "${outcome}" == "transport_lost_after_revoke" ) ]]; then
    printf 'permission cases: launcher entry resolved to `DroidMatchActivity`; media permission revoked during download check passed for `%s` with outcome `%s`; prior grants were restored\n' \
      "${download_source_path}" "${outcome}"
  elif [[ "${final_status}" == "failed" ]]; then
    printf 'permission cases: launcher entry resolved to `DroidMatchActivity`; media permission revoked during download check attempted for `%s` but did not complete; run failed at stage `%s`; recorded outcome `%s`; cleanup will restore prior grants if permission mutation started\n' \
      "${download_source_path}" "${failure_stage:-not recorded}" "${outcome}"
  else
    printf 'permission cases: launcher entry resolved to `DroidMatchActivity`; media permission revoked during download check requested for `%s` but did not complete with an accepted outcome; recorded outcome `%s`\n' \
      "${download_source_path}" "${outcome}"
  fi
}

publish_staged_m1_log() {
  local staged_log="$1" result_path="$2"
  [[ -f "${staged_log}" && ! -L "${staged_log}" ]] || return 1
  [[ ! -e "${result_path}" && ! -L "${result_path}" ]] || return 1
  bash tools/check-m1-run-logs.sh --log "${staged_log}" >/dev/null 2>&1 \
    || return 1
  ln -n "${staged_log}" "${result_path}" 2>/dev/null || return 1
  rm -f "${staged_log}"
}

write_result_log() {
  [[ "${record_log}" -eq 1 ]] || return 0

  local staged_log
  mkdir -p "$(dirname "${result_log}")" || return 1
  [[ ! -e "${result_log}" && ! -L "${result_log}" ]] || return 1
  staged_log="$(mktemp "$(dirname "${result_log}")/.m1-device-smoke.XXXXXX")" \
    || return 1
  if ! {
    printf '# %s ADB Device Smoke\n\n' "${run_started_utc}"
    printf 'status: %s\n' "${final_status}"
    if [[ "${final_status}" == "failed" ]]; then
      printf 'failure stage: %s\n' "${failure_stage}"
    fi
    printf 'date: %s\n' "${run_started_utc}"
    printf 'device slot: %s\n' "${device_slot}"
    printf 'manufacturer/model: %s %s\n' "${device_manufacturer}" "${device_model}"
    printf 'android version/api: Android %s / API %s\n' "${android_release}" "${sdk_int}"
    printf 'build channel: local release Swift harness + debug APK from git %s\n' "${git_commit}"
    printf 'transport: ADB forward to debug harness Activity endpoint\n'
    printf 'handshake attempts: %s/%s passed via `m1-smoke` (minimum %s)\n' "${m1_smoke_passes}" "${handshake_attempts}" "${min_handshake_passes}"
    if [[ "${dual_download_check}" -eq 1 && -n "${dual_download_output}" ]]; then
      printf 'dual-stream download: `dual-download-smoke` passed with two active streams for `%s` and a responsive heartbeat\n' "${download_source_path}"
    elif [[ "${dual_download_check}" -eq 1 ]]; then
      printf 'dual-stream download: requested for `%s` but did not complete\n' "${download_source_path}"
    else
      printf 'dual-stream download: not run\n'
    fi
    if [[ "${mixed_transfer_check}" -eq 1 && -n "${mixed_transfer_output}" ]]; then
      printf 'mixed-stream transfer: `mixed-transfer-smoke` passed one download from `%s`, one upload to `%s`, and a responsive heartbeat on the same async session\n' \
        "${download_source_path}" "${mixed_upload_destination_path}"
    elif [[ "${mixed_transfer_check}" -eq 1 ]]; then
      printf 'mixed-stream transfer: requested for `%s` but did not complete\n' "${download_source_path}"
    else
      printf 'mixed-stream transfer: not run\n'
    fi
    printf 'visible time: device already authorized over USB before script start\n'
    if [[ -n "${list_path}" && -n "${list_time_ms}" && "${max_list_ms}" -gt 0 ]]; then
      printf 'first list time: %s ms for `%s` (max %s ms)\n' "${list_time_ms}" "${list_path}" "${max_list_ms}"
    elif [[ -n "${list_path}" && -n "${list_time_ms}" ]]; then
      printf 'first list time: %s ms for `%s`\n' "${list_time_ms}" "${list_path}"
    elif [[ -n "${list_path}" ]]; then
      printf 'first list time: not completed for `%s`\n' "${list_path}"
    else
      printf 'first list time: not measured by this script\n'
    fi
    if [[ "${adb_baseline_download_check}" -eq 1 && -n "${adb_baseline_download_bytes}" ]]; then
      printf 'adb baseline download: `exec-out run-as cat` read `dm://app-sandbox/%s`; bytes %s expected %s%s\n' \
        "${prepare_app_sandbox_file}" \
        "${adb_baseline_download_bytes}" \
        "${prepare_app_sandbox_bytes}" \
        "$(adb_baseline_download_throughput_suffix)"
    elif [[ "${adb_baseline_download_check}" -eq 1 ]]; then
      printf 'adb baseline download: requested for `dm://app-sandbox/%s` but did not complete\n' "${prepare_app_sandbox_file}"
    else
      printf 'adb baseline download: not run\n'
    fi
    if [[ "${download_resume_source_deletion_check}" -eq 1 && "${final_status}" == "passed" ]]; then
      printf '100MB download: source-deletion check used a 1MiB script-created source; partial download completed for `%s`, script removed the source, and resume correctly returned not-found; 100MB size not asserted\n' "${download_source_path}"
    elif [[ "${download_resume_source_mutation_check}" -eq 1 && "${final_status}" == "passed" ]]; then
      printf '100MB download: source-mutation check used a 1MiB script-created source; partial download completed for `%s`, script appended one byte, and resume correctly rejected the changed source fingerprint; 100MB size not asserted\n' "${download_source_path}"
    elif [[ "${media_permission_revoked_during_download_check}" -eq 1 \
        && "${final_status}" == "passed" \
        && "${media_permission_revoke_download_outcome}" == "completed_after_revoke" ]]; then
      printf '100MB download: media permission revoked during `%s`; download still completed; 100MB size not asserted%s\n' "${download_source_path}" "$(download_throughput_suffix)"
    elif [[ "${media_permission_revoked_during_download_check}" -eq 1 \
        && "${final_status}" == "passed" \
        && "${media_permission_revoke_download_outcome}" == "transport_lost_after_revoke" ]]; then
      printf '100MB download: media permission revoked during `%s`; observed expected transport loss after revoke; 100MB size not asserted\n' "${download_source_path}"
    elif [[ "${resume_check}" -eq 1 && "${final_status}" == "passed" && "${min_download_bytes}" -gt 0 ]]; then
      printf '100MB download: partial download plus resume passed for `%s`; bytes %s >= required %s%s\n' "${download_source_path}" "${download_bytes_received:-unknown}" "${min_download_bytes}" "$(download_throughput_suffix)"
    elif [[ "${resume_check}" -eq 1 && "${final_status}" == "passed" ]]; then
      printf '100MB download: partial download plus resume passed for `%s`; 100MB size not asserted%s\n' "${download_source_path}" "$(download_throughput_suffix)"
    elif [[ "${resume_check}" -eq 1 && -n "${download_bytes_received}" && "${min_download_bytes}" -gt 0 ]]; then
      if (( download_bytes_received >= min_download_bytes )); then
        printf '100MB download: partial download plus resume transferred `%s`; bytes %s >= required %s%s; final status failed after transfer\n' "${download_source_path}" "${download_bytes_received}" "${min_download_bytes}" "$(download_throughput_suffix)"
      else
        printf '100MB download: partial download plus resume transferred `%s`; bytes %s below required %s%s; final status failed after transfer\n' "${download_source_path}" "${download_bytes_received}" "${min_download_bytes}" "$(download_throughput_suffix)"
      fi
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
      printf '100MB download: `download` command passed for `%s`; bytes %s >= required %s%s\n' "${download_source_path}" "${download_bytes_received:-unknown}" "${min_download_bytes}" "$(download_throughput_suffix)"
    elif [[ -n "${download_source_path}" && "${final_status}" == "passed" ]]; then
      printf '100MB download: `download` command passed for `%s`; 100MB size not asserted%s\n' "${download_source_path}" "$(download_throughput_suffix)"
    elif [[ -n "${download_source_path}" && -n "${download_bytes_received}" && "${min_download_bytes}" -gt 0 ]]; then
      if (( download_bytes_received >= min_download_bytes )); then
        printf '100MB download: `download` command transferred `%s`; bytes %s >= required %s%s; final status failed after transfer\n' "${download_source_path}" "${download_bytes_received}" "${min_download_bytes}" "$(download_throughput_suffix)"
      else
        printf '100MB download: `download` command transferred `%s`; bytes %s below required %s%s; final status failed after transfer\n' "${download_source_path}" "${download_bytes_received}" "${min_download_bytes}" "$(download_throughput_suffix)"
      fi
    elif [[ -n "${download_source_path}" ]]; then
      printf '100MB download: `download` requested for `%s` but did not complete; 100MB size not asserted\n' "${download_source_path}"
    else
      printf '100MB download: not run\n'
    fi
    if [[ "${upload_resume_check}" -eq 1 && "${final_status}" == "passed" && "${min_upload_bytes}" -gt 0 ]]; then
      printf '100MB upload: partial upload plus resume passed to `%s`; bytes %s >= required %s%s\n' "${upload_destination_path}" "${upload_bytes_sent:-unknown}" "${min_upload_bytes}" "$(upload_throughput_suffix)"
    elif [[ "${upload_resume_check}" -eq 1 && "${final_status}" == "passed" ]]; then
      printf '100MB upload: partial upload plus resume passed to `%s`; 100MB size not asserted%s\n' "${upload_destination_path}" "$(upload_throughput_suffix)"
    elif [[ "${upload_resume_check}" -eq 1 && -n "${upload_bytes_sent}" && "${min_upload_bytes}" -gt 0 ]]; then
      if (( upload_bytes_sent >= min_upload_bytes )); then
        printf '100MB upload: partial upload plus resume transferred to `%s`; bytes %s >= required %s%s; final status failed after transfer\n' "${upload_destination_path}" "${upload_bytes_sent}" "${min_upload_bytes}" "$(upload_throughput_suffix)"
      else
        printf '100MB upload: partial upload plus resume transferred to `%s`; bytes %s below required %s%s; final status failed after transfer\n' "${upload_destination_path}" "${upload_bytes_sent}" "${min_upload_bytes}" "$(upload_throughput_suffix)"
      fi
    elif [[ "${upload_resume_check}" -eq 1 ]]; then
      printf '100MB upload: upload-resume-check requested to `%s` but did not complete; 100MB size not asserted\n' "${upload_destination_path}"
    elif [[ "${upload_resume_unsupported_check}" -eq 1 && -n "${upload_source_file}" && "${final_status}" == "passed" && "${min_upload_bytes}" -gt 0 ]]; then
      printf '100MB upload: fresh-only resume unsupported check and `upload` passed to `%s`; bytes %s >= required %s%s\n' "${upload_destination_path}" "${upload_bytes_sent:-unknown}" "${min_upload_bytes}" "$(upload_throughput_suffix)"
    elif [[ "${upload_resume_unsupported_check}" -eq 1 && -n "${upload_source_file}" && "${final_status}" == "passed" ]]; then
      printf '100MB upload: fresh-only resume unsupported check and `upload` passed to `%s`; 100MB size not asserted%s\n' "${upload_destination_path}" "$(upload_throughput_suffix)"
    elif [[ "${upload_resume_unsupported_check}" -eq 1 && -n "${upload_source_file}" ]]; then
      printf '100MB upload: fresh-only resume unsupported check requested for `%s` but did not complete; 100MB size not asserted\n' "${upload_destination_path}"
    elif [[ -n "${upload_source_file}" && "${final_status}" == "passed" && "${min_upload_bytes}" -gt 0 ]]; then
      printf '100MB upload: `upload` command passed to `%s`; bytes %s >= required %s%s\n' "${upload_destination_path}" "${upload_bytes_sent:-unknown}" "${min_upload_bytes}" "$(upload_throughput_suffix)"
    elif [[ -n "${upload_source_file}" && "${final_status}" == "passed" ]]; then
      printf '100MB upload: `upload` command passed to `%s`; 100MB size not asserted%s\n' "${upload_destination_path}" "$(upload_throughput_suffix)"
    elif [[ -n "${upload_source_file}" && -n "${upload_bytes_sent}" && "${min_upload_bytes}" -gt 0 ]]; then
      if (( upload_bytes_sent >= min_upload_bytes )); then
        printf '100MB upload: `upload` command transferred to `%s`; bytes %s >= required %s%s; final status failed after transfer\n' "${upload_destination_path}" "${upload_bytes_sent}" "${min_upload_bytes}" "$(upload_throughput_suffix)"
      else
        printf '100MB upload: `upload` command transferred to `%s`; bytes %s below required %s%s; final status failed after transfer\n' "${upload_destination_path}" "${upload_bytes_sent}" "${min_upload_bytes}" "$(upload_throughput_suffix)"
      fi
    elif [[ -n "${upload_source_file}" ]]; then
      printf '100MB upload: `upload` requested to `%s` but did not complete; 100MB size not asserted\n' "${upload_destination_path}"
    else
      printf '100MB upload: not run\n'
    fi
    if [[ "${download_resume_source_deletion_check}" -eq 1 && "${final_status}" == "passed" ]]; then
      printf 'resume result: partial stop after at least %s byte(s), then the deleted source was rejected with stable code `notFound` (provider detail redacted)\n' "${resume_partial_bytes}"
    elif [[ "${download_resume_source_mutation_check}" -eq 1 && "${final_status}" == "passed" ]]; then
      printf 'resume result: partial stop after at least %s byte(s), then the changed source was rejected with stable code `invalidArgument` (fingerprint detail redacted)\n' "${resume_partial_bytes}"
    elif [[ "${resume_check}" -eq 1 && "${final_status}" == "passed" ]]; then
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
    if [[ "${media_permission_revoked_during_download_check}" -eq 1 ]]; then
      write_media_permission_revoke_download_permission_case
    elif [[ "${media_permission_revoked_check}" -eq 1 \
        && -n "${list_expect_error_output}" \
        && -n "${download_open_expect_error_output}" ]]; then
      printf 'permission cases: launcher entry resolved to `DroidMatchActivity`; media permission revoked check passed for `%s` with `%s`; download open expected-error check passed for `%s` with `%s`\n' "${list_expect_error_path}" "${list_expect_error_code}" "${download_open_expect_error_path}" "${download_open_expect_error_code}"
    elif [[ "${media_permission_revoked_check}" -eq 1 && -n "${list_expect_error_output}" ]]; then
      printf 'permission cases: launcher entry resolved to `DroidMatchActivity`; media permission revoked check passed for `%s` with `%s`\n' "${list_expect_error_path}" "${list_expect_error_code}"
    elif [[ -n "${list_expect_error_output}" && -n "${download_open_expect_error_output}" ]]; then
      printf 'permission cases: launcher entry resolved to `DroidMatchActivity`; list expected-error check passed for `%s` with `%s`; download open expected-error check passed for `%s` with `%s`\n' "${list_expect_error_path}" "${list_expect_error_code}" "${download_open_expect_error_path}" "${download_open_expect_error_code}"
    elif [[ -n "${list_expect_error_output}" ]]; then
      printf 'permission cases: launcher entry resolved to `DroidMatchActivity`; list expected-error check passed for `%s` with `%s`\n' "${list_expect_error_path}" "${list_expect_error_code}"
    elif [[ -n "${download_open_expect_error_output}" ]]; then
      printf 'permission cases: launcher entry resolved to `DroidMatchActivity`; download open expected-error check passed for `%s` with `%s`\n' "${download_open_expect_error_path}" "${download_open_expect_error_code}"
    else
      printf 'permission cases: launcher entry resolved to `DroidMatchActivity`; detailed permission-denied cases not run\n'
    fi
    printf 'diagnostics bundle: `m1-smoke` output included below\n'
    printf 'notes:\n\n'
    printf '%s\n' "- serial redaction tag: \`<serial-redacted:${serial_tag}>\`"
    printf '%s\n' "- remote port: \`${remote_port}\`"
    printf '%s\n' "- local port: \`${allocated_local_port}\`"
    printf '%s\n' '- launcher: `app.droidmatch/app.droidmatch.m1.DroidMatchActivity`'
    printf '%s\n' "- m1-smoke failures: \`${m1_smoke_failures}\`"
    if [[ -n "${list_path}" ]]; then
      printf '%s\n' "- timed list path: \`${list_path}\`"
    fi
    if [[ -n "${list_wall_time_ms}" ]]; then
      printf '%s\n' "- timed list command wall time: \`${list_wall_time_ms} ms\`"
    fi
    if [[ "${max_list_ms}" -gt 0 ]]; then
      printf '%s\n' "- max list time: \`${max_list_ms} ms\`"
    fi
    if [[ -n "${list_expect_error_path}" ]]; then
      printf '%s\n' "- list expected-error path: \`${list_expect_error_path}\`"
      printf '%s\n' "- list expected-error code: \`${list_expect_error_code}\`"
    fi
    if [[ "${media_permission_revoked_check}" -eq 1 ]]; then
      printf '%s\n' '- media permission revoked check: revoked media read permission before the expected list error, then restored prior grants'
    fi
    if [[ "${media_permission_revoked_during_download_check}" -eq 1 ]]; then
      if [[ "${final_status}" == "passed" \
          && ( "${media_permission_revoke_download_outcome}" == "completed_after_revoke" \
            || "${media_permission_revoke_download_outcome}" == "transport_lost_after_revoke" ) ]]; then
        printf '%s\n' '- media permission revoked during download check: revoked media read permission after the first proxied media download chunk, then restored prior grants'
        printf '%s\n' "- media permission revoked during download outcome: \`${media_permission_revoke_download_outcome}\`"
      elif [[ "${final_status}" == "failed" ]]; then
        printf '%s\n' "- media permission revoked during download check: attempted; run failed at stage \`${failure_stage:-not recorded}\` before an accepted outcome was recorded; cleanup restores prior grants if mutation started"
      else
        printf '%s\n' '- media permission revoked during download check: requested but no accepted outcome was recorded'
      fi
    fi
    if [[ -n "${download_open_expect_error_path}" ]]; then
      printf '%s\n' "- download open expected-error path: \`${download_open_expect_error_path}\`"
      printf '%s\n' "- download open expected-error code: \`${download_open_expect_error_code}\`"
    fi
    if [[ "${mixed_transfer_check}" -eq 1 ]]; then
      printf '%s\n' '- mixed transfer check: one async download + one async upload + heartbeat on one session'
      printf '%s\n' "- mixed upload destination: \`${mixed_upload_destination_path}\`"
      printf '%s\n' "- mixed upload bytes: \`${mixed_upload_bytes:-unknown}\`"
      printf '%s\n' "- mixed download bytes: \`${mixed_download_bytes:-unknown}\`"
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
    if [[ "${adb_baseline_download_check}" -eq 1 ]]; then
      printf '%s\n' '- ADB baseline download: enabled via `adb exec-out run-as app.droidmatch cat`'
      if [[ -n "${adb_baseline_download_bytes}" ]]; then
        printf '%s\n' "- ADB baseline download bytes: \`${adb_baseline_download_bytes}\`"
      fi
      if [[ -n "${adb_baseline_download_throughput_mib_per_second}" ]]; then
        printf '%s\n' "- ADB baseline download throughput: \`${adb_baseline_download_throughput_mib_per_second} MiB/s\`"
      fi
      if [[ -n "${adb_baseline_download_elapsed_ms}" ]]; then
        printf '%s\n' "- ADB baseline download elapsed: \`${adb_baseline_download_elapsed_ms} ms\`"
      fi
    fi
    if [[ "${min_download_bytes}" -gt 0 ]]; then
      printf '%s\n' "- min download bytes: \`${min_download_bytes}\`"
      printf '%s\n' "- observed download bytes: \`${download_bytes_received:-unknown}\`"
    fi
    if [[ -n "${download_throughput_mib_per_second}" ]]; then
      printf '%s\n' "- observed download throughput: \`${download_throughput_mib_per_second} MiB/s\`"
      if [[ -n "${download_elapsed_ms}" ]]; then
        printf '%s\n' "- observed download elapsed: \`${download_elapsed_ms} ms\`"
      fi
    fi
    if decimal_greater_than_zero "${min_download_mib_per_second}"; then
      printf '%s\n' "- min download throughput: \`${min_download_mib_per_second} MiB/s\`"
    fi
    if [[ "${download_retry_on_transport_loss}" -eq 1 ]]; then
      printf '%s\n' '- download transport-loss retry: enabled via `download --retry-on-transport-loss`'
      if [[ -n "${retry_max_attempts}" ]]; then
        printf '%s\n' "- download retry max attempts: \`${retry_max_attempts}\`"
      fi
      if [[ -n "${retry_backoff_ms}" ]]; then
        printf '%s\n' "- download retry base backoff: \`${retry_backoff_ms} ms\`"
      fi
    fi
    if [[ "${download_retry_fault_check}" -eq 1 ]]; then
      printf '%s\n' '- download transport-loss fault check: local frame proxy dropped the first transfer connection and required `recovered=true`'
    fi
    if [[ "${download_resume_source_mutation_check}" -eq 1 ]]; then
      printf '%s\n' '- download source mutation check: appended one byte to the script-created app-sandbox source after partial download and required stable `invalidArgument` on resume; fingerprint detail remains redacted'
    fi
    if [[ "${download_resume_source_deletion_check}" -eq 1 ]]; then
      printf '%s\n' '- download source deletion check: removed the script-created app-sandbox source after partial download and required stable `notFound` on resume; provider detail remains redacted'
    fi
    if [[ -n "${download_source_resume_restore_output}" ]]; then
      printf '%s\n' '- download source destructive-check cleanup: recreated the script-created app-sandbox source before subsequent cancel/pause probes'
    fi
    if [[ -n "${upload_source_file}" ]]; then
      printf '%s\n' "- upload destination: \`${upload_destination_path}\`"
      if [[ "${upload_resume_check}" -eq 1 ]]; then
        printf '%s\n' "- upload partial bytes: \`${upload_partial_bytes}\`"
      fi
      if [[ "${upload_retry_on_transport_loss}" -eq 1 ]]; then
        printf '%s\n' '- upload transport-loss retry: enabled via `upload --retry-on-transport-loss`'
        if [[ -n "${retry_max_attempts}" ]]; then
          printf '%s\n' "- upload retry max attempts: \`${retry_max_attempts}\`"
        fi
        if [[ -n "${retry_backoff_ms}" ]]; then
          printf '%s\n' "- upload retry base backoff: \`${retry_backoff_ms} ms\`"
        fi
      fi
      if [[ "${upload_retry_fault_check}" -eq 1 ]]; then
        printf '%s\n' '- upload transport-loss fault check: local frame proxy dropped the first transfer connection and required `recovered=true`'
      fi
      if [[ "${upload_retry_ack_loss_check}" -eq 1 ]]; then
        printf '%s\n' '- upload ACK-loss retry check: local frame proxy dropped the first upload ACK and required `recovered=true`'
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
    if [[ -n "${upload_throughput_mib_per_second}" ]]; then
      printf '%s\n' "- observed upload throughput: \`${upload_throughput_mib_per_second} MiB/s\`"
      if [[ -n "${upload_elapsed_ms}" ]]; then
        printf '%s\n' "- observed upload elapsed: \`${upload_elapsed_ms} ms\`"
      fi
    fi
    if decimal_greater_than_zero "${min_upload_mib_per_second}"; then
      printf '%s\n' "- min upload throughput: \`${min_upload_mib_per_second} MiB/s\`"
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
    if [[ -n "${adb_baseline_download_output}" ]]; then
      printf '```\n\n## ADB Baseline Download Output\n\n```text\n'
      printf '%s\n' "${adb_baseline_download_output}" | redacted_output
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
    if [[ -n "${dual_download_output}" ]]; then
      printf '\n## Dual Download Smoke Output\n\n```text\n'
      printf '%s\n' "${dual_download_output}" | redacted_output
      printf '```\n'
    fi
    if [[ -n "${mixed_transfer_output}" ]]; then
      printf '\n## Mixed Transfer Smoke Output\n\n```text\n'
      printf '%s\n' "${mixed_transfer_output}" | redacted_output
      printf '```\n'
    fi
    if [[ -n "${list_path}" ]]; then
      printf '\n## Timed ListDir Output\n\n```text\n'
      printf '%s\n' "${list_output}" | redacted_list_output
      printf '```\n'
    fi
    if [[ -n "${media_permission_mutation_output}" ]]; then
      printf '\n## Media Permission Mutation Output\n\n```text\n'
      printf '%s\n' "${media_permission_mutation_output}" | redacted_output
      printf '```\n'
    fi
    if [[ -n "${list_expect_error_output}" ]]; then
      printf '\n## ListDir Expected Error Output\n\n```text\n'
      printf '%s\n' "${list_expect_error_output}" | redacted_output
      printf '```\n'
    fi
    if [[ -n "${download_open_expect_error_output}" ]]; then
      printf '\n## Download Open Expected Error Output\n\n```text\n'
      printf '%s\n' "${download_open_expect_error_output}" | redacted_output
      printf '```\n'
    fi
    if [[ "${resume_check}" -eq 1 ]]; then
      printf '\n## Partial Download Output\n\n```text\n'
      printf '%s\n' "${partial_download_output}" | redacted_output
      printf '```\n'
      if [[ -n "${download_source_mutation_output}" ]]; then
        printf '\n## Download Source Mutation Output\n\n```text\n'
        printf '%s\n' "${download_source_mutation_output}" | redacted_output
        printf '```\n'
      fi
      if [[ -n "${download_source_deletion_output}" ]]; then
        printf '\n## Download Source Deletion Output\n\n```text\n'
        printf '%s\n' "${download_source_deletion_output}" | redacted_output
        printf '```\n'
      fi
      if [[ -n "${download_source_resume_restore_output}" ]]; then
        printf '\n## Download Source Restore Output\n\n```text\n'
        printf '%s\n' "${download_source_resume_restore_output}" | redacted_output
        printf '```\n'
      fi
      printf '\n## Resume Download Output\n\n```text\n'
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
  } | redacted_output >"${staged_log}"; then
    rm -f "${staged_log}"
    return 1
  fi

  if ! publish_staged_m1_log "${staged_log}" "${result_log}"; then
    rm -f "${staged_log}"
    return 1
  fi

  printf 'Result log written: <result-log-redacted>\n'
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

cleanup_one_upload_destination() {
  local destination="$1" local_relative parent_relative base_name partial_relative
  if [[ -z "${serial:-}" || -z "${destination}" ]]; then
    return 0
  fi
  if [[ "${destination}" == dm://app-sandbox/* ]]; then
    local_relative="${destination#dm://app-sandbox/}"
    if [[ -n "${local_relative}" && "${local_relative}" != *".."* && "${local_relative}" != /* ]]; then
      parent_relative="${local_relative%/*}"
      base_name="${local_relative##*/}"
      if [[ "${parent_relative}" == "${local_relative}" ]]; then
        partial_relative=".${base_name}.droidmatch-upload-part"
      else
        partial_relative="${parent_relative}/.${base_name}.droidmatch-upload-part"
      fi
      # The final path and the provider's hidden atomic partial are both owned
      # by an explicit smoke cleanup request. Removing only the final could
      # orphan a failed upload and contaminate a later evidence run.
      "${adb_bin}" -s "${serial}" shell run-as app.droidmatch rm -f \
        "files/droidmatch-sandbox/${local_relative}" \
        "files/droidmatch-sandbox/${partial_relative}" >/dev/null 2>&1 || true
    fi
  elif [[ "${destination}" == dm://media-images/* \
      || "${destination}" == dm://media-videos/* ]]; then
    cleanup_mediastore_upload_destination "${destination}"
  elif [[ "${destination}" =~ ^dm://saf-[A-Za-z0-9._-]+/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
      && [[ -n "${allocated_local_port:-}" ]]; then
    # Direct-root SAF paths are stable across sessions, so use the product
    # mutation boundary rather than touching provider URIs from the shell.
    # Nested /doc/<token>/ paths are intentionally rejected before the run and
    # remain manual because their opaque tokens are session-local.
    if ! run_swift_harness delete-path \
        --port "${allocated_local_port}" \
        --timeout-seconds "${timeout_seconds}" \
        --path "${destination}" >/dev/null 2>&1; then
      printf '%s\n' 'SAF upload cleanup failed for <dm-path-redacted>; inspect the device and remove the target manually.' >&2
    fi
  fi
}

cleanup() {
  if [[ -n "${adb_baseline_download_temp_file:-}" ]]; then
    rm -f "${adb_baseline_download_temp_file}" >/dev/null 2>&1 || true
  fi
  # Keep the active forward alive until remote SAF cleanup completes.
  # The remaining cleanup paths use adb shell directly and can run after the
  # forward is removed.
  if [[ "${cleanup_upload_destination:-0}" -eq 1 ]]; then
    cleanup_one_upload_destination "${upload_destination_path:-}"
    if [[ "${mixed_transfer_check:-0}" -eq 1 ]]; then
      cleanup_one_upload_destination "${mixed_upload_destination_path:-}"
    fi
  fi
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
  if [[ ( "${download_resume_source_mutation_check:-0}" -eq 1 \
        || "${download_resume_source_deletion_check:-0}" -eq 1 ) \
      && -n "${download_destination:-}" ]]; then
    rm -f "${download_destination}" \
      "${download_destination}.droidmatch-part" \
      "${download_destination}.droidmatch-transfer.json" >/dev/null 2>&1 || true
  fi
  if [[ -n "${mixed_download_destination:-}" ]]; then
    rm -f "${mixed_download_destination}" \
      "${mixed_download_destination}.droidmatch-part" \
      "${mixed_download_destination}.droidmatch-transfer.json" >/dev/null 2>&1 || true
  fi
  restore_media_permissions_after_check 0 >/dev/null 2>&1 || true
  if [[ -n "${media_permission_revoke_hook_script:-}" ]]; then
    rm -f "${media_permission_revoke_hook_script}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "${skip_build}" -eq 0 ]]; then
  bash tools/check-m1-skeleton.sh
fi

apk_path="android/app/build/outputs/apk/debug/app-debug.apk"
if [[ ! -s "${apk_path}" ]]; then
  printf 'Missing debug APK: <apk-path-redacted>. Run tools/check-m1-skeleton.sh first or omit --skip-build.\n' >&2
  exit 1
fi

select_serial
serial_tag="$(serial_tag_for "${serial}")"
printf 'Using adb device %s\n' "<serial-redacted:${serial_tag}>"

run_started_utc="$(date -u '+%Y-%m-%d %H:%M:%SZ')"
run_started_slug="$(date -u '+%Y-%m-%dT%H-%M-%SZ')"
if [[ -z "${result_log}" ]]; then
  result_log="fixtures/m1-runs/${run_started_slug}-adb-${serial_tag}.md"
fi
if [[ "${record_log}" -eq 1 \
    && ( -e "${result_log}" || -L "${result_log}" ) ]]; then
  printf '%s\n' 'Result log refused: the destination already exists (path redacted).' >&2
  exit 2
fi
git_commit="$(git_commit_for_evidence)"
device_manufacturer="$(device_prop ro.product.manufacturer)"
device_model="$(device_prop ro.product.model)"
android_release="$(device_prop ro.build.version.release)"
sdk_int="$(device_prop ro.build.version.sdk)"

install_output="$(install_debug_apk)"
print_redacted_output "${install_output}"

reserve_disposable_app_sandbox_paths
prepare_app_sandbox_file_on_device
run_adb_baseline_download

launcher_output="$("${adb_bin}" -s "${serial}" shell cmd package resolve-activity --brief \
  -a android.intent.action.MAIN \
  -c android.intent.category.LAUNCHER \
  app.droidmatch 2>/dev/null | tr -d '\r')"
if ! grep -Eq 'app\.droidmatch/(app\.droidmatch)?\.m1\.DroidMatchActivity' <<<"${launcher_output}"; then
  fail_with_log "launcher resolve" \
    "Installed APK does not resolve DroidMatchActivity as the launcher entry.
${launcher_output}"
fi
printf 'Launcher entry verified: app.droidmatch/app.droidmatch.m1.DroidMatchActivity\n'

if [[ "${open_launcher}" -eq 1 ]]; then
  "${adb_bin}" -s "${serial}" shell monkey -p app.droidmatch -c android.intent.category.LAUNCHER 1
fi

"${adb_bin}" -s "${serial}" logcat -c >/dev/null || true
"${adb_bin}" -s "${serial}" shell am force-stop app.droidmatch >/dev/null || true
activity_output="$(capture_or_exit "debug harness Activity start" "${adb_bin}" -s "${serial}" shell am start -W \
  -n app.droidmatch/app.droidmatch.m1.DebugHarnessActivity \
  --ei port "${remote_port}")"
print_redacted_output "${activity_output}"

forward_output="$(capture_or_exit "adb forward" run_swift_harness forward --serial "${serial}" --local-port "${local_port}" --remote-port "${remote_port}")"
printf '%s\n' "${forward_output}" | redacted_output
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
  print_redacted_output "${attempt_output}"
  if [[ -n "${m1_smoke_output}" ]]; then
    m1_smoke_output+=$'\n'
  fi
  m1_smoke_output+="## attempt ${attempt}/${handshake_attempts} ${attempt_status}"$'\n'"${attempt_output}"
done
if (( m1_smoke_passes < min_handshake_passes )); then
  fail_with_log "m1-smoke threshold" \
    "m1-smoke passed ${m1_smoke_passes}/${handshake_attempts} attempts, below required minimum ${min_handshake_passes}."
fi

if [[ "${dual_download_check}" -eq 1 ]]; then
  dual_download_args=(
    dual-download-smoke
    --port "${allocated_local_port}"
    --timeout-seconds "${timeout_seconds}"
    --source-path-a "${download_source_path}"
    --source-path-b "${download_source_path}"
  )
  if [[ -n "${transfer_chunk_size_bytes}" ]]; then
    dual_download_args+=(--chunk-size-bytes "${transfer_chunk_size_bytes}")
  fi
  dual_download_output="$(capture_or_exit "dual-download-smoke" run_swift_harness "${dual_download_args[@]}")"
  print_redacted_output "${dual_download_output}"
  if ! grep -q 'dual-download-smoke passed' <<<"${dual_download_output}"; then
    fail_with_log "dual-download-smoke assertion" \
      "dual-download-smoke exited successfully without its pass marker.\n${dual_download_output}"
  fi
fi

if [[ "${mixed_transfer_check}" -eq 1 ]]; then
  mixed_download_destination="$(mktemp /tmp/droidmatch-mixed-download.XXXXXX)"
  mixed_transfer_args=(
    mixed-transfer-smoke
    --port "${allocated_local_port}"
    --timeout-seconds "${timeout_seconds}"
    --download-source-path "${download_source_path}"
    --download-destination "${mixed_download_destination}"
    --upload-source "${upload_source_file}"
    --upload-destination-path "${mixed_upload_destination_path}"
  )
  if [[ -n "${transfer_chunk_size_bytes}" ]]; then
    mixed_transfer_args+=(--chunk-size-bytes "${transfer_chunk_size_bytes}")
  fi
  mixed_transfer_output="$(capture_or_exit "mixed-transfer-smoke" run_swift_harness "${mixed_transfer_args[@]}")"
  print_redacted_output "${mixed_transfer_output}"
  if ! grep -q 'mixed-transfer-smoke passed' <<<"${mixed_transfer_output}"; then
    fail_with_log "mixed-transfer-smoke assertion" \
      "mixed-transfer-smoke exited successfully without its pass marker.\n${mixed_transfer_output}"
  fi
  mixed_upload_bytes="$(sed -n 's/.* upload_bytes=\([0-9][0-9]*\).*/\1/p' <<<"${mixed_transfer_output}" | tail -1)"
  mixed_download_bytes="$(sed -n 's/.* download_bytes=\([0-9][0-9]*\).*/\1/p' <<<"${mixed_transfer_output}" | tail -1)"
  mixed_download_file_bytes="$(wc -c < "${mixed_download_destination}" | tr -d '[:space:]')"
  if [[ -z "${mixed_upload_bytes}" || "${mixed_upload_bytes}" != "${upload_source_bytes}" ]]; then
    fail_with_log "mixed-transfer-smoke upload size" \
      "mixed upload reported ${mixed_upload_bytes:-unknown} byte(s), expected ${upload_source_bytes}.\n${mixed_transfer_output}"
  fi
  if [[ -z "${mixed_download_bytes}" \
      || "${mixed_download_bytes}" != "${mixed_download_file_bytes}" ]]; then
    fail_with_log "mixed-transfer-smoke download size" \
      "mixed download reported ${mixed_download_bytes:-unknown} byte(s), local file has ${mixed_download_file_bytes}.\n${mixed_transfer_output}"
  fi
fi

download_retry_args=()
if [[ "${download_retry_on_transport_loss}" -eq 1 ]]; then
  download_retry_args+=(--retry-on-transport-loss)
  if [[ -n "${retry_max_attempts}" ]]; then
    download_retry_args+=(--max-retry-attempts "${retry_max_attempts}")
  fi
  if [[ -n "${retry_backoff_ms}" ]]; then
    download_retry_args+=(--retry-backoff-ms "${retry_backoff_ms}")
  fi
fi
upload_retry_args=()
if [[ "${upload_retry_on_transport_loss}" -eq 1 ]]; then
  upload_retry_args+=(--retry-on-transport-loss)
  if [[ -n "${retry_max_attempts}" ]]; then
    upload_retry_args+=(--max-retry-attempts "${retry_max_attempts}")
  fi
  if [[ -n "${retry_backoff_ms}" ]]; then
    upload_retry_args+=(--retry-backoff-ms "${retry_backoff_ms}")
  fi
fi

if [[ -n "${list_path}" ]]; then
  list_started_ms="$(now_ms)"
  list_output="$(capture_or_exit "list-dir" \
    run_swift_harness list-dir --port "${allocated_local_port}" --timeout-seconds "${timeout_seconds}" --path "${list_path}")"
  list_finished_ms="$(now_ms)"
  list_wall_time_ms=$((list_finished_ms - list_started_ms))
  list_time_ms="$(printf '%s\n' "${list_output}" | list_elapsed_ms_from_output)"
  if [[ -z "${list_time_ms}" ]]; then
    list_time_ms="${list_wall_time_ms}"
  fi
  printf '%s\n' "${list_output}" | redacted_list_output
  if [[ "${max_list_ms}" -gt 0 && "${list_time_ms}" -gt "${max_list_ms}" ]]; then
    fail_with_log "list latency assertion" \
      "list-dir ${list_path} took ${list_time_ms} ms, above required maximum ${max_list_ms} ms."
  fi
fi

if [[ "${media_permission_revoked_check}" -eq 1 ]]; then
  revoke_media_permissions_for_check
fi

if [[ -n "${list_expect_error_path}" ]]; then
  list_expect_error_output="$(capture_or_exit "list-dir expected error" \
    run_swift_harness list-dir-expect-error \
      --port "${allocated_local_port}" \
      --timeout-seconds "${timeout_seconds}" \
      --path "${list_expect_error_path}" \
      --expected-error-code "${list_expect_error_code}" \
      ${list_expect_error_message_contains:+--expected-message-contains} \
      ${list_expect_error_message_contains:+"${list_expect_error_message_contains}"})"
  print_redacted_output "${list_expect_error_output}"
fi

if [[ "${media_permission_revoked_check}" -eq 1 ]]; then
  restore_media_permissions_after_check 1
fi

if [[ -n "${download_open_expect_error_path}" ]]; then
  download_open_expect_error_output="$(capture_or_exit "download open expected error" \
    run_swift_harness download-open-expect-error \
      --port "${allocated_local_port}" \
      --timeout-seconds "${timeout_seconds}" \
      --source-path "${download_open_expect_error_path}" \
      --expected-error-code "${download_open_expect_error_code}" \
      ${download_open_expect_error_message_contains:+--expected-message-contains} \
      ${download_open_expect_error_message_contains:+"${download_open_expect_error_message_contains}"} \
      ${transfer_chunk_size_bytes:+--chunk-size} \
      ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"})"
  print_redacted_output "${download_open_expect_error_output}"
fi

if [[ "${resume_check}" -eq 1 ]]; then
  partial_download_output="$(capture_or_exit "partial download" run_swift_harness download \
    --port "${allocated_local_port}" \
    --timeout-seconds "${timeout_seconds}" \
    --source-path "${download_source_path}" \
    --destination "${download_destination}" \
    ${transfer_chunk_size_bytes:+--chunk-size} \
    ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
    --stop-after-bytes "${resume_partial_bytes}")"
  print_redacted_output "${partial_download_output}"

  if [[ "${download_resume_source_deletion_check}" -eq 1 ]]; then
    delete_prepared_app_sandbox_source_after_partial_download
    set +e
    resume_download_output="$(run_swift_harness download \
      --port "${allocated_local_port}" \
      --timeout-seconds "${timeout_seconds}" \
      --source-path "${download_source_path}" \
      --destination "${download_destination}" \
      ${transfer_chunk_size_bytes:+--chunk-size} \
      ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
      --resume 2>&1)"
    resume_download_status=$?
    set -e
    assert_source_deletion_resume_rejected "${resume_download_output}" "${resume_download_status}"
  elif [[ "${download_resume_source_mutation_check}" -eq 1 ]]; then
    mutate_prepared_app_sandbox_source_after_partial_download
    set +e
    resume_download_output="$(run_swift_harness download \
      --port "${allocated_local_port}" \
      --timeout-seconds "${timeout_seconds}" \
      --source-path "${download_source_path}" \
      --destination "${download_destination}" \
      ${transfer_chunk_size_bytes:+--chunk-size} \
      ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
      --resume 2>&1)"
    resume_download_status=$?
    set -e
    assert_source_mutation_resume_rejected "${resume_download_output}" "${resume_download_status}"
  elif [[ "${download_retry_fault_check}" -eq 1 ]]; then
    resume_download_output="$(capture_or_exit "resume download fault retry" run_swift_harness_with_fault_proxy download \
      --timeout-seconds "${timeout_seconds}" \
      --source-path "${download_source_path}" \
      --destination "${download_destination}" \
      ${transfer_chunk_size_bytes:+--chunk-size} \
      ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
      --resume \
      ${download_retry_args[@]+"${download_retry_args[@]}"})"
    assert_retry_recovered "resume download fault retry" "${resume_download_output}"
  else
    resume_download_output="$(capture_or_exit "resume download" run_swift_harness download \
      --port "${allocated_local_port}" \
      --timeout-seconds "${timeout_seconds}" \
      --source-path "${download_source_path}" \
      --destination "${download_destination}" \
      ${transfer_chunk_size_bytes:+--chunk-size} \
      ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
      --resume \
      ${download_retry_args[@]+"${download_retry_args[@]}"})"
  fi
  print_redacted_output "${resume_download_output}"
  download_bytes_received="$(printf '%s\n' "${resume_download_output}" | download_bytes_from_output)"
  download_elapsed_ms="$(printf '%s\n' "${resume_download_output}" | download_elapsed_ms_from_output)"
  download_throughput_mib_per_second="$(printf '%s\n' "${resume_download_output}" | download_throughput_from_output)"
  assert_min_download_bytes
  assert_min_download_throughput
  restore_prepared_app_sandbox_source_after_resume_check
elif [[ -n "${download_source_path}" && "${cancel_check}" -ne 1 && "${pause_check}" -ne 1 ]]; then
  if [[ "${media_permission_revoked_during_download_check}" -eq 1 ]]; then
    prepare_media_permission_revoke_during_download_check
    set +e
    download_output="$(run_swift_harness_with_permission_revoke_fault_proxy download \
      --timeout-seconds "${timeout_seconds}" \
      --source-path "${download_source_path}" \
      --destination "${download_destination}" \
      ${transfer_chunk_size_bytes:+--chunk-size} \
      ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} 2>&1)"
    download_status=$?
    set -e
    assert_fault_proxy_hook_command_succeeded "download media permission revoke hook" "${download_output}"
    record_media_permission_state_after_revoke_during_download
    restore_media_permissions_after_check 1
    if [[ "${download_status}" -eq 0 ]]; then
      media_permission_revoke_download_outcome="completed_after_revoke"
    elif is_expected_permission_revoke_download_failure "${download_output}"; then
      media_permission_revoke_download_outcome="transport_lost_after_revoke"
    else
      fail_with_log "download with media permission revoke" "${download_output}"
    fi
  elif [[ "${download_retry_fault_check}" -eq 1 ]]; then
    download_output="$(capture_or_exit "download fault retry" run_swift_harness_with_fault_proxy download \
      --timeout-seconds "${timeout_seconds}" \
      --source-path "${download_source_path}" \
      --destination "${download_destination}" \
      ${transfer_chunk_size_bytes:+--chunk-size} \
      ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
      ${download_retry_args[@]+"${download_retry_args[@]}"})"
    assert_retry_recovered "download fault retry" "${download_output}"
  else
    download_output="$(capture_or_exit "download" run_swift_harness download \
      --port "${allocated_local_port}" \
      --timeout-seconds "${timeout_seconds}" \
      --source-path "${download_source_path}" \
      --destination "${download_destination}" \
      ${transfer_chunk_size_bytes:+--chunk-size} \
      ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
      ${download_retry_args[@]+"${download_retry_args[@]}"})"
  fi
  print_redacted_output "${download_output}"
  if [[ "${media_permission_revoked_during_download_check}" -ne 1 \
      || "${media_permission_revoke_download_outcome}" == "completed_after_revoke" ]]; then
    download_bytes_received="$(printf '%s\n' "${download_output}" | download_bytes_from_output)"
    download_elapsed_ms="$(printf '%s\n' "${download_output}" | download_elapsed_ms_from_output)"
    download_throughput_mib_per_second="$(printf '%s\n' "${download_output}" | download_throughput_from_output)"
    assert_min_download_bytes
    assert_min_download_throughput
  fi
fi

if [[ "${cancel_check}" -eq 1 ]]; then
  cancel_download_output="$(capture_or_exit "download-cancel" run_swift_harness download-cancel \
    --port "${allocated_local_port}" \
    --timeout-seconds "${timeout_seconds}" \
    ${transfer_chunk_size_bytes:+--chunk-size} \
    ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
    --source-path "${download_source_path}")"
  print_redacted_output "${cancel_download_output}"
fi

if [[ "${pause_check}" -eq 1 ]]; then
  pause_download_output="$(capture_or_exit "download-pause" run_swift_harness download-pause \
    --port "${allocated_local_port}" \
    --timeout-seconds "${timeout_seconds}" \
    ${transfer_chunk_size_bytes:+--chunk-size} \
    ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
    --source-path "${download_source_path}")"
  print_redacted_output "${pause_download_output}"
fi

if [[ -n "${upload_source_file}" && "${upload_resume_unsupported_check}" -eq 1 ]]; then
  upload_resume_unsupported_output="$(capture_or_exit "upload resume unsupported" run_swift_harness upload-open-expect-error \
    --port "${allocated_local_port}" \
    --timeout-seconds "${timeout_seconds}" \
    --source "${upload_source_file}" \
    --destination-path "${upload_destination_path}" \
    ${transfer_chunk_size_bytes:+--chunk-size} \
    ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
    --requested-offset 1 \
    --expected-error-code unsupportedCapability \
    --expected-message-contains "upload resume is not supported")"
  print_redacted_output "${upload_resume_unsupported_output}"
fi

if [[ -n "${upload_source_file}" && "${upload_resume_check}" -eq 1 ]]; then
  partial_upload_output="$(capture_or_exit "partial upload" run_swift_harness upload \
    --port "${allocated_local_port}" \
    --timeout-seconds "${timeout_seconds}" \
    --source "${upload_source_file}" \
    --destination-path "${upload_destination_path}" \
    ${transfer_chunk_size_bytes:+--chunk-size} \
    ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
    --stop-after-bytes "${upload_partial_bytes}")"
  print_redacted_output "${partial_upload_output}"

  if [[ "${upload_retry_ack_loss_check}" -eq 1 ]]; then
    resume_upload_output="$(capture_or_exit "resume upload ack-loss retry" run_swift_harness_with_ack_loss_fault_proxy upload \
      --timeout-seconds "${timeout_seconds}" \
      --source "${upload_source_file}" \
      --destination-path "${upload_destination_path}" \
      ${transfer_chunk_size_bytes:+--chunk-size} \
      ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
      --resume \
      ${upload_retry_args[@]+"${upload_retry_args[@]}"})"
    assert_retry_recovered "resume upload ack-loss retry" "${resume_upload_output}"
  elif [[ "${upload_retry_fault_check}" -eq 1 ]]; then
    resume_upload_output="$(capture_or_exit "resume upload fault retry" run_swift_harness_with_fault_proxy upload \
      --timeout-seconds "${timeout_seconds}" \
      --source "${upload_source_file}" \
      --destination-path "${upload_destination_path}" \
      ${transfer_chunk_size_bytes:+--chunk-size} \
      ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
      --resume \
      ${upload_retry_args[@]+"${upload_retry_args[@]}"})"
    assert_retry_recovered "resume upload fault retry" "${resume_upload_output}"
  else
    resume_upload_output="$(capture_or_exit "resume upload" run_swift_harness upload \
      --port "${allocated_local_port}" \
      --timeout-seconds "${timeout_seconds}" \
      --source "${upload_source_file}" \
      --destination-path "${upload_destination_path}" \
      ${transfer_chunk_size_bytes:+--chunk-size} \
      ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
      --resume \
      ${upload_retry_args[@]+"${upload_retry_args[@]}"})"
  fi
  print_redacted_output "${resume_upload_output}"
  upload_bytes_sent="$(printf '%s\n' "${resume_upload_output}" | upload_bytes_from_output)"
  upload_elapsed_ms="$(printf '%s\n' "${resume_upload_output}" | upload_elapsed_ms_from_output)"
  upload_throughput_mib_per_second="$(printf '%s\n' "${resume_upload_output}" | upload_throughput_from_output)"
  assert_min_upload_bytes
  assert_min_upload_throughput
elif [[ -n "${upload_source_file}" ]]; then
  if [[ "${upload_retry_fault_check}" -eq 1 ]]; then
    upload_output="$(capture_or_exit "upload fault retry" run_swift_harness_with_fault_proxy upload \
      --timeout-seconds "${timeout_seconds}" \
      --source "${upload_source_file}" \
      --destination-path "${upload_destination_path}" \
      ${transfer_chunk_size_bytes:+--chunk-size} \
      ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
      ${upload_retry_args[@]+"${upload_retry_args[@]}"})"
    assert_retry_recovered "upload fault retry" "${upload_output}"
  else
    upload_output="$(capture_or_exit "upload" run_swift_harness upload \
      --port "${allocated_local_port}" \
      --timeout-seconds "${timeout_seconds}" \
      --source "${upload_source_file}" \
      --destination-path "${upload_destination_path}" \
      ${transfer_chunk_size_bytes:+--chunk-size} \
      ${transfer_chunk_size_bytes:+"${transfer_chunk_size_bytes}"} \
      ${upload_retry_args[@]+"${upload_retry_args[@]}"})"
  fi
  print_redacted_output "${upload_output}"
  upload_bytes_sent="$(printf '%s\n' "${upload_output}" | upload_bytes_from_output)"
  upload_elapsed_ms="$(printf '%s\n' "${upload_output}" | upload_elapsed_ms_from_output)"
  upload_throughput_mib_per_second="$(printf '%s\n' "${upload_output}" | upload_throughput_from_output)"
  assert_min_upload_bytes
  assert_min_upload_throughput
fi

write_result_log

printf 'M1 device smoke passed serial=%s local_port=%s remote_port=%s\n' \
  "<serial-redacted:${serial_tag}>" "${allocated_local_port}" "${remote_port}"
