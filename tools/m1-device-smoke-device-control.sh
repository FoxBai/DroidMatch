#!/usr/bin/env bash
# Sourced device, fault-proxy, and reversible permission control / 中文：设备、代理与可逆权限控制。
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
  droidmatch_run_with_immutable_swift_lock \
    swift run --package-path mac --configuration release \
      "${droidmatch_swift_compat_args[@]}" droidmatch-harness "$@"
}

fault_proxy_identity_tool() {
  local identity_tool="${repo_root}/tools/process_instance_identity.py"
  if [[ -n "${DROIDMATCH_TEST_FAULT_PROXY_IDENTITY_TOOL:-}" ]]; then
    [[ "${DROIDMATCH_FAULT_PROXY_TEST_MODE:-0}" == 1 ]] || return 2
    identity_tool="${DROIDMATCH_TEST_FAULT_PROXY_IDENTITY_TOOL}"
  fi
  printf '%s\n' "${identity_tool}"
}
fault_proxy_instance_matches() {
  local process_id="$1" process_identity="$2" identity_tool
  identity_tool="$(fault_proxy_identity_tool)" || return $?
  python3 "${identity_tool}" \
    matches "${process_id}" "${process_identity}" >/dev/null 2>&1
}
signal_fault_proxy_instance() {
  local process_id="$1" process_identity="$2" requested_signal="$3" identity_tool
  identity_tool="$(fault_proxy_identity_tool)" || return $?
  python3 "${identity_tool}" \
    signal "${process_id}" "${process_identity}" "${requested_signal}"
}
register_fault_proxy_instance() {
  local process_id="$1" process_identity="$2" shutdown_token="$3" temporary_record
  [[ -n "${fault_proxy_registry_file:-}" ]] || return 0
  temporary_record="${fault_proxy_registry_file}.new.${BASHPID:-$$}"
  (umask 077; printf '%s %s %s\n' \
    "${process_id}" "${process_identity}" "${shutdown_token}" \
    >"${temporary_record}")
  mv -f "${temporary_record}" "${fault_proxy_registry_file}"
}

clear_fault_proxy_registration() {
  local process_id="$1" process_identity="$2" shutdown_token="$3"
  local registered_id="" registered_identity="" registered_token="" extra=""
  [[ -n "${fault_proxy_registry_file:-}" \
      && -f "${fault_proxy_registry_file}" \
      && ! -L "${fault_proxy_registry_file}" ]] || return 0
  read -r registered_id registered_identity registered_token extra \
    <"${fault_proxy_registry_file}" || true
  if [[ "${registered_id}" == "${process_id}" \
      && "${registered_identity}" == "${process_identity}" \
      && "${registered_token}" == "${shutdown_token}" \
      && -z "${extra}" ]]; then
    rm -f "${fault_proxy_registry_file}"
  fi
}

fault_proxy_shutdown_status_matches() {
  local shutdown_token="$1"
  local status_line=""
  [[ -n "${fault_proxy_shutdown_status_file:-}" \
      && -f "${fault_proxy_shutdown_status_file}" \
      && ! -L "${fault_proxy_shutdown_status_file}" ]] || return 1
  IFS= read -r status_line <"${fault_proxy_shutdown_status_file}" || return 1
  [[ "${status_line}" == "clean ${shutdown_token}" ]]
}

wait_for_fault_proxy_shutdown_status() {
  local shutdown_token="$1"
  local status_wait
  for ((status_wait = 0; status_wait < 20; status_wait += 1)); do
    fault_proxy_shutdown_status_matches "${shutdown_token}" && return 0
    sleep 0.01
  done
  return 1
}

request_fault_proxy_shutdown() {
  local shutdown_token="$1" temporary_request
  [[ -n "${fault_proxy_shutdown_request_file:-}" ]] || return 1
  temporary_request="${fault_proxy_shutdown_request_file}.new.${BASHPID:-$$}"
  (umask 077; printf 'shutdown %s\n' "${shutdown_token}" \
    >"${temporary_request}") || return 1
  mv -f "${temporary_request}" "${fault_proxy_shutdown_request_file}"
}

