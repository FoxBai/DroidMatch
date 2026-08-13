#!/bin/bash -p

set +x
set -euo pipefail
builtin unset CDPATH
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
hash -r

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

directory="fixtures/product-usb-insertion"
single_log=""
directory_set=0
single_log_set=0
require_complete_matrix=0
device_identity_helper="${repo_root}/tools/product-usb-device-identity.py"

usage() {
  printf '%s\n' \
    'Usage: tools/check-product-usb-insertion-logs.sh [--directory <path> | --log <path>] [--require-complete-matrix]' \
    '' \
    'Validates fail-closed regular-file m1-product-usb-insertion-v2 evidence.' \
    '--require-complete-matrix requires directory mode with Slots A/C/D covered by one source revision.'
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
    --require-complete-matrix)
      require_complete_matrix=1
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf '%s\n' 'unknown product USB insertion log-check option.' >&2; exit 2 ;;
  esac
done
[[ $((directory_set + single_log_set)) -le 1 ]] \
  || { printf '%s\n' '--directory and --log are mutually exclusive.' >&2; exit 2; }
[[ "${require_complete_matrix}" -eq 0 || "${single_log_set}" -eq 0 ]] \
  || { printf '%s\n' '--require-complete-matrix is available only in directory mode.' >&2; exit 2; }
[[ -f "${device_identity_helper}" && ! -L "${device_identity_helper}" ]] \
  || { printf '%s\n' 'product USB selected-device registry helper is unavailable.' >&2; exit 1; }

grep_count() {
  local output status
  if output="$(grep "$@" 2>/dev/null)"; then
    printf '%s' "${output}"
    return 0
  else
    status=$?
  fi
  if [[ "${status}" -eq 1 ]]; then
    printf '%s' "${output}"
    return 0
  fi
  return 2
}

grep_match() {
  local status
  if grep "$@" >/dev/null 2>&1; then
    return 0
  else
    status=$?
  fi
  [[ "${status}" -eq 1 ]] && return 1
  return 2
}

field_value() {
  local log="$1" field="$2" count
  count="$(grep_count -c "^${field}:" "${log}")" || return 1
  [[ "${count}" == "1" ]] || {
    printf 'product USB insertion field must appear exactly once (%s): %s\n' \
      "${field}" "${log}" >&2
    return 1
  }
  sed -n "s/^${field}: //p" "${log}"
}

