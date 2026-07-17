#!/usr/bin/env bash

# Disposable App Sandbox sources, resume-invalidating mutations, and ADB baseline probes.
# This sourced helper defines behavior only; the runner retains orchestration.
# 中文：此 helper 只定义职责行为，最终编排仍由主 runner 持有。

app_sandbox_node_is_absent() {
  local path="$1"
  "${adb_bin}" -s "${serial}" shell \
    "run-as app.droidmatch sh -c 'test ! -e \"${path}\" && test ! -L \"${path}\"'"
}

prepare_app_sandbox_file_on_device() {
  [[ -n "${prepare_app_sandbox_file}" ]] || return 0

  local mebibytes mkdir_output dd_output stat_output
  mebibytes=$((prepare_app_sandbox_bytes / 1048576))
  mkdir_output="$(capture_or_exit "prepare app sandbox directory" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch mkdir -p files/droidmatch-sandbox)"
  # This runner deletes the prepared source on exit, so it must never adopt or
  # overwrite a pre-existing app-private file. 中文：清理权只来自“运行前不存在”。
  capture_or_exit "reserve prepared app sandbox source" \
    app_sandbox_node_is_absent \
    "files/droidmatch-sandbox/${prepare_app_sandbox_file}" >/dev/null
  prepared_app_sandbox_created=1
  dd_output="$(capture_or_exit "prepare app sandbox file" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch dd \
      if=/dev/zero \
      "of=files/droidmatch-sandbox/${prepare_app_sandbox_file}" \
      bs=1048576 \
      "count=${mebibytes}")"
  stat_output="$(capture_or_exit "verify app sandbox file" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch ls -l \
      "files/droidmatch-sandbox/${prepare_app_sandbox_file}")"
  prepare_app_sandbox_output="$(
    {
      printf 'mkdir:\n%s\n' "${mkdir_output}"
      printf 'dd:\n%s\n' "${dd_output}"
      printf 'verify:\n%s\n' "${stat_output}"
    }
  )"
  print_redacted_output "${prepare_app_sandbox_output}"
}

app_sandbox_upload_destination_key() {
  droidmatch_app_sandbox_upload_destination_key "$1"
}

app_sandbox_upload_staging_glob() {
  droidmatch_app_sandbox_upload_staging_glob "$1"
}

reserve_disposable_app_sandbox_paths() {
  [[ "${require_disposable_app_sandbox_paths}" -eq 1 ]] || return 0

  local path staging_glob upload_name
  upload_name="${upload_destination_path#dm://app-sandbox/}"
  for path in \
    "files/droidmatch-sandbox/${prepare_app_sandbox_file}" \
    "files/droidmatch-sandbox/${upload_name}"; do
    if ! app_sandbox_node_is_absent "${path}" >/dev/null 2>&1; then
      fail_with_log "disposable app-sandbox path reservation" \
        "A requested disposable app-sandbox path was not absent before the run."
    fi
  done
  staging_glob="$(app_sandbox_upload_staging_glob "${upload_name}")" \
    || fail_with_log "disposable app-sandbox path reservation" \
      "The private upload staging identity could not be derived."
  if ! "${adb_bin}" -s "${serial}" shell \
      "run-as app.droidmatch sh -c 'for path in ${staging_glob}; do [ ! -e \"\$path\" ] && [ ! -L \"\$path\" ] || exit 1; done'" \
      >/dev/null 2>&1; then
    fail_with_log "disposable app-sandbox path reservation" \
      "A requested disposable app-sandbox path was not absent before the run."
  fi
  # The strict wrapper treats this private marker as the ownership boundary:
  # cleanup is allowed only after all three paths were proven absent.
  disposable_app_sandbox_paths_reserved=1
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
      "run-as app.droidmatch sh -c 'test ! -e files/droidmatch-sandbox/${prepare_app_sandbox_file} && test ! -L files/droidmatch-sandbox/${prepare_app_sandbox_file}'")"
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
        && [[ "${download_resume_source_deletion_check}" -ne 1 ]] \
        && [[ "${download_resume_source_replacement_check}" -ne 1 ]] ); then
    return 0
  fi

  local mebibytes mkdir_output dd_output stat_output
  mebibytes=$((prepare_app_sandbox_bytes / 1048576))
  # Source mutation/deletion/replacement checks are intentionally destructive. Restore the
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