stop_fault_proxy_instance() {
  local process_id="$1" process_identity="$2" shutdown_token="$3"
  local identity_status wait_index

  if fault_proxy_instance_matches "${process_id}" "${process_identity}"; then
    identity_status=0
  else
    identity_status=$?
  fi
  case "${identity_status}" in
    0)
      ;;
    1)
      if wait_for_fault_proxy_shutdown_status "${shutdown_token}"; then
        clear_fault_proxy_registration \
          "${process_id}" "${process_identity}" "${shutdown_token}"
        return 0
      fi
      printf '%s\n' \
        'Fault proxy exited without a verified clean hook-shutdown marker.' >&2
      return 1
      ;;
    *)
      printf '%s\n' \
        'Fault-proxy identity probe failed; preserving cleanup state.' >&2
      return 1
      ;;
  esac

  if ! request_fault_proxy_shutdown "${shutdown_token}"; then
    printf '%s\n' \
      'Fault-proxy shutdown request failed; preserving cleanup state.' >&2
    return 1
  fi

  for ((wait_index = 0; wait_index < 100; wait_index += 1)); do
    if fault_proxy_instance_matches "${process_id}" "${process_identity}"; then
      identity_status=0
    else
      identity_status=$?
    fi
    case "${identity_status}" in
      0)
        ;;
      1)
        if wait_for_fault_proxy_shutdown_status "${shutdown_token}"; then
          clear_fault_proxy_registration \
            "${process_id}" "${process_identity}" "${shutdown_token}"
          return 0
        fi
        printf '%s\n' \
          'Fault proxy stopped without a verified clean hook-shutdown marker.' >&2
        return 1
        ;;
      *)
        printf '%s\n' \
          'Fault-proxy identity probe failed while waiting; preserving cleanup state.' >&2
        return 1
        ;;
    esac
    sleep 0.05
  done

  if signal_fault_proxy_instance \
      "${process_id}" "${process_identity}" KILL; then
    identity_status=0
  else
    identity_status=$?
  fi
  case "${identity_status}" in
    0|1)
      printf '%s\n' \
        'Fault proxy required SIGKILL; hook shutdown is unverified and permission restore is blocked.' >&2
      ;;
    *)
      printf '%s\n' \
        'Fault-proxy KILL probe failed; preserving cleanup state.' >&2
      ;;
  esac
  return 1
}

stop_registered_fault_proxy() {
  local process_id="" process_identity="" shutdown_token="" extra=""
  [[ -n "${fault_proxy_registry_file:-}" ]] || return 0
  [[ -e "${fault_proxy_registry_file}" || -L "${fault_proxy_registry_file}" ]] || return 0
  if [[ -f "${fault_proxy_registry_file}" && ! -L "${fault_proxy_registry_file}" ]]; then read -r process_id process_identity shutdown_token extra <"${fault_proxy_registry_file}" || true; fi
  if ! [[ -f "${fault_proxy_registry_file}" \
      && ! -L "${fault_proxy_registry_file}" \
      && "${process_id}" =~ ^[1-9][0-9]*$ \
      && -n "${process_identity}" \
      && "${shutdown_token}" =~ ^[0-9a-f]{32}$ \
      && -z "${extra}" ]]; then
    printf '%s\n' 'Fault-proxy cleanup found an invalid process registration.' >&2
    return 1
  fi
  stop_fault_proxy_instance \
    "${process_id}" "${process_identity}" "${shutdown_token}"
}

