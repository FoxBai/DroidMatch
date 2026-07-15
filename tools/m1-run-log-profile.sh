#!/usr/bin/env bash

# Internal semantic validator for versioned M1 device evidence and the frozen
# legacy archive. The public entry point owns CLI parsing and privacy scans.
# 中文：M1 设备证据语义校验与冻结历史归档的内部库；公开入口负责 CLI 与隐私扫描。

legacy_manifest="fixtures/m1-runs/legacy-v0.sha256"
legacy_manifest_sha256="714d600a533a2cd8b44006337b399ec0244f0a044cae01d8d898a4889c6b5a69"
source "${repo_root}/tools/m1-run-log-common.sh"
device_profile_fields=(
  'device profile result'
  'device profile archive class'
  'device profile source revision'
  'device profile source state'
  'device profile build mode'
  'device profile apk sha256'
  'device profile harness configuration'
  'device profile device slot'
  'device profile android api'
  'device profile checks requested'
  'device profile checks passed'
  'device profile checks incomplete'
  'device profile failure stage'
  'device profile handshake attempts'
  'device profile handshake passed'
  'device profile handshake minimum'
  'device profile list elapsed ms'
  'device profile list maximum ms'
  'device profile download bytes'
  'device profile download measured bytes'
  'device profile download elapsed ms'
  'device profile download observed mib per second'
  'device profile download minimum bytes'
  'device profile download minimum mib per second'
  'device profile upload bytes'
  'device profile upload measured bytes'
  'device profile upload elapsed ms'
  'device profile upload observed mib per second'
  'device profile upload minimum bytes'
  'device profile upload minimum mib per second'
  'device profile cleanup'
)

device_check_ids=(
  'm1-smoke'
  'adb-baseline'
  'list-dir'
  'list-expected-error'
  'media-permission-revoked'
  'download-open-expected-error'
  'download'
  'download-resume'
  'download-source-mutation'
  'download-source-deletion'
  'download-source-replacement'
  'download-cancel'
  'download-pause'
  'download-retry'
  'download-retry-fault'
  'media-permission-during-download'
  'dual-download'
  'upload'
  'upload-resume'
  'upload-resume-unsupported'
  'upload-retry'
  'upload-retry-fault'
  'upload-ack-loss'
  'mixed-transfer'
)

device_profile_value() {
  local log="$1" field="$2" count value
  count="$(grep_count -c "^${field}:" "${log}")" || return 1
  if [[ "${count}" -ne 1 ]]; then
    printf 'device evidence field must appear exactly once (%s): %s\n' \
      "${field}" "${log}" >&2
    return 1
  fi
  value="$(sed -n "s/^${field}: //p" "${log}" 2>/dev/null)" || return 1
  printf '%s\n' "${value}"
}

has_prefix() {
  local value="$1" prefix
  shift
  for prefix in "$@"; do
    [[ "${value}" == "${prefix}"* ]] && return 0
  done
  return 1
}

check_set_contains() {
  local set="$1" check_id="$2"
  [[ ",${set}," == *",${check_id},"* ]]
}

check_set_count() {
  local set="$1" check_id count=0
  shift
  for check_id in "$@"; do
    if check_set_contains "${set}" "${check_id}"; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "${count}"
}

require_check_dependencies() {
  local set="$1" child="$2" dependency
  shift 2
  check_set_contains "${set}" "${child}" || return 0
  for dependency in "$@"; do
    check_set_contains "${set}" "${dependency}" || return 1
  done
}

require_check_marker() {
  local log="$1" set="$2" check_id="$3" pattern="$4" count
  count="$(grep_count -Ec "${pattern}" "${log}")" || return 1
  if check_set_contains "${set}" "${check_id}"; then
    [[ "${count}" -ge 1 ]]
  else
    [[ "${count}" -eq 0 ]]
  fi
}

validate_transfer_metric_tuple() {
  local measured_bytes="$1" elapsed_ms="$2" observed="$3"
  if [[ "${measured_bytes}" == 'not-run' \
      && "${elapsed_ms}" == 'not-run' \
      && "${observed}" == 'not-run' ]]; then
    return 0
  fi
  [[ "${measured_bytes}" =~ ^[0-9]{1,18}$ \
      && "${elapsed_ms}" =~ ^[1-9][0-9]{0,17}$ \
      && "${observed}" =~ ^[0-9]{1,12}([.][0-9]{1,6})?$ ]] || return 1
  awk \
    -v bytes="${measured_bytes}" \
    -v elapsed_ms="${elapsed_ms}" \
    -v observed="${observed}" \
    'BEGIN {
      expected = (bytes / 1048576) / (elapsed_ms / 1000)
      delta = observed - expected
      if (delta < 0) delta = -delta
      exit !(delta <= 0.011)
    }'
}

