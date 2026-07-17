#!/usr/bin/env bash

# Pure command-line parsing and cross-option validation for the attended M1
# physical-device runner. This file must not perform ADB, device mutation,
# cleanup, build, or evidence-writing work.
# 中文：这里只负责参数解析与交叉校验，不得执行真机操作或写入证据。

parse_m1_device_smoke_options() {
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
      --download-resume-source-replacement-check)
        download_resume_source_replacement_check=1
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
    prepared_app_sandbox_replacement_name=".${prepare_app_sandbox_file}.droidmatch-source-replacement"
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
        && "${download_resume_source_deletion_check}" -ne 1 \
        && "${download_resume_source_replacement_check}" -ne 1 ]]; then
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
    # Keep attended evidence paths in the canonical `/private/tmp` spelling so
    # archived records stay comparable. The product writer also accepts the fixed
    # `/tmp` system alias. 中文：真机证据统一使用规范路径，便于归档比较。
    download_destination="/private/tmp/droidmatch-device-smoke-download-${$}.bin"
  fi
  if [[ "${download_resume_source_mutation_check}" != "0" && "${download_resume_source_mutation_check}" != "1" ]]; then
    printf '%s\n' "--download-resume-source-mutation-check must be 0 or 1 when set through DROIDMATCH_DOWNLOAD_RESUME_SOURCE_MUTATION_CHECK: ${download_resume_source_mutation_check}" >&2
    exit 2
  fi
  if [[ "${download_resume_source_deletion_check}" != "0" && "${download_resume_source_deletion_check}" != "1" ]]; then
    printf '%s\n' "--download-resume-source-deletion-check must be 0 or 1 when set through DROIDMATCH_DOWNLOAD_RESUME_SOURCE_DELETION_CHECK: ${download_resume_source_deletion_check}" >&2
    exit 2
  fi
  if [[ "${download_resume_source_replacement_check}" != "0" && "${download_resume_source_replacement_check}" != "1" ]]; then
    printf '%s\n' "--download-resume-source-replacement-check must be 0 or 1 when set through DROIDMATCH_DOWNLOAD_RESUME_SOURCE_REPLACEMENT_CHECK: ${download_resume_source_replacement_check}" >&2
    exit 2
  fi
  if (( download_resume_source_mutation_check \
      + download_resume_source_deletion_check \
      + download_resume_source_replacement_check > 1 )); then
    printf '%s\n' '--download resume source mutation, deletion, and replacement checks must be run separately.' >&2
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
  if [[ "${download_resume_source_mutation_check}" -eq 1 \
      || "${download_resume_source_deletion_check}" -eq 1 \
      || "${download_resume_source_replacement_check}" -eq 1 ]]; then
    if [[ "${resume_check}" -ne 1 ]]; then
      printf '%s\n' '--download resume source mutation/deletion/replacement checks require --resume-check.' >&2
      exit 2
    fi
    if [[ -z "${prepare_app_sandbox_file}" || "${download_source_path}" != "${prepared_app_sandbox_source_path}" ]]; then
      printf '%s\n' '--download resume source mutation/deletion/replacement checks require --prepare-app-sandbox-file as their --source-path.' >&2
      exit 2
    fi
    if [[ "${keep_prepared_app_sandbox_file}" -eq 1 ]]; then
      printf '%s\n' '--download resume source mutation/deletion/replacement checks cannot keep their destructive temporary source.' >&2
      exit 2
    fi
    if [[ "${download_retry_on_transport_loss}" -eq 1 || "${download_retry_fault_check}" -eq 1 ]]; then
      printf '%s\n' '--download resume source mutation/deletion/replacement checks cannot be combined with download transport-loss retry checks.' >&2
      exit 2
    fi
    if (( min_download_bytes > 0 )) \
        || awk -v value="${min_download_mib_per_second}" 'BEGIN { exit !((value + 0) > 0) }'; then
      printf '%s\n' '--download resume source mutation/deletion/replacement checks cannot be combined with download size or throughput gates.' >&2
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
  if (( download_retry_fault_check == 1 && resume_check == 0 \
      && (cancel_check == 1 || pause_check == 1) )); then
    printf '%s\n' '--download-retry-fault-check requires --resume-check when combined with cancel/pause checks.' >&2
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
}

# Post-parse validation that depends on local file sizes and retry-window policy.
# It mutates only runner configuration values and performs no device I/O.
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

finalize_m1_device_smoke_options() {
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
  if (( upload_retry_fault_check == 1 && upload_retry_ack_loss_check == 1 )); then
    printf '%s\n' '--upload-retry-fault-check and --upload-retry-ack-loss-check must be run separately.' >&2
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

}
