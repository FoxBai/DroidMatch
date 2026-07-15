#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

directory="fixtures/product-usb-insertion"
single_log=""
directory_set=0
single_log_set=0

usage() {
  printf '%s\n' \
    'Usage: tools/check-product-usb-insertion-logs.sh [--directory <path> | --log <path>]' \
    '' \
    'Validates fail-closed regular-file m1-product-usb-insertion-v1 evidence.'
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
    *) printf '%s\n' 'unknown product USB insertion log-check option.' >&2; exit 2 ;;
  esac
done
[[ $((directory_set + single_log_set)) -le 1 ]] \
  || { printf '%s\n' '--directory and --log are mutually exclusive.' >&2; exit 2; }

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
  local bundle_cdhash known_field allowed_field line
  local required_fields=(
    'status'
    'evidence profile'
    'profile result'
    'date'
    'device slot'
    'device label'
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
  while IFS= read -r line; do
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
  [[ "$(field_value "${log}" 'evidence profile')" == 'm1-product-usb-insertion-v1' ]] || return 1
  [[ "$(field_value "${log}" 'profile result')" == 'passed' ]] || return 1
  value="$(field_value "${log}" 'date')"
  [[ "${value}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || return 1
  value="$(field_value "${log}" 'device slot')"
  [[ "${value}" =~ ^(A|C|D)$ ]] || return 1
  value="$(field_value "${log}" 'device label')"
  [[ -n "${value}" && "${#value}" -le 80 \
      && "${value}" != *'/'* && "${value}" != *'\\'* \
      && "${value}" != *$'\n'* ]] || return 1
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
  value="$(field_value "${log}" 'bundle sandboxed')"
  [[ "${value}" == 'true' || "${value}" == 'false' ]] || return 1
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
fi

checked=0
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

if [[ "${check_status_count}" -eq 1 \
    && "${directory}" == 'fixtures/product-usb-insertion' ]]; then
  status_count="$(sed -n 's/^- \([0-9][0-9]*\) product USB insertion evidence logs$/\1/p' docs/m1-status.md)"
  status_zh_count="$(sed -n 's/^- \([0-9][0-9]*\) 个产品 USB 插入证据日志$/\1/p' docs/m1-status-zh.md)"
  [[ "${status_count}" == "${checked}" && "${status_zh_count}" == "${checked}" ]] || {
    printf 'product USB insertion fixture count does not match live status docs.\n' >&2
    exit 1
  }
fi

printf 'Product USB insertion evidence check passed (%s logs).\n' "${checked}"
printf '中文：产品 USB 插入证据校验通过（%s 个日志）。\n' "${checked}"
