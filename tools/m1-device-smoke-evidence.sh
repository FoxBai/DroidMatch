#!/usr/bin/env bash

# Privacy-bounded output, APK installation, source-state capture, and metric gates.
# This sourced helper defines behavior only; the runner retains orchestration.
# 中文：此 helper 只定义职责行为，最终编排仍由主 runner 持有。

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

device_profile_check_plan() {
  local checks=('m1-smoke')
  [[ "${adb_baseline_download_check}" -eq 0 ]] || checks+=('adb-baseline')
  [[ -z "${list_path}" ]] || checks+=('list-dir')
  [[ -z "${list_expect_error_path}" ]] || checks+=('list-expected-error')
  [[ "${media_permission_revoked_check}" -eq 0 ]] || checks+=('media-permission-revoked')
  [[ -z "${download_open_expect_error_path}" ]] || checks+=('download-open-expected-error')
  [[ -z "${download_source_path}" ]] || checks+=('download')
  [[ "${resume_check}" -eq 0 ]] || checks+=('download-resume')
  [[ "${download_resume_source_mutation_check}" -eq 0 ]] \
    || checks+=('download-source-mutation')
  [[ "${download_resume_source_deletion_check}" -eq 0 ]] \
    || checks+=('download-source-deletion')
  [[ "${download_resume_source_replacement_check}" -eq 0 ]] \
    || checks+=('download-source-replacement')
  [[ "${cancel_check}" -eq 0 ]] || checks+=('download-cancel')
  [[ "${pause_check}" -eq 0 ]] || checks+=('download-pause')
  [[ "${download_retry_on_transport_loss}" -eq 0 ]] || checks+=('download-retry')
  [[ "${download_retry_fault_check}" -eq 0 ]] || checks+=('download-retry-fault')
  [[ "${media_permission_revoked_during_download_check}" -eq 0 ]] \
    || checks+=('media-permission-during-download')
  [[ "${dual_download_check}" -eq 0 ]] || checks+=('dual-download')
  [[ -z "${upload_source_file}" ]] || checks+=('upload')
  [[ "${upload_resume_check}" -eq 0 ]] || checks+=('upload-resume')
  [[ "${upload_resume_unsupported_check}" -eq 0 ]] \
    || checks+=('upload-resume-unsupported')
  [[ "${upload_retry_on_transport_loss}" -eq 0 ]] || checks+=('upload-retry')
  [[ "${upload_retry_fault_check}" -eq 0 ]] || checks+=('upload-retry-fault')
  [[ "${upload_retry_ack_loss_check}" -eq 0 ]] || checks+=('upload-ack-loss')
  [[ "${mixed_transfer_check}" -eq 0 ]] || checks+=('mixed-transfer')
  local IFS=','
  printf '%s\n' "${checks[*]}"
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

download_measured_bytes_from_output() {
  local output observed
  output="$(cat)"
  observed="$(printf '%s\n' "${output}" | awk '
    /download passed / {
      for (field_index = 1; field_index <= NF; field_index += 1) {
        if ($field_index ~ /^bytes=[0-9][0-9]*$/) {
          sub(/^bytes=/, "", $field_index)
          value = $field_index
        }
      }
    }
    END { print value }
  ')"
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

upload_measured_bytes_from_output() {
  local output observed
  output="$(cat)"
  observed="$(printf '%s\n' "${output}" | awk '
    /upload passed / {
      for (field_index = 1; field_index <= NF; field_index += 1) {
        if ($field_index ~ /^bytes=[0-9][0-9]*$/) {
          sub(/^bytes=/, "", $field_index)
          value = $field_index
        }
      }
    }
    END { print value }
  ')"
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
