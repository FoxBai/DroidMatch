#!/usr/bin/env bash

set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
# shellcheck source=tools/m1-output-redaction.sh
source "${repo_root}/tools/m1-output-redaction.sh"
# shellcheck source=tools/app-sandbox-upload-staging.sh
source "${repo_root}/tools/app-sandbox-upload-staging.sh"
# shellcheck source=tools/m1-device-smoke-usage.sh
source "${repo_root}/tools/m1-device-smoke-usage.sh"
# shellcheck source=tools/m1-device-smoke-options.sh
source "${repo_root}/tools/m1-device-smoke-options.sh"

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
download_resume_source_replacement_check="${DROIDMATCH_DOWNLOAD_RESUME_SOURCE_REPLACEMENT_CHECK:-0}"
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
git_source_revision="unknown"
git_source_state="unknown"
apk_sha256=""
launcher_resolved=0
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
download_source_replacement_output=""
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
download_measured_bytes=""
upload_measured_bytes=""
download_elapsed_ms=""
upload_elapsed_ms=""
download_throughput_mib_per_second=""
upload_throughput_mib_per_second=""
prepare_app_sandbox_output=""
prepared_app_sandbox_source_path=""
prepared_app_sandbox_replacement_name=""
prepared_app_sandbox_created=0
prepared_app_sandbox_replacement_created=0
disposable_app_sandbox_paths_reserved=0
adb_baseline_download_output=""
adb_baseline_download_bytes=""
adb_baseline_download_elapsed_ms=""
adb_baseline_download_throughput_mib_per_second=""
adb_baseline_download_temp_file=""

parse_m1_device_smoke_options "$@"

finalize_m1_device_smoke_options

adb_bin="${DROIDMATCH_ADB:-}"
if [[ -z "${adb_bin}" ]]; then
  android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}"
  if [[ -x "${android_sdk}/platform-tools/adb" ]]; then
    adb_bin="${android_sdk}/platform-tools/adb"
  else
    adb_bin="adb"
  fi
fi

# shellcheck source=tools/m1-device-smoke-device-control.sh
source "${repo_root}/tools/m1-device-smoke-device-control.sh"
# shellcheck source=tools/m1-device-smoke-evidence.sh
source "${repo_root}/tools/m1-device-smoke-evidence.sh"
# shellcheck source=tools/m1-device-smoke-app-sandbox.sh
source "${repo_root}/tools/m1-device-smoke-app-sandbox.sh"
# shellcheck source=tools/m1-device-smoke-result-log.sh
source "${repo_root}/tools/m1-device-smoke-result-log.sh"
# shellcheck source=tools/m1-device-smoke-cleanup.sh
source "${repo_root}/tools/m1-device-smoke-cleanup.sh"
trap cleanup EXIT

if [[ "${skip_build}" -eq 0 ]]; then
  bash tools/check-m1-skeleton.sh
fi

apk_path="android/app/build/outputs/apk/debug/app-debug.apk"
if [[ ! -s "${apk_path}" ]]; then
  printf 'Missing debug APK: <apk-path-redacted>. Run tools/check-m1-skeleton.sh first or omit --skip-build.\n' >&2
  exit 1
fi
apk_sha256="$(shasum -a 256 "${apk_path}" 2>/dev/null | awk '{ print $1 }')" \
  || {
    printf '%s\n' 'Could not hash the debug APK for the evidence profile.' >&2
    exit 1
  }
[[ "${apk_sha256}" =~ ^[0-9a-f]{64}$ ]] || {
  printf '%s\n' 'Debug APK evidence digest is invalid.' >&2
  exit 1
}

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
if [[ "${git_commit}" == 'unknown' ]]; then
  git_source_revision='unknown'
  git_source_state='unknown'
else
  git_source_revision="$(git rev-parse HEAD 2>/dev/null)" || git_source_revision='unknown'
  if [[ ! "${git_source_revision}" =~ ^[0-9a-f]{40}$ ]]; then
    git_commit='unknown'
    git_source_revision='unknown'
    git_source_state='unknown'
  elif [[ "${git_commit}" == *-dirty ]]; then
    git_source_state='dirty'
  else
    git_source_state='clean'
  fi
fi
device_manufacturer="$(device_prop ro.product.manufacturer)"
device_model="$(device_prop ro.product.model)"
android_release="$(device_prop ro.build.version.release)"
sdk_int="$(device_prop ro.build.version.sdk)"
device_manufacturer="${device_manufacturer:-unknown}"
device_model="${device_model:-unknown}"
android_release="${android_release:-unknown}"
if [[ ! "${sdk_int}" =~ ^[0-9]{2}$ ]]; then
  sdk_int='unknown'
fi

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
launcher_resolved=1
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
  # Use the same canonical evidence-path convention as the ordinary download;
  # this is not a product capability restriction on the fixed `/tmp` alias.
  # 中文：混合下载沿用证据路径约定，并非产品不支持 `/tmp` 固定别名。
  mixed_download_destination="$(mktemp /private/tmp/droidmatch-mixed-download.XXXXXX)"
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
  elif [[ "${download_resume_source_replacement_check}" -eq 1 ]]; then
    replace_prepared_app_sandbox_source_after_partial_download
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
    assert_source_replacement_resume_rejected "${resume_download_output}" "${resume_download_status}"
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
  download_measured_bytes="$(
    printf '%s\n' "${resume_download_output}" | download_measured_bytes_from_output
  )"
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
    download_measured_bytes="$(
      printf '%s\n' "${download_output}" | download_measured_bytes_from_output
    )"
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
    --expected-message-contains "upload is not supported")"
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
  upload_measured_bytes="$(
    printf '%s\n' "${resume_upload_output}" | upload_measured_bytes_from_output
  )"
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
  upload_measured_bytes="$(
    printf '%s\n' "${upload_output}" | upload_measured_bytes_from_output
  )"
  upload_elapsed_ms="$(printf '%s\n' "${upload_output}" | upload_elapsed_ms_from_output)"
  upload_throughput_mib_per_second="$(printf '%s\n' "${upload_output}" | upload_throughput_from_output)"
  assert_min_upload_bytes
  assert_min_upload_throughput
fi

write_result_log

printf 'M1 device smoke passed serial=%s local_port=%s remote_port=%s\n' \
  "<serial-redacted:${serial_tag}>" "${allocated_local_port}" "${remote_port}"