run_swift_harness_with_fault_proxy() (
  local command="$1"
  shift
  local port_file log_file proxy_pid proxy_identity proxy_port proxy_shutdown_token output status wait_index proxy_log
  local published_pid published_identity published_token published_extra proxy_identity_tool
  local deferred_signal_status=0 proxy_direct_child_owned=0 proxy_registration_ready=0 proxy_starting=0
  local drop_after_frames="${FAULT_PROXY_DROP_AFTER_FRAMES:-3}"
  local drop_before_frame="${FAULT_PROXY_DROP_BEFORE_FRAME:-0}"
  local hook_after_frames="${FAULT_PROXY_HOOK_AFTER_FRAMES:-0}"
  local hook_timeout_seconds="${FAULT_PROXY_HOOK_TIMEOUT_SECONDS:-30}"
  local proxy_args=()
  local hook_argv=()
  port_file="$(mktemp /tmp/droidmatch-m1-fault-proxy-port.XXXXXX)"
  log_file="$(mktemp /tmp/droidmatch-m1-fault-proxy-log.XXXXXX)"
  proxy_pid=""
  proxy_identity=""
  proxy_port=""
  fault_proxy_shutdown_status_file="${fault_proxy_shutdown_status_file:-${fault_proxy_scope_root}/shutdown-status}"
  fault_proxy_shutdown_request_file="${fault_proxy_shutdown_request_file:-${fault_proxy_scope_root}/shutdown-request}"
  fault_proxy_identity_file="${fault_proxy_identity_file:-${fault_proxy_scope_root}/identity}"
  proxy_identity_tool="$(fault_proxy_identity_tool)" || return $?
  proxy_shutdown_token="$(
    python3 -c 'import secrets; print(secrets.token_hex(16))'
  )"
  [[ ! -e "${fault_proxy_registry_file}" && ! -L "${fault_proxy_registry_file}" ]] || { printf '%s\n' 'Refusing to replace an existing fault-proxy cleanup registration.' >&2; return 1; }
  rm -f "${fault_proxy_shutdown_status_file}" \
    "${fault_proxy_shutdown_request_file}" "${fault_proxy_identity_file}"

  stop_scoped_fault_proxy() {
    local stop_status=0
    if [[ -z "${proxy_pid}" ]]; then
      clear_fault_proxy_registration 0 pending "${proxy_shutdown_token}"
      return 0
    fi
    if [[ -n "${proxy_identity}" ]]; then
      if ! stop_fault_proxy_instance \
          "${proxy_pid}" "${proxy_identity}" "${proxy_shutdown_token}"; then
        return 1
      fi
      if [[ "${proxy_registration_ready}" -eq 0 ]]; then
        clear_fault_proxy_registration 0 pending "${proxy_shutdown_token}"
      fi
      if [[ "${proxy_direct_child_owned}" -eq 1 ]]; then
        if wait "${proxy_pid}"; then
          stop_status=0
        else
          stop_status=$?
          [[ "${stop_status}" -eq 143 || "${stop_status}" -eq 129 ]] \
            || return 1
        fi
      fi
    elif [[ "${proxy_direct_child_owned}" -eq 1 ]]; then
      if wait_for_fault_proxy_shutdown_status "${proxy_shutdown_token}"; then
        clear_fault_proxy_registration 0 pending "${proxy_shutdown_token}"
        proxy_pid=""
        proxy_direct_child_owned=0
        return 0
      fi
      printf '%s\n' \
        'Fault proxy has no captured process identity; cleanup state is preserved.' >&2
      return 1
    fi
    proxy_pid=""
    proxy_identity=""
    proxy_direct_child_owned=0
    proxy_registration_ready=0
    return 0
  }

  handle_scoped_fault_proxy_signal() {
    local requested_status="$1"
    if [[ "${proxy_starting}" -eq 1 \
        || ( "${proxy_direct_child_owned}" -eq 1 \
          && "${proxy_registration_ready}" -eq 0 ) ]]; then
      [[ "${deferred_signal_status}" -ne 0 ]] \
        || deferred_signal_status="${requested_status}"
      return 0
    fi
    exit "${requested_status}"
  }

  cleanup_fault_proxy_scope() {
    local exit_status=$?
    local cleanup_status=0
    trap - EXIT
    trap '' INT TERM HUP
    if ! stop_scoped_fault_proxy; then
      cleanup_status=1
    fi
    if [[ "${cleanup_status}" -ne 0 && -s "${log_file}" ]]; then
      printf 'fault proxy cleanup log:\n'
      redacted_output <"${log_file}"
    fi
    [[ -z "${port_file}" ]] || rm -f "${port_file}"
    [[ -z "${log_file}" ]] || rm -f "${log_file}"
    if [[ "${exit_status}" -eq 0 && "${cleanup_status}" -ne 0 ]]; then
      exit_status=1
    fi
    exit "${exit_status}"
  }
  trap cleanup_fault_proxy_scope EXIT
  trap 'handle_scoped_fault_proxy_signal 130' INT
  trap 'handle_scoped_fault_proxy_signal 143' TERM
  trap 'handle_scoped_fault_proxy_signal 129' HUP

  proxy_args=(
    --target-host 127.0.0.1
    --target-port "${allocated_local_port}"
    --listen-host 127.0.0.1
    --listen-port 0
    --port-file "${port_file}"
    --drop-first-server-frames "${drop_after_frames}"
    --drop-before-first-server-frame "${drop_before_frame}"
    --run-command-after-first-server-frames "${hook_after_frames}"
    --after-first-server-frames-command-timeout "${hook_timeout_seconds}"
    --max-connections 2
    --shutdown-status-file "${fault_proxy_shutdown_status_file}"
    --shutdown-request-file "${fault_proxy_shutdown_request_file}"
    --identity-file "${fault_proxy_identity_file}"
    --identity-tool "${proxy_identity_tool}"
    --shutdown-token "${proxy_shutdown_token}"
    --hook-state-directory "${fault_proxy_scope_root}"
  )
  if [[ -n "${FAULT_PROXY_HOOK_PROGRAM:-}" ]]; then
    hook_argv=("${FAULT_PROXY_HOOK_PROGRAM}")
    if [[ -n "${FAULT_PROXY_HOOK_ARGUMENT:-}" ]]; then
      hook_argv+=("${FAULT_PROXY_HOOK_ARGUMENT}")
    fi
    proxy_args+=(--after-first-server-frames-command "${hook_argv[@]}")
  fi

  proxy_starting=1
  register_fault_proxy_instance 0 pending "${proxy_shutdown_token}" || {
    printf '%s\n' 'Could not register the pending fault-proxy startup.' >&2
    return 1
  }
  python3 tools/m1-fault-proxy.py "${proxy_args[@]}" \
    >/dev/null 2>"${log_file}" &
  proxy_pid=$!
  proxy_direct_child_owned=1
  for ((wait_index = 0; wait_index < 100; wait_index += 1)); do
    if [[ -s "${fault_proxy_identity_file}" \
        && -f "${fault_proxy_identity_file}" \
        && ! -L "${fault_proxy_identity_file}" ]]; then
      read -r published_pid published_identity published_token published_extra \
        <"${fault_proxy_identity_file}" || true
      break
    fi
    kill -0 "${proxy_pid}" 2>/dev/null || break
    sleep 0.05
  done
  if ! [[ "${published_pid:-}" == "${proxy_pid}" \
      && "${published_identity:-}" =~ ^[a-z0-9][a-z0-9:._-]{10,255}$ \
      && "${published_token:-}" == "${proxy_shutdown_token}" \
      && -z "${published_extra:-}" ]]; then
    printf '%s\n' 'Could not verify the fault proxy self-published identity.' >&2
    return 1
  fi
  proxy_identity="${published_identity}"
  register_fault_proxy_instance \
    "${proxy_pid}" "${proxy_identity}" "${proxy_shutdown_token}" || {
    printf '%s\n' 'Could not register the active fault proxy for cleanup.' >&2
    return 1
  }
  proxy_registration_ready=1
  proxy_starting=0
  if [[ "${deferred_signal_status}" -ne 0 ]]; then
    return "${deferred_signal_status}"
  fi

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
    if ! stop_scoped_fault_proxy; then
      printf '%s\n' 'Fault proxy did not stop cleanly.' >&2
    fi
    rm -f "${port_file}" "${log_file}"
    port_file=""
    log_file=""
    printf 'fault proxy did not publish a listen port.\n%s\n' "${proxy_log}"
    return 1
  fi

  set +e
  output="$(run_swift_harness "${command}" --port "${proxy_port}" "$@" 2>&1)"
  status=$?
  set -e

  if ! stop_scoped_fault_proxy; then
    [[ "${status}" -ne 0 ]] || status=1
  fi
  proxy_log="$(cat "${log_file}" 2>/dev/null || true)"
  rm -f "${port_file}" "${log_file}"
  port_file=""
  log_file=""

  print_redacted_output "${output}"
  if [[ -n "${proxy_log}" ]]; then
    printf 'fault proxy log:\n%s\n' "${proxy_log}" | redacted_output
  fi
  return "${status}"
)

