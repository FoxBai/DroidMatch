#!/usr/bin/env bash

# Device selection, harness/fault-proxy execution, and reversible media-permission control.
# This sourced helper defines behavior only; the runner retains orchestration.
# 中文：此 helper 只定义职责行为，最终编排仍由主 runner 持有。

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
  local status
  set +e
  "${adb_bin}" -s "${serial}" shell "$@" >/dev/null 2>&1
  status=$?
  set -e
  # This hook runs as a fresh process and deliberately has no access to the
  # parent runner's shell functions. Keep its output aggregate-only instead of
  # copying the private serial, adb path, command, or platform error text.
  # 中文：独立 hook 只输出汇总状态，不依赖父进程函数，也不泄露私有参数。
  printf 'adb permission command status=%s\n' "${status}"
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