validate_device_check_set() {
  local set="$1" allow_none="$2" item check_id known index last_index=-1 seen=','
  local items=()
  if [[ "${set}" == 'none' ]]; then
    [[ "${allow_none}" -eq 1 ]]
    return
  fi
  [[ -n "${set}" \
      && "${set}" != *",,"* \
      && "${set}" != ","* \
      && "${set}" != *"," ]] \
    || return 1
  IFS=',' read -r -a items <<<"${set}"
  for item in "${items[@]}"; do
    known=0
    index=0
    for check_id in "${device_check_ids[@]}"; do
      if [[ "${item}" == "${check_id}" ]]; then
        known=1
        break
      fi
      index=$((index + 1))
    done
    [[ "${known}" -eq 1 && "${index}" -gt "${last_index}" ]] || return 1
    [[ "${seen}" != *",${item},"* ]] || return 1
    seen+="${item},"
    last_index="${index}"
  done
}

valid_integer_or_not_run() {
  local value="$1"
  [[ "${value}" == 'not-run' || "${value}" =~ ^[0-9]{1,18}$ ]]
}

valid_positive_integer_or_not_run() {
  local value="$1"
  [[ "${value}" == 'not-run' || "${value}" =~ ^[1-9][0-9]{0,17}$ ]]
}

valid_decimal_or_not_run() {
  local value="$1"
  [[ "${value}" == 'not-run' \
      || "${value}" =~ ^[0-9]{1,12}([.][0-9]{1,6})?$ ]]
}