run_swift_harness_with_ack_loss_fault_proxy() {
  FAULT_PROXY_DROP_AFTER_FRAMES=0 FAULT_PROXY_DROP_BEFORE_FRAME=3 \
    run_swift_harness_with_fault_proxy "$@"
}

run_swift_harness_with_permission_revoke_fault_proxy() {
  # This product probe intentionally exposes only `bash <generated-hook>`:
  # the proxy itself accepts arbitrary explicit argv, while this boundary
  # never reparses a caller-controlled shell command string.
  FAULT_PROXY_DROP_AFTER_FRAMES=0 \
    FAULT_PROXY_HOOK_AFTER_FRAMES=3 \
    FAULT_PROXY_HOOK_PROGRAM=bash \
    FAULT_PROXY_HOOK_ARGUMENT="${media_permission_revoke_hook_script}" \
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

media_permission_snapshot() {
  local current_user observed_sdk package_state
  observed_sdk="$(
    "${adb_bin}" -s "${serial}" shell getprop ro.build.version.sdk 2>/dev/null \
      | tr -d '\r' | tail -1
  )" || return 1
  [[ "${sdk_int:-unknown}" =~ ^[0-9]+$ \
      && "${observed_sdk}" == "${sdk_int}" ]] || return 1
  current_user="$(
    "${adb_bin}" -s "${serial}" shell am get-current-user 2>/dev/null \
      | tr -d '\r' | tail -1
  )" || return 1
  [[ "${current_user}" =~ ^[0-9]+$ ]] || return 1
  package_state="$(
    "${adb_bin}" -s "${serial}" shell dumpsys package app.droidmatch 2>/dev/null
  )" || return 1
  package_state="${package_state//$'\r'/}"
  printf '%s ' "${current_user}"
  python3 "${repo_root}/tools/m1-media-permission-snapshot.py" \
    --sdk "${sdk_int}" \
    --current-user "${current_user}" \
    <<<"${package_state}"
}

