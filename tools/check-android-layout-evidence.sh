#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

directory="fixtures/android-layout"
single_log=""
directory_set=0
single_log_set=0

usage() {
  printf '%s\n' \
    'Usage: tools/check-android-layout-evidence.sh [--directory <path> | --log <path>]' \
    '' \
    'Validates fail-closed regular-file m1-android-launcher-layout-v1 evidence.'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --directory) directory="${2:?missing value for --directory}"; directory_set=1; shift 2 ;;
    --log) single_log="${2:?missing value for --log}"; single_log_set=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '%s\n' 'unknown Android layout evidence option.' >&2; exit 2 ;;
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
  [[ "${status}" -eq 1 ]] || return 2
  printf '%s' "${output}"
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
    printf 'Android layout evidence field must appear exactly once (%s): %s\n' \
      "${field}" "${log}" >&2
    return 1
  }
  sed -n "s/^${field}: //p" "${log}"
}

validate_log() {
  local log="$1" field allowed_field known_field line value source_sha expected_sha origin_sha
  local required_fields=(
    'status'
    'evidence profile'
    'profile result'
    'date'
    'device slot'
    'device model'
    'android api'
    'instrumentation profile'
    'instrumentation class'
    'instrumentation tests expected'
    'instrumentation tests passed'
    'profile source revision'
    'profile expected main revision'
    'profile origin main revision'
    'profile source dirty'
    'build mode'
    'product apk sha256'
    'test apk sha256'
    'product package preexisting'
    'test package absent before run'
    'test apk install mode'
    'product apk replacement mode'
    'product data preservation'
    'test package cleanup verified'
    'product package remained installed'
    'repository clean before run'
    'repository clean after run'
    'physical display'
    'app viewport'
    'density dpi'
    'locale'
    'font scale'
    'layout assertion set'
    'raw instrumentation output included'
    'adb serial included'
  )

  [[ -f "${log}" && ! -L "${log}" && -s "${log}" ]] || return 1
  [[ "$(wc -c <"${log}")" -le 65536 ]] || return 1
  [[ "$(head -n 1 "${log}")" == '# M1 Android Launcher Layout Evidence' ]] \
    || return 1
  for field in "${required_fields[@]}"; do
    field_value "${log}" "${field}" >/dev/null || return 1
  done
  while IFS= read -r line; do
    [[ -z "${line}" || "${line}" == '# M1 Android Launcher Layout Evidence' ]] \
      && continue
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
  [[ "$(field_value "${log}" 'evidence profile')" \
      == 'm1-android-launcher-layout-v1' ]] || return 1
  [[ "$(field_value "${log}" 'profile result')" == 'passed' ]] || return 1
  value="$(field_value "${log}" 'date')"
  [[ "${value}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || return 1
  [[ "$(field_value "${log}" 'device slot')" == 'A' ]] || return 1
  [[ "$(field_value "${log}" 'device model')" == 'SHARP 704SH' ]] || return 1
  [[ "$(field_value "${log}" 'android api')" == '26' ]] || return 1
  [[ "$(field_value "${log}" 'instrumentation profile')" \
      == 'slot-a-704sh-layout-v2' ]] || return 1
  [[ "$(field_value "${log}" 'instrumentation class')" \
      == 'app.droidmatch.m1.DroidMatchActivityLayoutInstrumentationTest' ]] || return 1
  [[ "$(field_value "${log}" 'instrumentation tests expected')" == '1' ]] || return 1
  [[ "$(field_value "${log}" 'instrumentation tests passed')" == '1' ]] || return 1

  source_sha="$(field_value "${log}" 'profile source revision')"
  expected_sha="$(field_value "${log}" 'profile expected main revision')"
  origin_sha="$(field_value "${log}" 'profile origin main revision')"
  [[ "${source_sha}" =~ ^[0-9a-f]{40}$ \
      && "${source_sha}" == "${expected_sha}" \
      && "${source_sha}" == "${origin_sha}" ]] || return 1
  [[ "$(field_value "${log}" 'profile source dirty')" == 'false' ]] || return 1
  [[ "$(field_value "${log}" 'build mode')" == 'debug-clean-rebuild' ]] || return 1
  for field in 'product apk sha256' 'test apk sha256'; do
    value="$(field_value "${log}" "${field}")"
    [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || return 1
  done
  [[ "$(field_value "${log}" 'product apk sha256')" \
      != "$(field_value "${log}" 'test apk sha256')" ]] || return 1

  for field in \
    'product package preexisting' \
    'test package absent before run' \
    'test package cleanup verified' \
    'product package remained installed' \
    'repository clean before run' \
    'repository clean after run'; do
    [[ "$(field_value "${log}" "${field}")" == 'true' ]] || return 1
  done
  [[ "$(field_value "${log}" 'test apk install mode')" == 'create-only' ]] || return 1
  [[ "$(field_value "${log}" 'product apk replacement mode')" \
      == 'install-r-preserve-data' ]] || return 1
  [[ "$(field_value "${log}" 'product data preservation')" \
      == 'no-uninstall-no-clear' ]] || return 1
  [[ "$(field_value "${log}" 'physical display')" == '720x1280' ]] || return 1
  [[ "$(field_value "${log}" 'app viewport')" == '720x1136' ]] || return 1
  [[ "$(field_value "${log}" 'density dpi')" == '320' ]] || return 1
  [[ "$(field_value "${log}" 'locale')" == 'en-US' ]] || return 1
  [[ "$(field_value "${log}" 'font scale')" == '1.3' ]] || return 1
  [[ "$(field_value "${log}" 'layout assertion set')" \
      == 'initial-action,uniform-action-rows,media-detail-rows,text-fit,full-scroll,final-control' ]] \
    || return 1
  [[ "$(field_value "${log}" 'raw instrumentation output included')" == 'false' ]] \
    || return 1
  [[ "$(field_value "${log}" 'adb serial included')" == 'false' ]] || return 1
}

logs=()
check_status_count=0
if [[ -n "${single_log}" ]]; then
  logs=("${single_log}")
else
  [[ -d "${directory}" && ! -L "${directory}" ]] || {
    printf 'Android layout evidence directory is missing: %s\n' "${directory}" >&2
    exit 1
  }
  unset GLOBIGNORE
  shopt -s nullglob dotglob
  logs=("${directory}"/*)
  check_status_count=1
fi

checked=0
for log in "${logs[@]}"; do
  basename_log="$(basename "${log}")"
  if [[ -z "${single_log}" && "${basename_log}" == 'README.md' ]]; then
    [[ -f "${log}" && ! -L "${log}" && -s "${log}" ]] || exit 1
    continue
  fi
  if [[ -z "${single_log}" && "${basename_log}" == 'README.md.commit' ]]; then
    printf '%s\n' 'Android layout evidence directory contains an unsupported README companion.' >&2
    exit 1
  fi
  if [[ -z "${single_log}" && "${basename_log}" == *.md.commit ]]; then
    evidence_log="${log%.commit}"
    [[ -f "${log}" && ! -L "${log}" && -s "${log}" \
        && -f "${evidence_log}" && ! -L "${evidence_log}" && -s "${evidence_log}" ]] \
      && cmp -s "${evidence_log}" "${log}" || {
        printf '%s\n' 'Android layout evidence commit companion is invalid or orphaned.' >&2
        exit 1
      }
    continue
  fi
  if [[ -z "${single_log}" \
      && ! "${basename_log}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[.]md$ ]]; then
    printf '%s\n' 'Android layout evidence directory contains an unsupported entry.' >&2
    exit 1
  fi
  validate_log "${log}" || {
    printf 'invalid Android layout evidence: %s\n' "${log}" >&2
    exit 1
  }
  if [[ -z "${single_log}" ]]; then
    commit_log="${log}.commit"
    [[ -f "${commit_log}" && ! -L "${commit_log}" && -s "${commit_log}" ]] \
      && cmp -s "${log}" "${commit_log}" || {
        printf '%s\n' 'Android layout evidence is missing its matching commit companion.' >&2
        exit 1
      }
  fi
  checked=$((checked + 1))
done

if [[ "${check_status_count}" -eq 1 \
    && "${directory}" == 'fixtures/android-layout' ]]; then
  status_count="$(sed -n 's/^- \([0-9][0-9]*\) Android launcher layout evidence logs$/\1/p' docs/m1-status.md)"
  status_zh_count="$(sed -n 's/^- \([0-9][0-9]*\) 个 Android 启动器布局证据日志$/\1/p' docs/m1-status-zh.md)"
  [[ "${status_count}" == "${checked}" && "${status_zh_count}" == "${checked}" ]] \
    || { printf '%s\n' 'Android layout fixture count does not match live status docs.' >&2; exit 1; }
fi

printf 'Android layout evidence check passed (%s logs).\n' "${checked}"
printf '中文：Android 启动器布局证据校验通过（%s 个日志）。\n' "${checked}"