validate_device_smoke_profile() {
  local log="$1" status result archive_class source_revision source_state
  local build_mode apk_sha harness_configuration profile_slot profile_api
  local requested passed incomplete profile_failure_stage cleanup
  local attempts passed_attempts minimum summary_attempts summary_passed summary_minimum
  local list_elapsed list_max download_bytes download_measured download_elapsed download_observed
  local download_minimum_bytes download_minimum_rate upload_bytes upload_elapsed
  local upload_measured upload_observed upload_minimum_bytes upload_minimum_rate
  local title date_value slot api_value build_value build_sha build_dirty field allowed_field
  local known_field line value count first_list download_summary upload_summary
  local resume_summary permission_summary diagnostics_summary dual_summary mixed_summary
  local adb_summary cancel_summary pause_summary permission_suffix timed_list_re
  local handshake_re build_re serial_tag_re failure_stage_re failure_stage_value
  local check_id variable_name marker_count expected_archive manufacturer_model android_release

  for field in "${required_fields[@]}"; do
    count="$(grep_count -c "^${field}" "${log}")" || return 1
    [[ "${count}" == '1' ]] || return 1
  done
  for field in \
    'status' \
    'dual-stream download' \
    'mixed-stream transfer' \
    'adb baseline download' \
    'cancel result' \
    'pause result'; do
    count="$(grep_count -c "^${field}:" "${log}")" || return 1
    [[ "${count}" == '1' ]] || return 1
  done
  count="$(grep_count -Fxc 'notes:' "${log}")" || return 1
  [[ "${count}" == '1' ]] || return 1

  while IFS= read -r line; do
    [[ "${line}" == device\ profile\ *:* ]] || continue
    field="${line%%:*}"
    known_field=0
    for allowed_field in "${device_profile_fields[@]}"; do
      if [[ "${field}" == "${allowed_field}" ]]; then
        known_field=1
        break
      fi
    done
    [[ "${known_field}" -eq 1 ]] || return 1
  done <"${log}" || return 1

  status="$(sed -n 's/^status: //p' "${log}")"
  result="$(device_profile_value "${log}" 'device profile result')"
  [[ "${status}" =~ ^(passed|failed)$ && "${result}" == "${status}" ]] || return 1
  archive_class="$(device_profile_value "${log}" 'device profile archive class')"
  source_revision="$(device_profile_value "${log}" 'device profile source revision')"
  source_state="$(device_profile_value "${log}" 'device profile source state')"
  build_mode="$(device_profile_value "${log}" 'device profile build mode')"
  apk_sha="$(device_profile_value "${log}" 'device profile apk sha256')"
  harness_configuration="$(device_profile_value "${log}" 'device profile harness configuration')"
  profile_slot="$(device_profile_value "${log}" 'device profile device slot')"
  profile_api="$(device_profile_value "${log}" 'device profile android api')"
  requested="$(device_profile_value "${log}" 'device profile checks requested')"
  passed="$(device_profile_value "${log}" 'device profile checks passed')"
  incomplete="$(device_profile_value "${log}" 'device profile checks incomplete')"
  profile_failure_stage="$(device_profile_value "${log}" 'device profile failure stage')"
  cleanup="$(device_profile_value "${log}" 'device profile cleanup')"

  [[ "${build_mode}" =~ ^(rebuilt|reused)$ \
      && "${apk_sha}" =~ ^[0-9a-f]{64}$ \
      && "${harness_configuration}" == 'release' \
      && "${cleanup}" == 'scheduled-on-exit' ]] || return 1
  validate_device_check_set "${requested}" 0 || return 1
  validate_device_check_set "${passed}" 1 || return 1
  validate_device_check_set "${incomplete}" 1 || return 1
  [[ "${requested}" == 'm1-smoke' || "${requested}" == m1-smoke,* ]] || return 1
  require_check_dependencies "${requested}" 'media-permission-revoked' \
    'list-expected-error' || return 1
  for check_id in \
    'download-resume' \
    'download-cancel' \
    'download-pause' \
    'download-retry' \
    'media-permission-during-download' \
    'dual-download'; do
    require_check_dependencies "${requested}" "${check_id}" 'download' || return 1
  done
  require_check_dependencies "${requested}" 'download-retry-fault' \
    'download' 'download-retry' || return 1
  for check_id in \
    'download-source-mutation' \
    'download-source-deletion' \
    'download-source-replacement'; do
    require_check_dependencies "${requested}" "${check_id}" \
      'download' 'download-resume' || return 1
  done
  for check_id in \
    'upload-resume' \
    'upload-resume-unsupported' \
    'upload-retry'; do
    require_check_dependencies "${requested}" "${check_id}" 'upload' || return 1
  done
  require_check_dependencies "${requested}" 'upload-retry-fault' \
    'upload' 'upload-retry' || return 1
  require_check_dependencies "${requested}" 'upload-ack-loss' \
    'upload' 'upload-resume' 'upload-retry' || return 1
  require_check_dependencies "${requested}" 'mixed-transfer' \
    'download' 'upload' || return 1
  [[ "$(check_set_count "${requested}" \
      'download-source-mutation' \
      'download-source-deletion' \
      'download-source-replacement')" -le 1 ]] || return 1
  [[ "$(check_set_count "${requested}" \
      'media-permission-revoked' \
      'media-permission-during-download')" -le 1 ]] || return 1
  [[ "$(check_set_count "${requested}" \
      'upload-resume' \
      'upload-resume-unsupported')" -le 1 ]] || return 1
  [[ "$(check_set_count "${requested}" \
      'upload-retry-fault' 'upload-ack-loss')" -le 1 ]] || return 1
  [[ "$(check_set_count "${requested}" 'download-retry-fault' \
      'download-source-mutation' 'download-source-deletion' \
      'download-source-replacement' 'media-permission-during-download')" -le 1 ]] || return 1
  if check_set_contains "${requested}" 'download-retry-fault' \
      && ! check_set_contains "${requested}" 'download-resume'; then
    [[ "$(check_set_count "${requested}" 'download-cancel' 'download-pause')" -eq 0 ]] \
      || return 1
  fi

  count="$(grep_count -c '^failure stage:' "${log}")" || return 1
  if [[ "${status}" == 'passed' ]]; then
    [[ "${archive_class}" =~ ^(device-evidence|diagnostic-only)$ \
        && "${passed}" == "${requested}" \
        && "${incomplete}" == 'none' \
        && "${profile_failure_stage}" == 'none' \
        && "${count}" == '0' ]] || return 1
  else
    [[ "${archive_class}" == 'failed-diagnostic' \
        && "${passed}" == 'none' \
        && "${incomplete}" == "${requested}" \
        && "${profile_failure_stage}" != 'none' \
        && "${count}" == '1' ]] || return 1
    failure_stage_value="$(sed -n 's/^failure stage: //p' "${log}")"
    failure_stage_re='^[A-Za-z0-9._:/ -]{1,120}$'
    [[ "${failure_stage_value}" == "${profile_failure_stage}" \
        && "${failure_stage_value}" =~ ${failure_stage_re} ]] || return 1
  fi

  date_value="$(sed -n 's/^date: //p' "${log}")"
  title="$(head -n 1 "${log}")" || return 1
  [[ "${date_value}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}Z$ \
      && "${title}" == "# ${date_value} ADB Device Smoke" ]] || return 1
  python3 - "${date_value}" <<'PY' >/dev/null 2>&1 || return 1
import datetime
import sys
datetime.datetime.strptime(sys.argv[1], "%Y-%m-%d %H:%M:%SZ")
PY

  slot="$(sed -n 's/^device slot: //p' "${log}")"
  api_value="$(sed -n 's/^android version\/api: Android .* \/ API \([0-9][0-9]*\)$/\1/p' "${log}")"
  manufacturer_model="$(sed -n 's/^manufacturer\/model: //p' "${log}")"
  android_release="$(
    sed -n 's/^android version\/api: Android \(.*\) \/ API .*$/\1/p' "${log}"
  )"
  [[ "${slot}" =~ ^(A|B|C|D|E|unclassified)$ \
      && "${profile_slot}" == "${slot}" \
      && "${manufacturer_model}" =~ [^[:space:]] \
      && "${android_release}" =~ [^[:space:]] ]] || return 1
  if [[ "${status}" == 'failed' && "${profile_api}" == 'unknown' ]]; then
    [[ "$(sed -n 's/^android version\/api: //p' "${log}")" \
        == 'Android unknown / API unknown' ]] || return 1
  else
    [[ "${api_value}" =~ ^[0-9]{2}$ && "${profile_api}" == "${api_value}" ]] \
      || return 1
    case "${slot}" in
      A) (( api_value >= 26 && api_value <= 29 )) || return 1 ;;
      B) (( api_value >= 30 && api_value <= 32 )) || return 1 ;;
      C) (( api_value >= 33 && api_value <= 35 )) || return 1 ;;
      D|E) (( api_value >= 30 && api_value <= 99 )) || return 1 ;;
      unclassified) (( api_value >= 26 && api_value <= 99 )) || return 1 ;;
    esac
  fi

  build_value="$(sed -n 's/^build channel: //p' "${log}")"
  build_re='^local release Swift harness \+ debug APK from git ([0-9a-f]{7,40})(-dirty)?$'
  if [[ "${build_value}" == 'local release Swift harness + debug APK from git unknown' ]]; then
    [[ "${source_state}" == 'unknown' && "${source_revision}" == 'unknown' ]] || return 1
  elif [[ "${build_value}" =~ ${build_re} ]]; then
    build_sha="${BASH_REMATCH[1]}"
    build_dirty="${BASH_REMATCH[2]:-}"
    [[ "${source_revision}" =~ ^[0-9a-f]{40}$ \
        && "${source_revision:0:${#build_sha}}" == "${build_sha}" ]] || return 1
    if [[ -n "${build_dirty}" ]]; then
      [[ "${source_state}" == 'dirty' ]] || return 1
    else
      [[ "${source_state}" == 'clean' ]] || return 1
    fi
  else
    return 1
  fi
  if [[ "${status}" == 'passed' ]]; then
    expected_archive='diagnostic-only'
    if [[ "${source_state}" == 'clean' && "${build_mode}" == 'rebuilt' ]]; then
      expected_archive='device-evidence'
    fi
    [[ "${archive_class}" == "${expected_archive}" ]] || return 1
  fi

  [[ "$(sed -n 's/^transport: //p' "${log}")" \
      == 'ADB forward to debug harness Activity endpoint' ]] || return 1
  [[ "$(sed -n 's/^visible time: //p' "${log}")" \
      == 'device already authorized over USB before script start' ]] || return 1

  attempts="$(device_profile_value "${log}" 'device profile handshake attempts')"
  passed_attempts="$(device_profile_value "${log}" 'device profile handshake passed')"
  minimum="$(device_profile_value "${log}" 'device profile handshake minimum')"
  [[ "${attempts}" =~ ^[1-9][0-9]{0,5}$ \
      && "${passed_attempts}" =~ ^[0-9]{1,6}$ \
      && "${minimum}" =~ ^[1-9][0-9]{0,5}$ ]] || return 1
  (( passed_attempts <= attempts && minimum <= attempts )) || return 1
  handshake_re='^([0-9]+)/([0-9]+) passed via `m1-smoke` \(minimum ([0-9]+)\)$'
  value="$(sed -n 's/^handshake attempts: //p' "${log}")"
  [[ "${value}" =~ ${handshake_re} ]] || return 1
  summary_passed="${BASH_REMATCH[1]}"
  summary_attempts="${BASH_REMATCH[2]}"
  summary_minimum="${BASH_REMATCH[3]}"
  [[ "${summary_attempts}" == "${attempts}" \
      && "${summary_passed}" == "${passed_attempts}" \
      && "${summary_minimum}" == "${minimum}" ]] || return 1
  if [[ "${status}" == 'passed' ]]; then
    (( passed_attempts >= minimum )) || return 1
  fi

  list_elapsed="$(device_profile_value "${log}" 'device profile list elapsed ms')"
  list_max="$(device_profile_value "${log}" 'device profile list maximum ms')"
  download_bytes="$(device_profile_value "${log}" 'device profile download bytes')"
  download_measured="$(
    device_profile_value "${log}" 'device profile download measured bytes'
  )"
  download_elapsed="$(device_profile_value "${log}" 'device profile download elapsed ms')"
  download_observed="$(device_profile_value "${log}" 'device profile download observed mib per second')"
  download_minimum_bytes="$(device_profile_value "${log}" 'device profile download minimum bytes')"
  download_minimum_rate="$(device_profile_value "${log}" 'device profile download minimum mib per second')"
  upload_bytes="$(device_profile_value "${log}" 'device profile upload bytes')"
  upload_measured="$(device_profile_value "${log}" 'device profile upload measured bytes')"
  upload_elapsed="$(device_profile_value "${log}" 'device profile upload elapsed ms')"
  upload_observed="$(device_profile_value "${log}" 'device profile upload observed mib per second')"
  upload_minimum_bytes="$(device_profile_value "${log}" 'device profile upload minimum bytes')"
  upload_minimum_rate="$(device_profile_value "${log}" 'device profile upload minimum mib per second')"
  valid_integer_or_not_run "${list_elapsed}" || return 1
  [[ "${list_max}" =~ ^[0-9]{1,18}$ ]] || return 1
  valid_integer_or_not_run "${download_bytes}" || return 1
  valid_integer_or_not_run "${download_measured}" || return 1
  valid_positive_integer_or_not_run "${download_elapsed}" || return 1
  valid_decimal_or_not_run "${download_observed}" || return 1
  [[ "${download_minimum_bytes}" =~ ^[0-9]{1,18}$ \
      && "${download_minimum_rate}" =~ ^[0-9]{1,12}([.][0-9]{1,6})?$ ]] || return 1
  valid_integer_or_not_run "${upload_bytes}" || return 1
  valid_integer_or_not_run "${upload_measured}" || return 1
  valid_positive_integer_or_not_run "${upload_elapsed}" || return 1
  valid_decimal_or_not_run "${upload_observed}" || return 1
  [[ "${upload_minimum_bytes}" =~ ^[0-9]{1,18}$ \
      && "${upload_minimum_rate}" =~ ^[0-9]{1,12}([.][0-9]{1,6})?$ ]] || return 1
  validate_transfer_metric_tuple \
    "${download_measured}" "${download_elapsed}" "${download_observed}" || return 1
  validate_transfer_metric_tuple \
    "${upload_measured}" "${upload_elapsed}" "${upload_observed}" || return 1
  if [[ "${status}" == 'passed' && "${download_measured}" != "${download_bytes}" ]] \
      && ! check_set_contains "${requested}" 'download-resume'; then
    check_set_contains "${requested}" 'download-retry' \
      && section_has_pattern "${log}" '## Download Output' \
        '(^| )recovered=true( |$)' || return 1
  fi
  if [[ "${status}" == 'passed' && "${upload_measured}" != "${upload_bytes}" ]] \
      && ! check_set_contains "${requested}" 'upload-resume'; then
    check_set_contains "${requested}" 'upload-retry' \
      && section_has_pattern "${log}" '## Upload Output' \
        '(^| )recovered=true( |$)' || return 1
  fi

  first_list="$(sed -n 's/^first list time: //p' "${log}")"
  timed_list_re='^[0-9]+ ms for `(<dm-path-redacted>|dm://[A-Za-z0-9._/-]+)`( \(max [0-9]+ ms\))?$'
  if check_set_contains "${requested}" 'list-dir'; then
    if [[ "${status}" == 'passed' ]]; then
      [[ "${list_elapsed}" != 'not-run' && "${first_list}" =~ ${timed_list_re} \
          && "${first_list}" == "${list_elapsed} ms for "* ]] || return 1
      if (( list_max > 0 )); then
        awk -v value="${list_elapsed}" -v maximum="${list_max}" \
          'BEGIN { exit !(value <= maximum) }' || return 1
      fi
    fi
  else
    [[ "${list_elapsed}" == 'not-run' && "${first_list}" == 'not measured by this script' ]] \
      || return 1
  fi

  download_summary="$(sed -n 's/^100MB download: //p' "${log}")"
  upload_summary="$(sed -n 's/^100MB upload: //p' "${log}")"
  resume_summary="$(sed -n 's/^resume result: //p' "${log}")"
  dual_summary="$(sed -n 's/^dual-stream download: //p' "${log}")"
  mixed_summary="$(sed -n 's/^mixed-stream transfer: //p' "${log}")"
  adb_summary="$(sed -n 's/^adb baseline download: //p' "${log}")"
  cancel_summary="$(sed -n 's/^cancel result: //p' "${log}")"
  pause_summary="$(sed -n 's/^pause result: //p' "${log}")"
  permission_summary="$(sed -n 's/^permission cases: //p' "${log}")"
  diagnostics_summary="$(sed -n 's/^diagnostics bundle: //p' "${log}")"

  require_check_marker "${log}" "${requested}" 'adb-baseline' \
    '^- ADB baseline download: enabled via ' || return 1
  require_check_marker "${log}" "${requested}" 'list-expected-error' \
    '^- list expected-error path: ' || return 1
  require_check_marker "${log}" "${requested}" 'media-permission-revoked' \
    '^- media permission revoked check: ' || return 1
  require_check_marker "${log}" "${requested}" 'download-open-expected-error' \
    '^- download open expected-error path: ' || return 1
  require_check_marker "${log}" "${requested}" 'download-resume' \
    '^## Partial Download Output$' || return 1
  require_check_marker "${log}" "${requested}" 'download-source-mutation' \
    '^- download source mutation check: ' || return 1
  require_check_marker "${log}" "${requested}" 'download-source-deletion' \
    '^- download source deletion check: ' || return 1
  require_check_marker "${log}" "${requested}" 'download-source-replacement' \
    '^- download source replacement check: ' || return 1
  require_check_marker "${log}" "${requested}" 'download-retry' \
    '^- download transport-loss retry: enabled ' || return 1
  require_check_marker "${log}" "${requested}" 'download-retry-fault' \
    '^- download transport-loss fault check: ' || return 1
  require_check_marker "${log}" "${requested}" 'media-permission-during-download' \
    '^- media permission revoked during download check: ' || return 1
  require_check_marker "${log}" "${requested}" 'upload' \
    '^- upload destination: ' || return 1
  require_check_marker "${log}" "${requested}" 'upload-resume' \
    '^- upload partial bytes: ' || return 1
  require_check_marker "${log}" "${requested}" 'upload-resume-unsupported' \
    '^- upload resume unsupported check: ' || return 1
  require_check_marker "${log}" "${requested}" 'upload-retry' \
    '^- upload transport-loss retry: enabled ' || return 1
  require_check_marker "${log}" "${requested}" 'upload-retry-fault' \
    '^- upload transport-loss fault check: ' || return 1
  require_check_marker "${log}" "${requested}" 'upload-ack-loss' \
    '^- upload ACK-loss retry check: ' || return 1
  require_check_marker "${log}" "${requested}" 'mixed-transfer' \
    '^- mixed transfer check: ' || return 1

  [[ "${download_summary}" == 'not run' ]] || has_prefix "${download_summary}" \
    'source-deletion check used ' \
    'source-replacement check used ' \
    'source-mutation check used ' \
    'media permission revoked during ' \
    'partial download plus resume ' \
    'resume-check requested ' \
    'cancel-check ' \
    'pause-check ' \
    '`download` command ' \
    '`download` requested ' || return 1
  [[ "${upload_summary}" == 'not run' ]] || has_prefix "${upload_summary}" \
    'partial upload plus resume ' \
    'upload-resume-check requested ' \
    'fresh-only resume unsupported check ' \
    '`upload` command ' \
    '`upload` requested ' || return 1
  [[ "${resume_summary}" == 'not run' ]] || has_prefix "${resume_summary}" \
    'partial stop after at least ' \
    'resume-check requested but did not complete' || return 1
  [[ "${dual_summary}" == 'not run' ]] || has_prefix "${dual_summary}" \
    '`dual-download-smoke` passed ' \
    'requested for ' || return 1
  [[ "${mixed_summary}" == 'not run' ]] || has_prefix "${mixed_summary}" \
    '`mixed-transfer-smoke` passed ' \
    'requested for ' || return 1
  [[ "${adb_summary}" == 'not run' ]] || has_prefix "${adb_summary}" \
    '`exec-out run-as cat` read ' \
    'requested for ' || return 1
  [[ "${cancel_summary}" == 'not run' ]] || has_prefix "${cancel_summary}" \
    '`download-cancel` passed ' \
    'cancel-check requested but did not complete' || return 1
  [[ "${pause_summary}" == 'not run' ]] || has_prefix "${pause_summary}" \
    '`download-pause` passed ' \
    'pause-check requested but did not complete' || return 1
  [[ "${diagnostics_summary}" == '`m1-smoke` output included below' ]] || return 1

  if [[ "${permission_summary}" == 'launcher entry resolved to `DroidMatchActivity`; '* ]]; then
    permission_suffix="${permission_summary#launcher entry resolved to \`DroidMatchActivity\`; }"
    has_prefix "${permission_suffix}" \
      'detailed permission-denied cases not run' \
      'media permission revoked ' \
      'list expected-error check passed ' \
      'download open expected-error check passed ' || return 1
  elif [[ "${status}" == 'failed' ]]; then
    [[ "${permission_summary}" == \
      'launcher entry not resolved before failure; detailed permission-denied cases not run' ]] \
      || return 1
  else
    return 1
  fi

  if [[ "${status}" == 'passed' ]]; then
    for value in \
      "${first_list}" "${download_summary}" "${upload_summary}" "${resume_summary}" \
      "${dual_summary}" "${mixed_summary}" "${adb_summary}" \
      "${cancel_summary}" "${pause_summary}" "${permission_summary}"; do
      case "${value}" in
        *'did not complete'*|*'not completed'*|*'command failed'*|*'final status failed'*|*'below required'*|*'run failed'*)
          return 1
          ;;
      esac
    done
    if check_set_contains "${requested}" 'list-expected-error'; then
      [[ "${permission_summary}" == *'list expected-error check passed '* \
          || "${permission_summary}" == *'media permission revoked check passed '* ]] \
        || return 1
    fi
    if check_set_contains "${requested}" 'media-permission-revoked'; then
      [[ "${permission_summary}" == *'media permission revoked check passed '* ]] \
        || return 1
    fi
    if check_set_contains "${requested}" 'download-open-expected-error'; then
      [[ "${permission_summary}" == *'download open expected-error check passed '* ]] \
        || return 1
    fi
    if check_set_contains "${requested}" 'download-source-mutation'; then
      [[ "${download_summary}" == 'source-mutation check used '* \
          && "${resume_summary}" == *'changed source was rejected'* ]] || return 1
    fi
    if check_set_contains "${requested}" 'download-source-deletion'; then
      [[ "${download_summary}" == 'source-deletion check used '* \
          && "${resume_summary}" == *'deleted source was rejected'* ]] || return 1
    fi
    if check_set_contains "${requested}" 'download-source-replacement'; then
      [[ "${download_summary}" == 'source-replacement check used '* \
          && "${resume_summary}" == *'source replacement was rejected'* ]] || return 1
    fi
    if check_set_contains "${requested}" 'media-permission-during-download'; then
      [[ "${permission_summary}" == *'media permission revoked during download check passed '* ]] \
        || return 1
    fi
    if check_set_contains "${requested}" 'upload-resume'; then
      [[ "${upload_summary}" == 'partial upload plus resume passed '* ]] || return 1
    fi
    if check_set_contains "${requested}" 'upload-resume-unsupported'; then
      [[ "${upload_summary}" == 'fresh-only resume unsupported check and `upload` passed '* ]] \
        || return 1
    fi
    if check_set_contains "${requested}" 'download-retry-fault'; then
      value='## Download Output'
      check_set_contains "${requested}" 'download-resume' \
        && value='## Resume Download Output'
      section_has_pattern "${log}" "${value}" '(^| )recovered=true( |$)' || return 1
    fi
    if check_set_contains "${requested}" 'upload-retry-fault' \
        || check_set_contains "${requested}" 'upload-ack-loss'; then
      value='## Upload Output'
      check_set_contains "${requested}" 'upload-resume' \
        && value='## Resume Upload Output'
      section_has_pattern "${log}" "${value}" '(^| )recovered=true( |$)' || return 1
    fi
  fi

  if check_set_contains "${requested}" 'download'; then
    [[ "${status}" == 'failed' || "${download_summary}" != 'not run' ]] || return 1
  else
    [[ "${download_summary}" == 'not run' \
        && "${download_bytes}" == 'not-run' \
        && "${download_measured}" == 'not-run' \
        && "${download_elapsed}" == 'not-run' \
        && "${download_observed}" == 'not-run' ]] || return 1
  fi
  if check_set_contains "${requested}" 'upload'; then
    [[ "${status}" == 'failed' || "${upload_summary}" != 'not run' ]] || return 1
  else
    [[ "${upload_summary}" == 'not run' \
        && "${upload_bytes}" == 'not-run' \
        && "${upload_measured}" == 'not-run' \
        && "${upload_elapsed}" == 'not-run' \
        && "${upload_observed}" == 'not-run' ]] || return 1
  fi
  if check_set_contains "${requested}" 'download-resume'; then
    [[ "${status}" == 'failed' || "${resume_summary}" != 'not run' ]] || return 1
  else
    [[ "${resume_summary}" == 'not run' ]] || return 1
  fi
  for field in \
    'adb-baseline:adb_summary' \
    'dual-download:dual_summary' \
    'mixed-transfer:mixed_summary' \
    'download-cancel:cancel_summary' \
    'download-pause:pause_summary'; do
    check_id="${field%%:*}"
    variable_name="${field#*:}"
    value="${!variable_name}"
    if check_set_contains "${requested}" "${check_id}"; then
      [[ "${status}" == 'failed' || "${value}" != 'not run' ]] || return 1
    else
      [[ "${value}" == 'not run' ]] || return 1
    fi
  done

  if [[ "${download_observed}" != 'not-run' ]]; then
    value="; throughput ${download_observed} MiB/s over ${download_elapsed} ms"
    if awk -v minimum="${download_minimum_rate}" \
        'BEGIN { exit !(minimum > 0) }'; then
      value+=" (required >= ${download_minimum_rate} MiB/s)"
    fi
    [[ "${download_summary}" == *"${value}"* ]] || return 1
  fi
  if [[ "${upload_observed}" != 'not-run' ]]; then
    value="; throughput ${upload_observed} MiB/s over ${upload_elapsed} ms"
    if awk -v minimum="${upload_minimum_rate}" \
        'BEGIN { exit !(minimum > 0) }'; then
      value+=" (required >= ${upload_minimum_rate} MiB/s)"
    fi
    [[ "${upload_summary}" == *"${value}"* ]] || return 1
  fi

  if [[ "${status}" == 'passed' ]]; then
    marker_count="$(check_set_count "${requested}" \
      'download-source-mutation' \
      'download-source-deletion' \
      'download-source-replacement' \
      'media-permission-during-download')"
    if check_set_contains "${requested}" 'download' \
        && [[ "${marker_count}" -eq 0 ]] \
        && { ! check_set_contains "${requested}" 'download-cancel' \
          || check_set_contains "${requested}" 'download-resume'; } \
        && { ! check_set_contains "${requested}" 'download-pause' \
          || check_set_contains "${requested}" 'download-resume'; }; then
      [[ "${download_measured}" != 'not-run' ]] || return 1
    fi
    if check_set_contains "${requested}" 'upload'; then
      [[ "${upload_measured}" != 'not-run' ]] || return 1
    fi
    if [[ "${download_minimum_bytes}" != '0' ]]; then
      [[ "${download_bytes}" != 'not-run' \
          && "${download_summary}" == *"bytes ${download_bytes} >= required ${download_minimum_bytes}"* ]] \
        || return 1
      awk -v value="${download_bytes}" -v minimum="${download_minimum_bytes}" \
        'BEGIN { exit !(value >= minimum) }' || return 1
    fi
    if awk -v minimum="${download_minimum_rate}" \
        'BEGIN { exit !(minimum > 0) }'; then
      [[ "${download_observed}" != 'not-run' ]] || return 1
      awk -v value="${download_observed}" -v minimum="${download_minimum_rate}" \
        'BEGIN { exit !(value >= minimum) }' || return 1
    fi
    if [[ "${upload_minimum_bytes}" != '0' ]]; then
      [[ "${upload_bytes}" != 'not-run' \
          && "${upload_summary}" == *"bytes ${upload_bytes} >= required ${upload_minimum_bytes}"* ]] \
        || return 1
      awk -v value="${upload_bytes}" -v minimum="${upload_minimum_bytes}" \
        'BEGIN { exit !(value >= minimum) }' || return 1
    fi
    if awk -v minimum="${upload_minimum_rate}" \
        'BEGIN { exit !(minimum > 0) }'; then
      [[ "${upload_observed}" != 'not-run' ]] || return 1
      awk -v value="${upload_observed}" -v minimum="${upload_minimum_rate}" \
        'BEGIN { exit !(value >= minimum) }' || return 1
    fi
  fi

  serial_tag_re='^- serial redaction tag: `<serial-redacted:[0-9a-f]{8}>`$'
  count="$(grep_count -Ec "${serial_tag_re}" "${log}")" || return 1
  [[ "${count}" == '1' ]] || return 1
}