media_permission_snapshot_state_line() {
  local snapshot="$1"
  local current_user read_external read_images read_video read_selected
  read -r current_user read_external read_images read_video read_selected <<<"${snapshot}"
  printf 'sdk=%s user=%s read_external=%s read_media_images=%s read_media_video=%s read_media_visual_user_selected=%s' \
    "${sdk_int:-unknown}" \
    "${current_user}" \
    "$([[ "${read_external}" == 1 ]] && printf granted || printf denied)" \
    "$([[ "${read_images}" == 1 ]] && printf granted || printf denied)" \
    "$([[ "${read_video}" == 1 ]] && printf granted || printf denied)" \
    "$([[ "${read_selected}" == 1 ]] && printf granted || printf denied)"
}

media_permission_snapshot_matches_restore_state() {
  local snapshot="$1"
  local current_user read_external read_images read_video read_selected
  read -r current_user read_external read_images read_video read_selected <<<"${snapshot}"
  [[ "${current_user}" == "${media_permission_restore_user_id}" \
      && "${read_external}" == "${media_permission_restore_read_external_storage}" \
      && "${read_images}" == "${media_permission_restore_read_media_images}" \
      && "${read_video}" == "${media_permission_restore_read_media_video}" \
      && "${read_selected}" == "${media_permission_restore_read_media_visual_user_selected}" ]]
}

media_permission_mutation_context_matches() {
  local expected_user="$1" current_user observed_sdk
  observed_sdk="$("${adb_bin}" -s "${serial}" shell getprop ro.build.version.sdk \
    2>/dev/null | tr -d '\r' | tail -1)" || return 1
  current_user="$("${adb_bin}" -s "${serial}" shell am get-current-user \
    2>/dev/null | tr -d '\r' | tail -1)" || return 1
  [[ "${observed_sdk}" =~ ^[0-9]+$ \
      && "${observed_sdk}" == "${sdk_int}" \
      && "${current_user}" =~ ^[0-9]+$ \
      && "${current_user}" == "${expected_user}" ]]
}

revoke_media_permission_for_captured_user() {
  local permission="$1"
  if ! media_permission_mutation_context_matches \
      "${media_permission_restore_user_id}"; then
    printf '%s\n' \
      'Media-permission mutation context changed; revoke was refused.'
    return 2
  fi
  run_adb_shell_record pm revoke --user \
    "${media_permission_restore_user_id}" app.droidmatch "${permission}"
}

media_permission_state_line() {
  local snapshot
  snapshot="$(media_permission_snapshot)" || {
    printf 'sdk=%s permission_state=unavailable' "${sdk_int:-unknown}"
    return 1
  }
  media_permission_snapshot_state_line "${snapshot}"
}

media_read_permission_granted_for_sdk() {
  local snapshot current_user read_external read_images read_video read_selected
  snapshot="$(media_permission_snapshot)" || return 2
  read -r current_user read_external read_images read_video read_selected <<<"${snapshot}"
  [[ -z "${media_permission_restore_user_id:-}" \
      || "${current_user}" == "${media_permission_restore_user_id}" ]] || return 2
  if [[ "${sdk_int}" -ge 34 ]]; then
    [[ "${read_images}" -eq 1 || "${read_video}" -eq 1 \
      || "${read_selected}" -eq 1 ]]
  elif [[ "${sdk_int}" -eq 33 ]]; then
    [[ "${read_images}" -eq 1 || "${read_video}" -eq 1 ]]
  else
    [[ "${read_external}" -eq 1 ]]
  fi
}

