#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

directory="fixtures/m1-runs"
single_log=""
directory_set=0
single_log_set=0

usage() {
  printf '%s\n' \
    'Usage: tools/check-m1-run-logs.sh [--directory <path> | --log <path>]' \
    '' \
    'Validates legacy M1 logs and strict versioned evidence profiles.'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --directory)
      directory="${2:?missing value for --directory}"
      directory_set=1
      shift 2
      ;;
    --log)
      single_log="${2:?missing value for --log}"
      single_log_set=1
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf '%s\n' 'unknown M1 run log-check option.' >&2; exit 2 ;;
  esac
done
[[ $((directory_set + single_log_set)) -le 1 ]] || {
  printf '%s\n' '--directory and --log are mutually exclusive.' >&2
  exit 2
}

required_fields=(
  "date:"
  "device slot:"
  "manufacturer/model:"
  "android version/api:"
  "build channel:"
  "transport:"
  "handshake attempts:"
  "visible time:"
  "first list time:"
  "100MB download:"
  "100MB upload:"
  "resume result:"
  "permission cases:"
  "diagnostics bundle:"
  "notes:"
)

throughput_profile_fields=(
  'profile result'
  'profile source revision'
  'profile expected main revision'
  'profile origin main revision'
  'profile handshake attempts'
  'profile handshake passed'
  'profile handshake minimum'
  'profile warm list elapsed ms'
  'profile warm list maximum ms'
  'profile adb baseline bytes'
  'profile adb baseline elapsed ms'
  'profile adb baseline throughput mib per second'
  'profile download bytes'
  'profile download mode'
  'profile download chunks'
  'profile download requested chunk bytes'
  'profile download negotiated chunk bytes'
  'profile download minimum mib per second'
  'profile download observed mib per second'
  'profile download elapsed ms'
  'profile upload bytes'
  'profile upload mode'
  'profile upload chunks'
  'profile upload requested chunk bytes'
  'profile upload negotiated chunk bytes'
  'profile upload minimum mib per second'
  'profile upload observed mib per second'
  'profile upload elapsed ms'
  'profile cleanup remote prepared source'
  'profile cleanup remote upload final'
  'profile cleanup remote upload partial'
  'profile cleanup local transfer artifacts'
  'profile cleanup adb forward'
  'profile cleanup verified before pass'
)

throughput_profile_v2_fields=(
  'profile managed payload sha256'
  'profile download payload sha256'
  'profile upload payload sha256'
)
throughput_diagnostic_fields=(
  'diagnostic result'
  'diagnostic archive class'
  'diagnostic failure stage'
  'diagnostic source revision'
  'diagnostic expected main revision'
  'diagnostic origin main revision before run'
  'diagnostic post-run provenance'
  'diagnostic producer exit status'
  'diagnostic producer result'
  'diagnostic managed payload sha256'
  'diagnostic download payload sha256'
  'diagnostic upload payload sha256'
  'diagnostic cleanup remote artifacts'
  'diagnostic cleanup local artifacts'
  'diagnostic cleanup adb forward'
  'diagnostic cleanup result'
)
throughput_managed_payload_sha256='20492a4d0d84f8beb1767f6616229f85d44c2827b64bdbfb260ee12fa1109e0e'


source "${repo_root}/tools/m1-run-log-profile.sh"