replace_prepared_app_sandbox_source_after_partial_download() {
  [[ "${download_resume_source_replacement_check}" -eq 1 ]] || return 0

  local after_byte after_bytes after_inode after_mtime before_byte before_bytes
  local before_inode before_mtime mebibytes replacement_output
  local source_relative="files/droidmatch-sandbox/${prepare_app_sandbox_file}"
  local replacement_relative="files/droidmatch-sandbox/${prepared_app_sandbox_replacement_name}"
  mebibytes=$((prepare_app_sandbox_bytes / 1048576))

  before_bytes="$(capture_or_exit "read source size before replacement" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch stat -c %s "${source_relative}")"
  before_mtime="$(capture_or_exit "read source mtime before replacement" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch stat -c %y "${source_relative}")"
  before_inode="$(capture_or_exit "read source inode before replacement" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch stat -c %i "${source_relative}")"
  before_byte="$(capture_or_exit "read source content marker before replacement" \
    "${adb_bin}" -s "${serial}" shell \
      "run-as app.droidmatch sh -c 'dd if=${source_relative} bs=1 count=1 2>/dev/null | od -An -tu1'")"
  before_byte="$(tr -d '[:space:]' <<<"${before_byte}")"
  before_bytes="$(tr -d '[:space:]' <<<"${before_bytes}")"
  before_inode="$(tr -d '[:space:]' <<<"${before_inode}")"
  before_mtime="$(tr -d '\r' <<<"${before_mtime}")"

  capture_or_exit "reserve source replacement path" \
    app_sandbox_node_is_absent "${replacement_relative}" >/dev/null
  prepared_app_sandbox_replacement_created=1
  replacement_output="$(capture_or_exit "create same-size source replacement" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch dd \
      if=/dev/zero "of=${replacement_relative}" bs=1048576 "count=${mebibytes}")"
  capture_or_exit "change replacement content marker" \
    "${adb_bin}" -s "${serial}" shell \
      "run-as app.droidmatch sh -c 'printf x | dd of=${replacement_relative} bs=1 count=1 conv=notrunc 2>/dev/null'" \
      >/dev/null
  capture_or_exit "preserve source replacement mtime" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch touch -r \
      "${source_relative}" "${replacement_relative}" >/dev/null
  # Same-directory mv maps to one rename on Android's app-private filesystem.
  # 中文：同目录 rename 保留路径但替换 inode，正是本场景要验证的竞争形态。
  capture_or_exit "atomically publish source replacement" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch mv -f \
      "${replacement_relative}" "${source_relative}" >/dev/null
  prepared_app_sandbox_replacement_created=0

  after_bytes="$(capture_or_exit "read source size after replacement" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch stat -c %s "${source_relative}")"
  after_mtime="$(capture_or_exit "read source mtime after replacement" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch stat -c %y "${source_relative}")"
  after_inode="$(capture_or_exit "read source inode after replacement" \
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch stat -c %i "${source_relative}")"
  after_byte="$(capture_or_exit "read source content marker after replacement" \
    "${adb_bin}" -s "${serial}" shell \
      "run-as app.droidmatch sh -c 'dd if=${source_relative} bs=1 count=1 2>/dev/null | od -An -tu1'")"
  after_byte="$(tr -d '[:space:]' <<<"${after_byte}")"
  after_bytes="$(tr -d '[:space:]' <<<"${after_bytes}")"
  after_inode="$(tr -d '[:space:]' <<<"${after_inode}")"
  after_mtime="$(tr -d '\r' <<<"${after_mtime}")"

  if ! [[ "${before_bytes}" =~ ^[0-9]+$ && "${after_bytes}" =~ ^[0-9]+$ \
      && "${before_inode}" =~ ^[0-9]+$ && "${after_inode}" =~ ^[0-9]+$ \
      && "${before_byte}" =~ ^[0-9]+$ && "${after_byte}" =~ ^[0-9]+$ ]] \
      || [[ "${before_bytes}" != "${after_bytes}" \
      || "${before_mtime}" != "${after_mtime}" \
      || "${before_inode}" == "${after_inode}" \
      || "${before_byte}" != "0" \
      || "${after_byte}" != "120" ]]; then
    fail_with_log "source replacement verification" \
      "Same-metadata source replacement did not preserve size/mtime while changing inode/content."
  fi

  download_source_replacement_output="$({
    printf 'replacement: same-directory atomic rename after partial download\n'
    printf 'size_preserved=true mtime_preserved=true inode_changed=true content_changed=true\n'
    if [[ -n "${replacement_output}" ]]; then
      printf 'replacement seed: completed (%s bytes)\n' "${after_bytes}"
    fi
  })"
  print_redacted_output "${download_source_replacement_output}"
}

assert_source_replacement_resume_rejected() {
  local output="$1" status="$2"
  if [[ "${status}" -eq 0 ]]; then
    fail_with_log "source replacement resume" \
      "Resume unexpectedly succeeded after same-metadata atomic source replacement.\n${output}"
  fi
  if ! grep -Eq 'remote error(:[[:space:]]|[[:space:]])invalidArgument([:[:space:]]|$)' <<<"${output}"; then
    fail_with_log "source replacement resume" \
      "Expected invalidArgument source fingerprint rejection after replacement.\n${output}"
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