validate_log() {
  local log="$1" field value source_sha expected_sha origin_sha bundle_sha elapsed
  local bundle_cdhash known_field allowed_field line slot profile_output
  local expected_registry expected_tag expected_manufacturer expected_model
  local expected_api expected_label adb_profile_output expected_adb_registry
  local expected_adb_sha expected_adb_version expected_adb_build expected_adb_socket
  local required_fields=(
    'status'
    'evidence profile'
    'profile result'
    'date'
    'selected device registry'
    'device slot'
    'device identity tag'
    'device manufacturer'
    'device model'
    'device android api'
    'device label'
    'adb selected absent before arming'
    'adb inventory unchanged before signal'
    'adb insertion delta verified'
    'adb identity verified'
    'identity reverified before publication'
    'adb toolchain registry'
    'adb executable sha256'
    'adb version'
    'adb build'
    'adb server socket'
    'adb server stable'
    'bundle id'
    'profile source revision'
    'profile expected main revision'
    'profile origin main revision'
    'bundle source revision'
    'bundle source dirty'
    'bundle build configuration'
    'bundle sandboxed'
    'bundle executable sha256'
    'bundle code cdhash'
    'running code requirement verified'
    'running app count'
    'running bundle matched requested app'
    'bundle verification'
    'repository clean before run'
    'repository clean after run'
    'preflight matching elements'
    'pre-signal matching elements'
    'operator arm acknowledged'
    'operator physical insertion attested'
    'measurement clock'
    'measurement boundary'
    'countdown seconds'
    'poll interval ms'
    'threshold ms'
    'elapsed ms'
    'completion matching elements'
    'product visible'
    'accessibility identifier'
    'probe override'
  )

  [[ -f "${log}" && ! -L "${log}" && -s "${log}" ]] || return 1
  [[ "$(head -n 1 "${log}")" == '# M1 Product USB Insertion Evidence' ]] || return 1
  for field in "${required_fields[@]}"; do
    field_value "${log}" "${field}" >/dev/null || return 1
  done
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == '# M1 Product USB Insertion Evidence' ]] && continue
    [[ "${line}" == *:* ]] || return 1
    field="${line%%:*}"
    known_field=0
    for allowed_field in "${required_fields[@]}"; do
      if [[ "${field}" == "${allowed_field}" ]]; then
        known_field=1
        break
      fi
    done
    [[ "${known_field}" -eq 1 ]] || return 1
  done <"${log}"
  scan_status=0
  LC_ALL=C grep_match -q '[[:cntrl:]]' "${log}" || scan_status=$?
  [[ "${scan_status}" -eq 1 ]] || return 1
  scan_status=0
  grep_match -Eiq '/Users/|/home/[^/[:space:]]+/|content://|Authorization:|Bearer[[:space:]]+|access[_-]?token|refresh[_-]?token|password|secret|(^|[[:space:]])serial[=:]|(^|[^[:alnum:]_])(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,})' "${log}" \
    || scan_status=$?
  [[ "${scan_status}" -eq 1 ]] || return 1

  [[ "$(field_value "${log}" 'status')" == 'passed' ]] || return 1
  [[ "$(field_value "${log}" 'evidence profile')" == 'm1-product-usb-insertion-v2' ]] || return 1
  [[ "$(field_value "${log}" 'profile result')" == 'passed' ]] || return 1
  value="$(field_value "${log}" 'date')"
  [[ "${value}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || return 1
  slot="$(field_value "${log}" 'device slot')"
  [[ "${slot}" =~ ^(A|C|D)$ ]] || return 1
  profile_output="$(python3 "${device_identity_helper}" profile --slot "${slot}" 2>/dev/null)" \
    || return 1
  profile_value() {
    local profile_field="$1" profile_count
    profile_count="$(grep_count -c "^${profile_field}=" <<<"${profile_output}")" || return 1
    [[ "${profile_count}" == "1" ]] || return 1
    sed -n "s/^${profile_field}=//p" <<<"${profile_output}"
  }
  expected_registry="$(profile_value registry_profile)" || return 1
  expected_tag="$(profile_value identity_tag)" || return 1
  expected_manufacturer="$(profile_value manufacturer)" || return 1
  expected_model="$(profile_value model)" || return 1
  expected_api="$(profile_value android_api)" || return 1
  expected_label="$(profile_value visible_label)" || return 1
  [[ "$(field_value "${log}" 'selected device registry')" == "${expected_registry}" \
      && "$(field_value "${log}" 'device identity tag')" == "${expected_tag}" \
      && "$(field_value "${log}" 'device manufacturer')" == "${expected_manufacturer}" \
      && "$(field_value "${log}" 'device model')" == "${expected_model}" \
      && "$(field_value "${log}" 'device android api')" == "${expected_api}" \
      && "$(field_value "${log}" 'device label')" == "${expected_label}" ]] || return 1
  adb_profile_output="$(python3 "${device_identity_helper}" toolchain 2>/dev/null)" || return 1
  adb_profile_value() {
    local profile_field="$1" profile_count
    profile_count="$(grep_count -c "^${profile_field}=" <<<"${adb_profile_output}")" \
      || return 1
    [[ "${profile_count}" == "1" ]] || return 1
    sed -n "s/^${profile_field}=//p" <<<"${adb_profile_output}"
  }
  expected_adb_registry="$(adb_profile_value adb_registry_profile)" || return 1
  expected_adb_sha="$(adb_profile_value adb_executable_sha256)" || return 1
  expected_adb_version="$(adb_profile_value adb_version)" || return 1
  expected_adb_build="$(adb_profile_value adb_build)" || return 1
  expected_adb_socket="$(adb_profile_value adb_server_socket)" || return 1
  [[ "$(field_value "${log}" 'adb toolchain registry')" == "${expected_adb_registry}" \
      && "$(field_value "${log}" 'adb executable sha256')" == "${expected_adb_sha}" \
      && "$(field_value "${log}" 'adb version')" == "${expected_adb_version}" \
      && "$(field_value "${log}" 'adb build')" == "${expected_adb_build}" \
      && "$(field_value "${log}" 'adb server socket')" == "${expected_adb_socket}" ]] \
    || return 1
  [[ "$(field_value "${log}" 'bundle id')" == 'app.droidmatch.mac' ]] || return 1

  source_sha="$(field_value "${log}" 'profile source revision')"
  expected_sha="$(field_value "${log}" 'profile expected main revision')"
  origin_sha="$(field_value "${log}" 'profile origin main revision')"
  bundle_sha="$(field_value "${log}" 'bundle source revision')"
  [[ "${source_sha}" =~ ^[0-9a-f]{40}$ \
      && "${source_sha}" == "${expected_sha}" \
      && "${source_sha}" == "${origin_sha}" \
      && "${source_sha}" == "${bundle_sha}" ]] || return 1
  [[ "$(field_value "${log}" 'bundle build configuration')" == 'release' ]] || return 1
  [[ "$(field_value "${log}" 'bundle sandboxed')" == 'true' ]] || return 1
  value="$(field_value "${log}" 'bundle executable sha256')"
  [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || return 1
  bundle_cdhash="$(field_value "${log}" 'bundle code cdhash')"
  [[ "${bundle_cdhash}" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ "$(field_value "${log}" 'running app count')" == '1' ]] || return 1
  [[ "$(field_value "${log}" 'bundle verification')" == 'passed' ]] || return 1

  for field in \
    'repository clean before run' \
    'repository clean after run' \
    'running bundle matched requested app' \
    'running code requirement verified' \
    'operator arm acknowledged' \
    'operator physical insertion attested' \
    'adb selected absent before arming' \
    'adb inventory unchanged before signal' \
    'adb insertion delta verified' \
    'adb identity verified' \
    'identity reverified before publication' \
    'adb server stable' \
    'product visible'; do
    [[ "$(field_value "${log}" "${field}")" == 'true' ]] || return 1
  done
  [[ "$(field_value "${log}" 'bundle source dirty')" == 'false' ]] || return 1
  [[ "$(field_value "${log}" 'probe override')" == 'false' ]] || return 1
  [[ "$(field_value "${log}" 'preflight matching elements')" == '0' ]] || return 1
  [[ "$(field_value "${log}" 'pre-signal matching elements')" == '0' ]] || return 1
  [[ "$(field_value "${log}" 'completion matching elements')" == '1' ]] || return 1
  [[ "$(field_value "${log}" 'measurement clock')" == 'CLOCK_MONOTONIC' ]] || return 1
  [[ "$(field_value "${log}" 'measurement boundary')" == 'monotonic-before-insert-now' ]] \
    || return 1
  [[ "$(field_value "${log}" 'countdown seconds')" == '3' ]] || return 1
  [[ "$(field_value "${log}" 'poll interval ms')" == '100' ]] || return 1
  [[ "$(field_value "${log}" 'threshold ms')" == '5000' ]] || return 1
  elapsed="$(field_value "${log}" 'elapsed ms')"
  [[ "${elapsed}" =~ ^[1-9][0-9]*$ ]] || return 1
  awk -v value="${elapsed}" 'BEGIN { exit !(value <= 5000) }' || return 1
  [[ "$(field_value "${log}" 'accessibility identifier')" \
      == 'app.droidmatch.discovery-device-card' ]] || return 1
}

logs=()
check_status_count=0
enforce_repository_names=0
if [[ -n "${single_log}" ]]; then
  logs=("${single_log}")
else
  [[ -d "${directory}" && ! -L "${directory}" ]] || {
    printf 'product USB insertion fixture directory is missing: %s\n' "${directory}" >&2
    exit 1
  }
  unset GLOBIGNORE
  shopt -s nullglob dotglob
  logs=("${directory}"/*)
  check_status_count=1
  directory_physical="$(cd "${directory}" && pwd -P)"
  [[ "${directory_physical}" != "${repo_root}/fixtures/product-usb-insertion" ]] \
    || enforce_repository_names=1
fi

checked=0
slot_a_tag=""
slot_c_tag=""
slot_d_tag=""
matrix_revision_slots=""
if [[ "${#logs[@]}" -gt 0 ]]; then
  for log in "${logs[@]}"; do
    basename_log="$(basename "${log}")"
    if [[ -z "${single_log}" && "${basename_log}" == 'README.md' ]]; then
      [[ -f "${log}" && ! -L "${log}" && -s "${log}" ]] || {
        printf '%s\n' 'product USB insertion fixture directory contains an invalid README.' >&2
        exit 1
      }
      continue
    fi
    if [[ -z "${single_log}" ]]; then
      if [[ "${basename_log}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[.]md$ ]]; then
        :
      elif [[ "${basename_log}" == 'README.md.commit' ]]; then
        printf '%s\n' 'product USB insertion fixture directory contains an unsupported entry.' >&2
        exit 1
      elif [[ "${basename_log}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[.]md[.]commit$ ]]; then
        evidence_log="${log%.commit}"
        if [[ ! -f "${log}" || -L "${log}" || ! -s "${log}" \
            || ! -f "${evidence_log}" || -L "${evidence_log}" \
            || ! -s "${evidence_log}" ]] \
            || ! cmp -s "${evidence_log}" "${log}"; then
          printf '%s\n' 'product USB insertion commit companion is invalid or orphaned.' >&2
          exit 1
        fi
        continue
      else
        printf '%s\n' 'product USB insertion fixture directory contains an unsupported entry.' >&2
        exit 1
      fi
    fi
    if ! validate_log "${log}"; then
      printf 'invalid product USB insertion evidence: %s\n' "${log}" >&2
      exit 1
    fi
    validated_slot="$(field_value "${log}" 'device slot')"
    validated_tag="$(field_value "${log}" 'device identity tag')"
    validated_revision="$(field_value "${log}" 'profile source revision')"
    matrix_revision_slots="${matrix_revision_slots}${validated_revision} ${validated_slot}"$'\n'
    if [[ "${enforce_repository_names}" -eq 1 ]]; then
      validated_slot_lower="$(printf '%s' "${validated_slot}" | tr '[:upper:]' '[:lower:]')"
      repository_name_pattern="^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z-slot-${validated_slot_lower}-${validated_tag}[.]md$"
      [[ "${basename_log}" =~ ${repository_name_pattern} ]] || {
        printf '%s\n' 'product USB insertion evidence has an unsafe repository filename.' >&2
        exit 1
      }
    fi
    case "${validated_slot}" in
      A)
        [[ -z "${slot_a_tag}" || "${slot_a_tag}" == "${validated_tag}" ]] || exit 1
        slot_a_tag="${validated_tag}"
        ;;
      C)
        [[ -z "${slot_c_tag}" || "${slot_c_tag}" == "${validated_tag}" ]] || exit 1
        slot_c_tag="${validated_tag}"
        ;;
      D)
        [[ -z "${slot_d_tag}" || "${slot_d_tag}" == "${validated_tag}" ]] || exit 1
        slot_d_tag="${validated_tag}"
        ;;
    esac
    if [[ -z "${single_log}" ]]; then
      commit_log="${log}.commit"
      if [[ ! -f "${commit_log}" || -L "${commit_log}" || ! -s "${commit_log}" ]] \
          || ! cmp -s "${log}" "${commit_log}"; then
        printf '%s\n' 'product USB insertion evidence is missing its matching commit companion.' >&2
        exit 1
      fi
    fi
    checked=$((checked + 1))
  done
fi

for tag_pair in \
  "${slot_a_tag}:${slot_c_tag}" \
  "${slot_a_tag}:${slot_d_tag}" \
  "${slot_c_tag}:${slot_d_tag}"; do
  first_tag="${tag_pair%%:*}"
  second_tag="${tag_pair#*:}"
  [[ -z "${first_tag}" || -z "${second_tag}" || "${first_tag}" != "${second_tag}" ]] || {
    printf '%s\n' 'product USB insertion evidence reuses one device identity across required slots.' >&2
    exit 1
  }
done
covered_slots=""
[[ -z "${slot_a_tag}" ]] || covered_slots="A"
[[ -z "${slot_c_tag}" ]] || covered_slots="${covered_slots:+${covered_slots}/}C"
[[ -z "${slot_d_tag}" ]] || covered_slots="${covered_slots:+${covered_slots}/}D"
[[ -n "${covered_slots}" ]] || covered_slots="none"

if [[ "${require_complete_matrix}" -eq 1 && "${covered_slots}" != 'A/C/D' ]]; then
  missing_slots=""
  [[ -n "${slot_a_tag}" ]] || missing_slots="A"
  [[ -n "${slot_c_tag}" ]] || missing_slots="${missing_slots:+${missing_slots}/}C"
  [[ -n "${slot_d_tag}" ]] || missing_slots="${missing_slots:+${missing_slots}/}D"
  printf 'product USB insertion matrix is incomplete (covered slots: %s; missing slots: %s).\n' \
    "${covered_slots}" "${missing_slots}" >&2
  exit 1
fi
if [[ "${require_complete_matrix}" -eq 1 ]]; then
  complete_revision="$(printf '%s' "${matrix_revision_slots}" | awk '
    { slots[$1 " " $2] = 1; revisions[$1] = 1 }
    END { for (revision in revisions) {
      if (slots[revision " A"] && slots[revision " C"] && slots[revision " D"]) {
        print revision; exit
      }
    } }')"
  [[ "${complete_revision}" =~ ^[0-9a-f]{40}$ ]] || {
    printf '%s\n' 'product USB insertion matrix has no single source revision covering Slots A/C/D.' >&2
    exit 1
  }
fi

if [[ "${check_status_count}" -eq 1 \
    && "${directory}" == 'fixtures/product-usb-insertion' ]]; then
  status_count="$(sed -n 's/^- \([0-9][0-9]*\) product USB insertion evidence logs$/\1/p' docs/m1-status.md)"
  status_zh_count="$(sed -n 's/^- \([0-9][0-9]*\) 个产品 USB 插入证据日志$/\1/p' docs/m1-status-zh.md)"
  [[ "${status_count}" == "${checked}" && "${status_zh_count}" == "${checked}" ]] || {
    printf 'product USB insertion fixture count does not match live status docs.\n' >&2
    exit 1
  }
  status_slots="$(sed -n 's/^- Product USB insertion covered slots: //p' docs/m1-status.md)"
  status_zh_slots="$(sed -n 's/^- 产品 USB 插入已覆盖槽位：//p' docs/m1-status-zh.md)"
  [[ "${status_slots}" == "${covered_slots}" \
      && "${status_zh_slots}" == "${covered_slots}" ]] || {
    printf '%s\n' 'product USB insertion slot coverage does not match live status docs.' >&2
    exit 1
  }
fi

printf 'Product USB insertion evidence check passed (%s logs; slots %s).\n' \
  "${checked}" "${covered_slots}"
printf '中文：产品 USB 插入证据校验通过（%s 个日志；槽位 %s）。\n' \
  "${checked}" "${covered_slots}"