legacy_manifest_validated=0
validate_legacy_manifest() {
  local actual_manifest_sha line digest path actual_digest count=0 seen=$'\n'
  [[ "${legacy_manifest_validated}" -eq 0 ]] || return 0
  [[ -f "${legacy_manifest}" && ! -L "${legacy_manifest}" ]] || return 1
  actual_manifest_sha="$(sha256_file "${legacy_manifest}")" || return 1
  [[ "${actual_manifest_sha}" == "${legacy_manifest_sha256}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^([0-9a-f]{64})\ \ (fixtures/m1-runs/[A-Za-z0-9][A-Za-z0-9._-]*[.]md)$ ]] \
      || return 1
    digest="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
    [[ "${path}" != 'fixtures/m1-runs/README.md' \
        && "${seen}" != *$'\n'"${path}"$'\n'* \
        && -f "${path}" \
        && ! -L "${path}" ]] || return 1
    actual_digest="$(sha256_file "${path}")" || return 1
    [[ "${actual_digest}" == "${digest}" ]] || return 1
    seen+="${path}"$'\n'
    count=$((count + 1))
  done <"${legacy_manifest}"
  [[ "${count}" -eq 89 ]] || return 1
  legacy_manifest_validated=1
}

validate_frozen_legacy_log() {
  local log="$1" relative expected_digest actual_digest count
  case "${log}" in
    "${repo_root}"/fixtures/m1-runs/*.md) relative="${log#${repo_root}/}" ;;
    fixtures/m1-runs/*.md) relative="${log}" ;;
    *) return 1 ;;
  esac
  validate_legacy_manifest || return 1
  count="$(awk -v path="${relative}" '$2 == path { count += 1 } END { print count + 0 }' \
    "${legacy_manifest}")" || return 1
  [[ "${count}" -eq 1 ]] || return 1
  expected_digest="$(awk -v path="${relative}" '$2 == path { print $1 }' \
    "${legacy_manifest}")" || return 1
  actual_digest="$(sha256_file "${log}")" || return 1
  [[ "${actual_digest}" == "${expected_digest}" ]]
}
