#!/usr/bin/env bash

# Destination-specific cleanup and the single exit cleanup owner.
# This sourced helper defines behavior only; the runner retains orchestration.
# 中文：此 helper 只定义职责行为，最终编排仍由主 runner 持有。

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
  local destination="$1" local_relative staging_glob
  if [[ -z "${serial:-}" || -z "${destination}" ]]; then
    return 0
  fi
  if [[ "${destination}" == dm://app-sandbox/* ]]; then
    local_relative="${destination#dm://app-sandbox/}"
    if [[ -n "${local_relative}" && "${local_relative}" != *".."* && "${local_relative}" != /* ]]; then
      staging_glob="$(app_sandbox_upload_staging_glob "${local_relative}")" || return 0
      # The final path and every transfer-scoped private partial for that exact
      # logical destination are owned by an explicit smoke cleanup request.
      "${adb_bin}" -s "${serial}" shell run-as app.droidmatch rm -f \
        "files/droidmatch-sandbox/${local_relative}" >/dev/null 2>&1 || true
      "${adb_bin}" -s "${serial}" shell \
        "run-as app.droidmatch sh -c 'rm -f ${staging_glob}; rmdir files/.droidmatch-sandbox.droidmatch-upload-staging 2>/dev/null || true'" \
        >/dev/null 2>&1 || true
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
upload_destination_cleanup_is_owned() {
  [[ "${cleanup_upload_destination:-0}" -eq 1 ]] || return 1
  [[ "${require_disposable_app_sandbox_paths:-0}" -ne 1 \
    || "${disposable_app_sandbox_paths_reserved:-0}" -eq 1 ]]
}

cleanup() {
  if [[ -n "${adb_baseline_download_temp_file:-}" ]]; then
    rm -f "${adb_baseline_download_temp_file}" >/dev/null 2>&1 || true
  fi
  # Keep the active forward alive until remote SAF cleanup completes.
  # The remaining cleanup paths use adb shell directly and can run after the
  # forward is removed.
  if upload_destination_cleanup_is_owned; then
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
  if [[ "${prepared_app_sandbox_replacement_created:-0}" -eq 1 \
      && -n "${serial:-}" \
      && -n "${prepared_app_sandbox_replacement_name:-}" ]]; then
    "${adb_bin}" -s "${serial}" shell run-as app.droidmatch rm -f \
      "files/droidmatch-sandbox/${prepared_app_sandbox_replacement_name}" >/dev/null 2>&1 || true
  fi
  if [[ ( "${download_resume_source_mutation_check:-0}" -eq 1 \
        || "${download_resume_source_deletion_check:-0}" -eq 1 \
        || "${download_resume_source_replacement_check:-0}" -eq 1 ) \
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