capture_media_permission_restore_state() {
  local snapshot
  media_permission_restore_baseline_captured=0
  snapshot="$(media_permission_snapshot)" || {
    fail_with_log "media permission revoke guard" \
      "Could not capture a verified media-permission baseline; no permission mutation was attempted."
    return 1
  }
  read -r \
    media_permission_restore_user_id \
    media_permission_restore_read_external_storage \
    media_permission_restore_read_media_images \
    media_permission_restore_read_media_video \
    media_permission_restore_read_media_visual_user_selected \
    <<<"${snapshot}"
  media_permission_restored=0

  if [[ "${media_permission_restore_read_media_visual_user_selected}" -eq 1 \
      && ( "${media_permission_restore_read_media_images}" -eq 0 \
        || "${media_permission_restore_read_media_video}" -eq 0 ) ]]; then
    fail_with_log "media permission revoke guard" \
      "Device has selected-photos-only media access. ADB cannot safely restore the selected media set after revoke; skip --media-permission-revoked-check on this device state."
  fi
  media_permission_restore_baseline_captured=1
}

media_permission_mutation_enabled() {
  [[ "${media_permission_revoked_check}" -eq 1 || "${media_permission_revoked_during_download_check}" -eq 1 ]]
}

revoke_media_permissions_for_check() {
  [[ "${media_permission_revoked_check}" -eq 1 ]] || return 0

  local before_snapshot
  capture_media_permission_restore_state
  before_snapshot="$(media_permission_snapshot)" || {
    fail_with_log "media permission revoke guard" \
      "Could not revalidate the media-permission baseline before mutation."
  }
  media_permission_snapshot_matches_restore_state "${before_snapshot}" || {
    fail_with_log "media permission revoke guard" \
      "Media-permission state changed after baseline capture; no mutation was attempted."
  }

  if ! media_permission_mutation_output="$(
      {
        printf 'before revoke: %s\n' \
          "$(media_permission_snapshot_state_line "${before_snapshot}")"
        if [[ "${sdk_int:-0}" =~ ^[0-9]+$ && "${sdk_int}" -ge 34 ]]; then
          revoke_media_permission_for_captured_user android.permission.READ_MEDIA_VISUAL_USER_SELECTED || exit 2
          revoke_media_permission_for_captured_user android.permission.READ_MEDIA_IMAGES || exit 2
          revoke_media_permission_for_captured_user android.permission.READ_MEDIA_VIDEO || exit 2
        elif [[ "${sdk_int:-0}" =~ ^[0-9]+$ && "${sdk_int}" -eq 33 ]]; then
          revoke_media_permission_for_captured_user android.permission.READ_MEDIA_IMAGES || exit 2
          revoke_media_permission_for_captured_user android.permission.READ_MEDIA_VIDEO || exit 2
        elif [[ "${sdk_int:-0}" =~ ^[0-9]+$ && "${sdk_int}" -ge 26 ]]; then
          revoke_media_permission_for_captured_user android.permission.READ_EXTERNAL_STORAGE || exit 2
        else
          printf '%s\n' 'Unsupported SDK; media-permission revoke was refused.'
          exit 2
        fi
        printf 'after revoke: %s\n' "$(media_permission_state_line)"
      }
    )"; then
    fail_with_log "media permission revoke guard" \
      "Media-permission mutation context changed; the revoke batch stopped immediately.
${media_permission_mutation_output}"
  fi
  print_redacted_output "${media_permission_mutation_output}"

  local permission_status
  if media_read_permission_granted_for_sdk; then
    permission_status=0
  else
    permission_status=$?
  fi
  if [[ "${permission_status}" -eq 0 ]]; then
    fail_with_log "media permission revoke" \
      "Media read permission remained granted after revoke.