validate_adb_throughput_profile() {
  local log="$1" profile_version="$2" source_sha expected_sha origin_sha build_sha api
  local list_elapsed list_max list_summary download_elapsed upload_elapsed
  local download_min download_observed upload_min upload_observed
  local baseline_elapsed baseline_observed
  local field value count allowed_field known_field line download_summary upload_summary
  local download_summary_suffix upload_summary_suffix
  local managed_payload_sha256 download_payload_sha256 upload_payload_sha256

  for field in "${required_fields[@]}"; do
    count="$(grep_count -c "^${field}" "${log}")" || return 1
    [[ "${count}" == "1" ]] || return 1
  done

  [[ "$(profile_value "${log}" 'profile result')" == "passed" ]] || return 1
  count="$(grep_count -Fxc 'status: passed' "${log}")" || return 1
  [[ "${count}" == "1" ]] || return 1
  count="$(grep_count -Fxc 'device slot: A' "${log}")" || return 1
  [[ "${count}" == "1" ]] || return 1
  count="$(grep_count -c '^build channel:' "${log}")" || return 1
  [[ "${count}" == "1" ]] || return 1
  build_sha="$(sed -n 's/^build channel: local release Swift harness [+] debug APK from git \([0-9a-f][0-9a-f]*\)$/\1/p' "${log}")"
  [[ "${build_sha}" =~ ^[0-9a-f]{7,40}$ ]] || return 1
  count="$(grep_count -c -- '-dirty' "${log}")" || return 1
  [[ "${count}" == "0" ]] || return 1

  source_sha="$(profile_value "${log}" 'profile source revision')"
  expected_sha="$(profile_value "${log}" 'profile expected main revision')"
  origin_sha="$(profile_value "${log}" 'profile origin main revision')"
  [[ "${source_sha}" =~ ^[0-9a-f]{40}$ \
      && "${source_sha}" == "${expected_sha}" \
      && "${source_sha}" == "${origin_sha}" ]] || return 1
  [[ "${source_sha}" == "${build_sha}"* ]] || return 1

  count="$(grep_count -c '^android version/api:' "${log}")" || return 1
  [[ "${count}" == "1" ]] || return 1
  api="$(sed -n 's/^android version\/api: .* API \([0-9][0-9]*\)$/\1/p' "${log}")"
  [[ "${api}" =~ ^(26|27|28|29)$ ]] || return 1
  count="$(grep_count -Fxc \
    'handshake attempts: 20/20 passed via `m1-smoke` (minimum 19)' "${log}")" \
    || return 1
  [[ "${count}" == "1" ]] || return 1

  [[ "$(profile_value "${log}" 'transport')" \
      == 'ADB forward to debug harness Activity endpoint' ]] || return 1
  [[ "$(profile_value "${log}" 'visible time')" \
      == 'device already authorized over USB before script start' ]] || return 1
  [[ "$(profile_value "${log}" 'resume result')" == 'not run' ]] || return 1
  [[ "$(profile_value "${log}" 'permission cases')" \
      == 'launcher entry resolved to `DroidMatchActivity`; detailed permission-denied cases not run' ]] \
    || return 1
  download_summary="$(profile_value "${log}" '100MB download')" || return 1
  upload_summary="$(profile_value "${log}" '100MB upload')" || return 1

  while IFS= read -r line; do
    # A passing profile must not carry the fail-only namespace, even if every
    # v2 field is otherwise valid.
    [[ "${line}" != diagnostic\ *:* ]] || return 1
    [[ "${line}" == profile\ *:* ]] || continue
    field="${line%%:*}"
    known_field=0
    for allowed_field in "${throughput_profile_fields[@]}"; do
      if [[ "${field}" == "${allowed_field}" ]]; then
        known_field=1
        break
      fi
    done
    if [[ "${known_field}" -eq 0 && "${profile_version}" == "v2" ]]; then
      for allowed_field in "${throughput_profile_v2_fields[@]}"; do
        if [[ "${field}" == "${allowed_field}" ]]; then
          known_field=1
          break
        fi
      done
    fi
    [[ "${known_field}" -eq 1 ]] || return 1
  done <"${log}" || return 1

  for field in \
    'profile handshake attempts' \
    'profile handshake passed' \
    'profile handshake minimum' \
    'profile adb baseline bytes' \
    'profile download bytes' \
    'profile download chunks' \
    'profile download requested chunk bytes' \
    'profile download negotiated chunk bytes' \
    'profile upload bytes' \
    'profile upload chunks' \
    'profile upload requested chunk bytes' \
    'profile upload negotiated chunk bytes'; do
    value="$(profile_value "${log}" "${field}")"
    case "${field}" in
      'profile handshake attempts'|'profile handshake passed') [[ "${value}" == "20" ]] || return 1 ;;
      'profile handshake minimum') [[ "${value}" == "19" ]] || return 1 ;;
      'profile download chunks'|'profile upload chunks') [[ "${value}" == "100" ]] || return 1 ;;
      *'chunk bytes') [[ "${value}" == "1048576" ]] || return 1 ;;
      *) [[ "${value}" == "104857600" ]] || return 1 ;;
    esac
  done

  [[ "$(profile_value "${log}" 'profile download mode')" == "fresh" ]] || return 1
  [[ "$(profile_value "${log}" 'profile upload mode')" == "fresh" ]] || return 1
  list_elapsed="$(profile_value "${log}" 'profile warm list elapsed ms')"
  list_max="$(profile_value "${log}" 'profile warm list maximum ms')"
  [[ "${list_elapsed}" =~ ^[0-9]+$ && "${list_max}" == "1000" ]] || return 1
  awk -v value="${list_elapsed}" -v maximum="${list_max}" \
    'BEGIN { exit !(value <= maximum) }' || return 1
  list_summary="$(profile_value "${log}" 'first list time')" || return 1
  [[ "${list_summary}" \
      == "${list_elapsed} ms for \`dm://media-images/\` (max ${list_max} ms)" ]] \
    || return 1

  for field in 'profile download elapsed ms' 'profile upload elapsed ms'; do
    value="$(profile_value "${log}" "${field}")"
    [[ "${value}" =~ ^[1-9][0-9]*$ ]] || return 1
    awk -v value="${value}" 'BEGIN { exit !(value <= 5000) }' || return 1
  done

  baseline_elapsed="$(profile_value "${log}" 'profile adb baseline elapsed ms')"
  [[ "${baseline_elapsed}" =~ ^[1-9][0-9]*$ ]] || return 1
  baseline_observed="$(profile_value "${log}" 'profile adb baseline throughput mib per second')"
  [[ "${baseline_observed}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1

  download_min="$(profile_value "${log}" 'profile download minimum mib per second')"
  download_observed="$(profile_value "${log}" 'profile download observed mib per second')"
  upload_min="$(profile_value "${log}" 'profile upload minimum mib per second')"
  upload_observed="$(profile_value "${log}" 'profile upload observed mib per second')"
  [[ "${download_min}" == "20" && "${upload_min}" == "20" \
      && "${download_observed}" =~ ^[0-9]+([.][0-9]+)?$ \
      && "${upload_observed}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  awk -v value="${download_observed}" -v minimum="${download_min}" \
    'BEGIN { exit !(value >= minimum) }' || return 1
  awk -v value="${upload_observed}" -v minimum="${upload_min}" \
    'BEGIN { exit !(value >= minimum) }' || return 1

  download_elapsed="$(profile_value "${log}" 'profile download elapsed ms')"
  upload_elapsed="$(profile_value "${log}" 'profile upload elapsed ms')"
  for value in \
    "${baseline_observed}:${baseline_elapsed}" \
    "${download_observed}:${download_elapsed}" \
    "${upload_observed}:${upload_elapsed}"; do
    awk -F: -v pair="${value}" 'BEGIN {
      split(pair, fields, ":")
      expected = 100 / (fields[2] / 1000)
      delta = fields[1] - expected
      if (delta < 0) delta = -delta
      exit !(delta <= 0.011)
    }' || return 1
  done
  download_summary_suffix="; bytes 104857600 >= required 104857600; throughput ${download_observed} MiB/s over ${download_elapsed} ms (required >= ${download_min} MiB/s)"
  upload_summary_suffix="; bytes 104857600 >= required 104857600; throughput ${upload_observed} MiB/s over ${upload_elapsed} ms (required >= ${upload_min} MiB/s)"
  [[ "${download_summary}" == '`download` command passed for `dm://app-sandbox/'*"${download_summary_suffix}" ]] \
    || return 1
  [[ "${upload_summary}" == '`upload` command passed to `dm://app-sandbox/'*"${upload_summary_suffix}" ]] \
    || return 1

  for field in \
    'profile cleanup remote prepared source' \
    'profile cleanup remote upload final' \
    'profile cleanup remote upload partial' \
    'profile cleanup local transfer artifacts' \
    'profile cleanup adb forward'; do
    [[ "$(profile_value "${log}" "${field}")" == "absent" ]] || return 1
  done
  [[ "$(profile_value "${log}" 'profile cleanup verified before pass')" == "true" ]] \
    || return 1

  if [[ "${profile_version}" == "v2" ]]; then
    managed_payload_sha256="$(profile_value "${log}" 'profile managed payload sha256')"
    download_payload_sha256="$(profile_value "${log}" 'profile download payload sha256')"
    upload_payload_sha256="$(profile_value "${log}" 'profile upload payload sha256')"
    [[ "${managed_payload_sha256}" == "${throughput_managed_payload_sha256}" \
        && "${managed_payload_sha256}" == "${download_payload_sha256}" \
        && "${managed_payload_sha256}" == "${upload_payload_sha256}" ]] \
      || return 1
  fi
}

validate_adb_throughput_producer_binding() {
  local log="$1" field pair producer_field throughput_field
  [[ "$(device_profile_value "${log}" 'device profile result')" == 'passed' \
      && "$(device_profile_value "${log}" 'device profile archive class')" == 'device-evidence' \
      && "$(device_profile_value "${log}" 'device profile source state')" == 'clean' \
      && "$(device_profile_value "${log}" 'device profile build mode')" == 'rebuilt' \
      && "$(device_profile_value "${log}" 'device profile device slot')" == 'A' \
      && "$(device_profile_value "${log}" 'device profile checks requested')" \
        == 'm1-smoke,adb-baseline,list-dir,download,upload' \
      && "$(device_profile_value "${log}" 'device profile checks passed')" \
        == 'm1-smoke,adb-baseline,list-dir,download,upload' \
      && "$(device_profile_value "${log}" 'device profile checks incomplete')" == 'none' \
      && "$(device_profile_value "${log}" 'device profile download bytes')" == '104857600' \
      && "$(device_profile_value "${log}" 'device profile download measured bytes')" == '104857600' \
      && "$(device_profile_value "${log}" 'device profile download minimum bytes')" == '104857600' \
      && "$(device_profile_value "${log}" 'device profile upload bytes')" == '104857600' \
      && "$(device_profile_value "${log}" 'device profile upload measured bytes')" == '104857600' \
      && "$(device_profile_value "${log}" 'device profile upload minimum bytes')" == '104857600' ]] \
    || return 1
  [[ "$(device_profile_value "${log}" 'device profile source revision')" \
      == "$(profile_value "${log}" 'profile source revision')" ]] || return 1
  for pair in \
    'device profile handshake attempts:profile handshake attempts' \
    'device profile handshake passed:profile handshake passed' \
    'device profile handshake minimum:profile handshake minimum' \
    'device profile list elapsed ms:profile warm list elapsed ms' \
    'device profile list maximum ms:profile warm list maximum ms' \
    'device profile download elapsed ms:profile download elapsed ms' \
    'device profile download observed mib per second:profile download observed mib per second' \
    'device profile download minimum mib per second:profile download minimum mib per second' \
    'device profile upload elapsed ms:profile upload elapsed ms' \
    'device profile upload observed mib per second:profile upload observed mib per second' \
    'device profile upload minimum mib per second:profile upload minimum mib per second'; do
    producer_field="${pair%%:*}"
    throughput_field="${pair#*:}"
    [[ "$(device_profile_value "${log}" "${producer_field}")" \
        == "$(profile_value "${log}" "${throughput_field}")" ]] || return 1
  done
}

validate_adb_throughput_diagnostic_profile() {
  local log="$1" line field allowed_field known_field
  local result archive_class failure_stage source_sha expected_sha origin_sha
  local post_run_provenance producer_exit_status producer_result managed_sha
  local download_sha upload_sha cleanup_remote cleanup_local cleanup_forward cleanup_result
  local producer_api producer_archive producer_requested producer_passed producer_incomplete
  local all_cleanup_absent=0
  local fixed_plan='m1-smoke,adb-baseline,list-dir,download,upload'
  local digest_re='^[0-9a-f]{64}$'

  while IFS= read -r line; do
    if [[ "${line}" == diagnostic\ *:* ]]; then
      field="${line%%:*}"
      known_field=0
      for allowed_field in "${throughput_diagnostic_fields[@]}"; do
        if [[ "${field}" == "${allowed_field}" ]]; then
          known_field=1
          break
        fi
      done
      [[ "${known_field}" -eq 1 ]] || return 1
    elif [[ "${line}" == profile\ *:* ]]; then
      # A diagnostic is a distinct fail-only profile, never a relaxed v2 block.
      return 1
    fi
  done <"${log}" || return 1

  result="$(profile_value "${log}" 'diagnostic result')" || return 1
  archive_class="$(profile_value "${log}" 'diagnostic archive class')" || return 1
  failure_stage="$(profile_value "${log}" 'diagnostic failure stage')" || return 1
  source_sha="$(profile_value "${log}" 'diagnostic source revision')" || return 1
  expected_sha="$(profile_value "${log}" 'diagnostic expected main revision')" || return 1
  origin_sha="$(profile_value "${log}" 'diagnostic origin main revision before run')" \
    || return 1
  post_run_provenance="$(profile_value "${log}" 'diagnostic post-run provenance')" \
    || return 1
  producer_exit_status="$(profile_value "${log}" 'diagnostic producer exit status')" \
    || return 1
  producer_result="$(profile_value "${log}" 'diagnostic producer result')" || return 1
  managed_sha="$(profile_value "${log}" 'diagnostic managed payload sha256')" || return 1
  download_sha="$(profile_value "${log}" 'diagnostic download payload sha256')" || return 1
  upload_sha="$(profile_value "${log}" 'diagnostic upload payload sha256')" || return 1
  cleanup_remote="$(profile_value "${log}" 'diagnostic cleanup remote artifacts')" \
    || return 1
  cleanup_local="$(profile_value "${log}" 'diagnostic cleanup local artifacts')" \
    || return 1
  cleanup_forward="$(profile_value "${log}" 'diagnostic cleanup adb forward')" \
    || return 1
  cleanup_result="$(profile_value "${log}" 'diagnostic cleanup result')" || return 1

  [[ "${result}" == 'failed' && "${archive_class}" == 'failed-diagnostic' ]] || return 1
  case "${failure_stage}" in
    producer-exit|wrapper-contract|download-content-integrity|upload-content-integrity|cleanup|post-run-provenance|pass-log|unexpected-shell-exit|interrupted) ;;
    *) return 1 ;;
  esac
  [[ "${source_sha}" =~ ^[0-9a-f]{40}$ \
      && "${source_sha}" == "${expected_sha}" \
      && "${source_sha}" == "${origin_sha}" ]] || return 1
  [[ "${post_run_provenance}" =~ ^(matched|changed|unavailable)$ ]] || return 1
  [[ "${producer_exit_status}" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
  awk -v value="${producer_exit_status}" 'BEGIN { exit !(value <= 255) }' || return 1
  [[ "${producer_result}" =~ ^(passed|failed)$ ]] || return 1
  [[ "${managed_sha}" == "${throughput_managed_payload_sha256}" ]] || return 1
  [[ "${download_sha}" == 'not-recorded' || "${download_sha}" =~ ${digest_re} ]] \
    || return 1
  [[ "${upload_sha}" == 'not-recorded' || "${upload_sha}" =~ ${digest_re} ]] \
    || return 1
  [[ "${cleanup_remote}" =~ ^(absent|present|unknown|not-owned)$ \
      && "${cleanup_local}" =~ ^(absent|present|unknown)$ \
      && "${cleanup_forward}" =~ ^(absent|present|unknown|not-recorded)$ \
      && "${cleanup_result}" =~ ^(complete|incomplete)$ ]] || return 1

  if [[ "${cleanup_remote}" == 'absent' \
      && "${cleanup_local}" == 'absent' \
      && "${cleanup_forward}" == 'absent' ]]; then
    all_cleanup_absent=1
  fi
  if [[ "${cleanup_result}" == 'complete' ]]; then
    [[ "${all_cleanup_absent}" -eq 1 ]] || return 1
  else
    [[ "${all_cleanup_absent}" -eq 0 ]] || return 1
  fi
  producer_api="$(device_profile_value "${log}" 'device profile android api')" || return 1
  producer_archive="$(device_profile_value "${log}" 'device profile archive class')" \
    || return 1
  producer_requested="$(device_profile_value "${log}" 'device profile checks requested')" \
    || return 1
  producer_passed="$(device_profile_value "${log}" 'device profile checks passed')" \
    || return 1
  producer_incomplete="$(device_profile_value "${log}" 'device profile checks incomplete')" \
    || return 1
  [[ "$(device_profile_value "${log}" 'device profile source revision')" == "${source_sha}" \
      && "$(device_profile_value "${log}" 'device profile source state')" == 'clean' \
      && "$(device_profile_value "${log}" 'device profile build mode')" == 'rebuilt' \
      && "$(device_profile_value "${log}" 'device profile harness configuration')" == 'release' \
      && "$(device_profile_value "${log}" 'device profile device slot')" == 'A' \
      && "${producer_api}" =~ ^(26|27|28|29)$ \
      && "${producer_requested}" == "${fixed_plan}" \
      && "$(device_profile_value "${log}" 'device profile download minimum bytes')" == '104857600' \
      && "$(device_profile_value "${log}" 'device profile download minimum mib per second')" == '20' \
      && "$(device_profile_value "${log}" 'device profile upload minimum bytes')" == '104857600' \
      && "$(device_profile_value "${log}" 'device profile upload minimum mib per second')" == '20' \
      && "$(device_profile_value "${log}" 'device profile result')" == "${producer_result}" ]] \
    || return 1

  if [[ "${producer_result}" == 'passed' ]]; then
    [[ "${producer_exit_status}" == '0' \
        && "${producer_archive}" == 'device-evidence' \
        && "${producer_passed}" == "${fixed_plan}" \
        && "${producer_incomplete}" == 'none' \
        && "${failure_stage}" != 'producer-exit' ]] || return 1
  else
    [[ "${producer_exit_status}" != '0' \
        && "${producer_archive}" == 'failed-diagnostic' \
        && "${producer_passed}" == 'none' \
        && "${producer_incomplete}" == "${fixed_plan}" \
        && "${failure_stage}" == 'producer-exit' ]] || return 1
  fi

  case "${failure_stage}" in
    producer-exit)
      [[ "${download_sha}" == 'not-recorded' && "${upload_sha}" == 'not-recorded' ]] \
        || return 1
      ;;
    download-content-integrity)
      [[ "${download_sha}" =~ ${digest_re} && "${download_sha}" != "${managed_sha}" ]] \
        || return 1
      ;;
    upload-content-integrity)
      [[ "${download_sha}" == "${managed_sha}" \
          && "${upload_sha}" =~ ${digest_re} \
          && "${upload_sha}" != "${managed_sha}" ]] || return 1
      ;;
    pass-log)
      [[ "${download_sha}" == "${managed_sha}" \
          && "${upload_sha}" == "${managed_sha}" \
          && "${cleanup_result}" == 'complete' ]] || return 1
      ;;
  esac
}

