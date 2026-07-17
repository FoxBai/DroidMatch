#!/usr/bin/env bash

# Validated, no-clobber, privacy-bounded M1 result-log assembly and publication.
# This sourced helper defines behavior only; the runner retains orchestration.
# 中文：此 helper 只定义职责行为，最终编排仍由主 runner 持有。

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

  local staged_log requested_checks passed_checks incomplete_checks archive_class
  local profile_failure_stage build_mode
  mkdir -p "$(dirname "${result_log}")" || return 1
  [[ ! -e "${result_log}" && ! -L "${result_log}" ]] || return 1
  staged_log="$(mktemp "$(dirname "${result_log}")/.m1-device-smoke.XXXXXX")" \
    || return 1
  requested_checks="$(device_profile_check_plan)" || return 1
  if [[ "${skip_build}" -eq 1 ]]; then
    build_mode='reused'
  else
    build_mode='rebuilt'
  fi
  if [[ "${final_status}" == 'passed' ]]; then
    if [[ "${git_source_state}" == 'clean' && "${build_mode}" == 'rebuilt' ]]; then
      archive_class='device-evidence'
    else
      archive_class='diagnostic-only'
    fi
    passed_checks="${requested_checks}"
    incomplete_checks='none'
    profile_failure_stage='none'
  else
    archive_class='failed-diagnostic'
    passed_checks='none'
    incomplete_checks="${requested_checks}"
    profile_failure_stage="${failure_stage}"
  fi
  if ! {
    printf '# %s ADB Device Smoke\n\n' "${run_started_utc}"
    printf 'evidence profile: m1-device-smoke-v1\n'
    printf 'device profile result: %s\n' "${final_status}"
    printf 'device profile archive class: %s\n' "${archive_class}"
    printf 'device profile source revision: %s\n' "${git_source_revision}"
    printf 'device profile source state: %s\n' "${git_source_state}"
    printf 'device profile build mode: %s\n' "${build_mode}"
    printf 'device profile apk sha256: %s\n' "${apk_sha256}"
    printf 'device profile harness configuration: release\n'
    printf 'device profile device slot: %s\n' "${device_slot}"
    printf 'device profile android api: %s\n' "${sdk_int}"
    printf 'device profile checks requested: %s\n' "${requested_checks}"
    printf 'device profile checks passed: %s\n' "${passed_checks}"
    printf 'device profile checks incomplete: %s\n' "${incomplete_checks}"
    printf 'device profile failure stage: %s\n' "${profile_failure_stage}"
    printf 'device profile handshake attempts: %s\n' "${handshake_attempts}"
    printf 'device profile handshake passed: %s\n' "${m1_smoke_passes}"
    printf 'device profile handshake minimum: %s\n' "${min_handshake_passes}"
    printf 'device profile list elapsed ms: %s\n' "${list_time_ms:-not-run}"
    printf 'device profile list maximum ms: %s\n' "${max_list_ms}"
    printf 'device profile download bytes: %s\n' "${download_bytes_received:-not-run}"
    printf 'device profile download measured bytes: %s\n' \
      "${download_measured_bytes:-not-run}"
    printf 'device profile download elapsed ms: %s\n' "${download_elapsed_ms:-not-run}"
    printf 'device profile download observed mib per second: %s\n' \
      "${download_throughput_mib_per_second:-not-run}"
    printf 'device profile download minimum bytes: %s\n' "${min_download_bytes}"
    printf 'device profile download minimum mib per second: %s\n' \
      "${min_download_mib_per_second}"
    printf 'device profile upload bytes: %s\n' "${upload_bytes_sent:-not-run}"
    printf 'device profile upload measured bytes: %s\n' \
      "${upload_measured_bytes:-not-run}"
    printf 'device profile upload elapsed ms: %s\n' "${upload_elapsed_ms:-not-run}"
    printf 'device profile upload observed mib per second: %s\n' \
      "${upload_throughput_mib_per_second:-not-run}"
    printf 'device profile upload minimum bytes: %s\n' "${min_upload_bytes}"
    printf 'device profile upload minimum mib per second: %s\n' \
      "${min_upload_mib_per_second}"
    printf 'device profile cleanup: scheduled-on-exit\n'
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
    elif [[ "${download_resume_source_replacement_check}" -eq 1 && "${final_status}" == "passed" ]]; then
      printf '100MB download: source-replacement check used a script-created source; partial download completed for `%s`, a same-size/same-mtime atomic replacement changed inode/content, and resume correctly rejected the changed fingerprint; 100MB size not asserted\n' "${download_source_path}"
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
    elif [[ "${download_resume_source_replacement_check}" -eq 1 && "${final_status}" == "passed" ]]; then
      printf 'resume result: partial stop after at least %s byte(s), then same-size/same-mtime atomic source replacement was rejected with stable code `invalidArgument` (fingerprint detail redacted)\n' "${resume_partial_bytes}"
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
    if [[ "${launcher_resolved}" -ne 1 ]]; then
      printf 'permission cases: launcher entry not resolved before failure; detailed permission-denied cases not run\n'
    elif [[ "${media_permission_revoked_during_download_check}" -eq 1 ]]; then
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
    if [[ "${download_resume_source_replacement_check}" -eq 1 ]]; then
      printf '%s\n' '- download source replacement check: same-directory rename preserved size/mtime, changed inode/content, and required stable `invalidArgument` on resume; raw metadata and fingerprint detail remain omitted'
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
      if [[ -n "${download_source_replacement_output}" ]]; then
        printf '\n## Download Source Replacement Output\n\n```text\n'
        printf '%s\n' "${download_source_replacement_output}" | redacted_output
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