${media_permission_mutation_output}"
  elif [[ "${permission_status}" -ne 1 ]]; then
    fail_with_log "media permission revoke" \
      "Could not verify the complete current-user permission set after revoke."
  fi

  local restart_output
  restart_output="$(capture_or_exit "debug harness Activity restart after media permission revoke" \
    "${adb_bin}" -s "${serial}" shell am start -W \
      -n app.droidmatch/app.droidmatch.m1.DebugHarnessActivity \
      --ei port "${remote_port}")"
  media_permission_mutation_output+=$'\n'"restart after revoke:"$'\n'"${restart_output}"
  print_redacted_output "${restart_output}"
}

# shellcheck source=tools/m1-device-smoke-permission-hook.sh
source "${repo_root}/tools/m1-device-smoke-permission-hook.sh"

record_media_permission_state_after_revoke_during_download() {
  [[ "${media_permission_revoked_during_download_check}" -eq 1 ]] || return 0

  local after_revoke_state
  after_revoke_state="$(media_permission_state_line)"
  media_permission_mutation_output+=$'\n'"after revoke during download: ${after_revoke_state}"
  printf 'after revoke during download: %s\n' "${after_revoke_state}"
  local permission_status
  if media_read_permission_granted_for_sdk; then
    permission_status=0
  else
    permission_status=$?
  fi
  if [[ "${permission_status}" -eq 0 ]]; then
    restore_media_permissions_after_check 1
    fail_with_log "media permission revoke during download" \
      "Media read permission remained granted after the proxy hook.
${media_permission_mutation_output}"
  elif [[ "${permission_status}" -ne 1 ]]; then
    restore_media_permissions_after_check 1
    fail_with_log "media permission revoke during download" \
      "Could not verify the complete current-user permission set after the proxy hook."
  fi
}

restore_media_permissions_after_check() {
  local restart_endpoint="${1:-0}"
  local attempt attempt_output current_snapshot current_state_line restore_output=""
  local stable_matches=0
  media_permission_mutation_enabled || return 0
  [[ "${media_permission_restore_baseline_captured:-0}" -eq 1 ]] || return 0
  [[ "${media_permission_restored}" -eq 0 ]] || return 0
  [[ -n "${serial:-}" ]] || return 0

  for ((attempt = 1; attempt <= 6; attempt += 1)); do
    attempt_output="$(
      {
        printf 'restore attempt=%s\n' "${attempt}"
        if [[ "${media_permission_restore_read_external_storage}" -eq 1 ]]; then
          run_adb_shell_record pm grant --user "${media_permission_restore_user_id}" app.droidmatch android.permission.READ_EXTERNAL_STORAGE
        fi
        if [[ "${media_permission_restore_read_media_images}" -eq 1 ]]; then
          run_adb_shell_record pm grant --user "${media_permission_restore_user_id}" app.droidmatch android.permission.READ_MEDIA_IMAGES
        fi
        if [[ "${media_permission_restore_read_media_video}" -eq 1 ]]; then
          run_adb_shell_record pm grant --user "${media_permission_restore_user_id}" app.droidmatch android.permission.READ_MEDIA_VIDEO
        fi
        if [[ "${media_permission_restore_read_media_visual_user_selected}" -eq 1 ]]; then
          run_adb_shell_record pm grant --user "${media_permission_restore_user_id}" app.droidmatch android.permission.READ_MEDIA_VISUAL_USER_SELECTED
        fi
      }
    )"
    restore_output+="${attempt_output}"$'\n'
    if current_snapshot="$(media_permission_snapshot)" \
        && media_permission_snapshot_matches_restore_state "${current_snapshot}"; then
      stable_matches=$((stable_matches + 1))
      current_state_line="$(
        media_permission_snapshot_state_line "${current_snapshot}"
      )"
      restore_output+="verification attempt=${attempt} baseline_match=true ${current_state_line}"$'\n'
    else
      stable_matches=0
      restore_output+="verification attempt=${attempt} baseline_match=false"$'\n'
    fi
    if [[ "${stable_matches}" -ge 2 ]]; then
      media_permission_restored=1
      break
    fi
    if [[ "${attempt}" -lt 6 ]]; then
      sleep 0.25
    fi
  done

  if [[ -n "${media_permission_mutation_output:-}" ]]; then
    media_permission_mutation_output+=$'\n'
  fi
  media_permission_mutation_output+="restore permissions:"$'\n'"${restore_output}"
  print_redacted_output "${restore_output}"
  if [[ "${media_permission_restored}" -ne 1 ]]; then
    printf '%s\n' \
      'Could not verify a stable media-permission baseline after bounded restore attempts.' >&2
    return 1
  fi

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