logs=()
check_status_count=0
if [[ -n "${single_log}" ]]; then
  logs=("${single_log}")
else
  [[ -d "${directory}" && ! -L "${directory}" ]] || {
    printf 'M1 run log directory is missing: %s\n' "${directory}" >&2
    exit 1
  }
  shopt -s nullglob dotglob
  for entry in "${directory}"/*; do
    case "$(basename "${entry}")" in
      README.md)
        [[ -f "${entry}" && ! -L "${entry}" ]] || {
          printf 'M1 run-log README must be a regular non-symlink file.\n' >&2
          exit 1
        }
        ;;
      legacy-v0.sha256)
        [[ -f "${entry}" && ! -L "${entry}" ]] || {
          printf 'M1 legacy manifest must be a regular non-symlink file.\n' >&2
          exit 1
        }
        ;;
      *.md) logs+=("${entry}") ;;
      *)
        printf 'unexpected file or nested path in the M1 run-log directory: %s\n' \
          "${entry}" >&2
        exit 1
        ;;
    esac
  done
  shopt -u dotglob
  [[ "${directory}" == "fixtures/m1-runs" ]] && check_status_count=1
fi

checked=0
if [[ "${check_status_count}" -eq 1 ]]; then
  if ! validate_legacy_manifest; then
    printf 'frozen M1 legacy manifest or fixture bytes are invalid.\n' >&2
    exit 1
  fi
fi
for log in "${logs[@]}"; do
  [[ -z "${single_log}" && "$(basename "${log}")" == "README.md" ]] && continue
  checked=$((checked + 1))

  if [[ ! -f "${log}" || -L "${log}" || ! -s "${log}" ]]; then
    printf 'M1 run log must be a non-empty regular non-symlink file: %s\n' "${log}" >&2
    exit 1
  fi
  first_line="$(head -n 1 "${log}" 2>/dev/null)" || {
    printf 'M1 run log could not be read: %s\n' "${log}" >&2
    exit 1
  }
  if [[ "${first_line}" != '# '* ]]; then
    printf 'M1 run log must start with a markdown title: %s\n' "${log}" >&2
    exit 1
  fi
  for field in "${required_fields[@]}"; do
    count="$(grep_count -c "^${field}" "${log}")" || {
      printf 'M1 run log could not be scanned: %s\n' "${log}" >&2
      exit 1
    }
    if [[ "${count}" == "0" ]]; then
      printf 'M1 run log missing field "%s": %s\n' "${field}" "${log}" >&2
      exit 1
    fi
  done

  scan_status=0
  LC_ALL=C grep_match -q '[[:cntrl:]]' "${log}" || scan_status=$?
  case "${scan_status}" in
    0) printf 'M1 run log contains a control character: %s\n' "${log}" >&2; exit 1 ;;
    1) ;;
    *) printf 'M1 run log could not be privacy-scanned: %s\n' "${log}" >&2; exit 1 ;;
  esac
  scan_status=0
  grep_match -Eiq '/Users/|/home/[^/[:space:]]+/|content://|Authorization:|Bearer[[:space:]]+|access[_-]?token|refresh[_-]?token|password|secret|(^|[^[:alnum:]_])(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,})' "${log}" \
    || scan_status=$?
  case "${scan_status}" in
    0) printf 'M1 run log contains sensitive-looking content: %s\n' "${log}" >&2; exit 1 ;;
    1) ;;
    *) printf 'M1 run log could not be privacy-scanned: %s\n' "${log}" >&2; exit 1 ;;
  esac
  scan_status=0
  grep_match -Eiq 'serial[=:][[:space:]]*[^<[:space:]][^[:space:]]{5,}|adb[[:space:]]+-s[[:space:]]+[^<[:space:]][^[:space:]]{5,}|ro[.]serialno[=:][[:space:]]*[^<[:space:]][^[:space:]]{5,}|device[[:space:]_-]*id[=:][[:space:]]*[^<[:space:]][^[:space:]]{5,}|^[A-Za-z0-9._:-]{6,}[[:space:]]+(device|unauthorized|offline)([[:space:]]|$)' "${log}" \
    || scan_status=$?
  case "${scan_status}" in
    0) printf 'M1 run log appears to contain an unredacted serial: %s\n' "${log}" >&2; exit 1 ;;
    1) ;;
    *) printf 'M1 run log could not be privacy-scanned: %s\n' "${log}" >&2; exit 1 ;;
  esac

  producer_profile_count="$(grep_count -c '^evidence producer profile:' "${log}")" || {
    printf 'M1 run log could not be scanned: %s\n' "${log}" >&2
    exit 1
  }
  if [[ "${producer_profile_count}" -gt 1 ]]; then
    printf 'M1 run log contains multiple evidence producer profiles: %s\n' "${log}" >&2
    exit 1
  elif [[ "${producer_profile_count}" -eq 1 ]]; then
    producer_profile="$(sed -n 's/^evidence producer profile: //p' "${log}")"
    if [[ "${producer_profile}" != 'm1-device-smoke-v1' ]]; then
      printf 'unknown M1 evidence producer profile "%s": %s\n' \
        "${producer_profile}" "${log}" >&2
      exit 1
    fi
  fi

  profile_count="$(grep_count -c '^evidence profile:' "${log}")" || {
    printf 'M1 run log could not be scanned: %s\n' "${log}" >&2
    exit 1
  }
  if [[ "${profile_count}" -gt 1 ]]; then
    printf 'M1 run log contains multiple evidence profiles: %s\n' "${log}" >&2
    exit 1
  elif [[ "${profile_count}" -eq 1 ]]; then
    profile="$(sed -n 's/^evidence profile: //p' "${log}")"
    case "${profile}" in
      m1-device-smoke-v1)
        if [[ "${producer_profile_count}" -ne 0 ]] \
            || ! validate_device_smoke_profile "${log}"; then
          printf 'invalid m1-device-smoke-v1 evidence: %s\n' "${log}" >&2
          exit 1
        fi
        ;;
      m1-adb-throughput-v2)
        if [[ "${producer_profile_count}" -ne 1 ]] \
            || ! validate_device_smoke_profile "${log}" \
            || ! validate_adb_throughput_profile "${log}" v2 \
            || ! validate_adb_throughput_producer_binding "${log}"; then
          printf 'invalid m1-adb-throughput-v2 evidence: %s\n' "${log}" >&2
          exit 1
        fi
        ;;
      m1-adb-throughput-diagnostic-v1)
        if [[ "${producer_profile_count}" -ne 1 ]] \
            || ! validate_device_smoke_profile "${log}" \
            || ! validate_adb_throughput_diagnostic_profile "${log}"; then
          printf 'invalid m1-adb-throughput-diagnostic-v1 evidence: %s\n' "${log}" >&2
          exit 1
        fi
        ;;
      *)
        printf 'unknown M1 evidence profile "%s": %s\n' "${profile}" "${log}" >&2
        exit 1
        ;;
    esac
  else
    if [[ "${producer_profile_count}" -ne 0 ]] \
        || ! validate_frozen_legacy_log "${log}"; then
      printf 'unprofiled M1 run log is not an exact frozen legacy fixture: %s\n' \
        "${log}" >&2
      exit 1
    fi
  fi
done

if [[ "${check_status_count}" -eq 1 ]]; then
  if [[ -e docs/m1-status.md || -e docs/m1-status-zh.md ]]; then
    [[ -f docs/m1-status.md && -f docs/m1-status-zh.md ]] || {
      printf 'both English and Chinese M1 status documents are required.\n' >&2
      exit 1
    }
    status_count="$(sed -n 's/^- \([0-9][0-9]*\) test result logs$/\1/p' docs/m1-status.md 2>/dev/null || true)"
    status_zh_count="$(sed -n 's/^- \([0-9][0-9]*\) 个测试结果日志$/\1/p' docs/m1-status-zh.md 2>/dev/null || true)"
    [[ "${status_count}" =~ ^[0-9]+$ && "${status_zh_count}" =~ ^[0-9]+$ ]] || {
      printf 'M1 status documents must declare their fixture-log count.\n' >&2
      exit 1
    }
  fi
  if [[ -n "${status_count:-}" && "${status_count}" != "${checked}" ]]; then
    printf 'docs/m1-status.md says %s M1 run logs, but fixtures/m1-runs contains %s.\n' \
      "${status_count}" "${checked}" >&2
    exit 1
  fi

  if [[ -n "${status_zh_count:-}" && "${status_zh_count}" != "${checked}" ]]; then
    printf 'docs/m1-status-zh.md says %s M1 run logs, but fixtures/m1-runs contains %s.\n' \
      "${status_zh_count}" "${checked}" >&2
    exit 1
  fi
fi

printf 'M1 run log check passed (%d logs).\n' "${checked}"
