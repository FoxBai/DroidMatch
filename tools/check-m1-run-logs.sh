#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

shopt -s nullglob
logs=(fixtures/m1-runs/*.md)

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

profile_value() {
  local log="$1" field="$2" count
  count="$(grep -c "^${field}:" "${log}" || true)"
  if [[ "${count}" -ne 1 ]]; then
    printf 'throughput evidence field must appear exactly once (%s): %s\n' \
      "${field}" "${log}" >&2
    return 1
  fi
  sed -n "s/^${field}: //p" "${log}"
}

validate_adb_throughput_profile() {
  local log="$1" source_sha expected_sha origin_sha build_sha api
  local list_elapsed list_max download_min download_observed upload_min upload_observed
  local field value

  for field in "${required_fields[@]}"; do
    [[ "$(grep -c "^${field}" "${log}" || true)" == "1" ]] || return 1
  done

  [[ "$(profile_value "${log}" 'profile result')" == "passed" ]] || return 1
  [[ "$(grep -c '^status:' "${log}" || true)" == "1" \
      && "$(grep -Fxc 'status: passed' "${log}" || true)" == "1" ]] || return 1
  [[ "$(grep -c '^device slot:' "${log}" || true)" == "1" \
      && "$(grep -Fxc 'device slot: A' "${log}" || true)" == "1" ]] || return 1
  [[ "$(grep -c '^build channel:' "${log}" || true)" == "1" ]] || return 1
  build_sha="$(sed -n 's/^build channel: local release Swift harness [+] debug APK from git \([0-9a-f][0-9a-f]*\)$/\1/p' "${log}")"
  [[ "${build_sha}" =~ ^[0-9a-f]{7,40}$ ]] || return 1
  ! grep -q -- '-dirty' "${log}" || return 1

  source_sha="$(profile_value "${log}" 'profile source revision')"
  expected_sha="$(profile_value "${log}" 'profile expected main revision')"
  origin_sha="$(profile_value "${log}" 'profile origin main revision')"
  [[ "${source_sha}" =~ ^[0-9a-f]{40}$ \
      && "${source_sha}" == "${expected_sha}" \
      && "${source_sha}" == "${origin_sha}" ]] || return 1
  [[ "${source_sha}" == "${build_sha}"* ]] || return 1

  [[ "$(grep -c '^android version/api:' "${log}" || true)" == "1" ]] || return 1
  api="$(sed -n 's/^android version\/api: .* API \([0-9][0-9]*\)$/\1/p' "${log}")"
  [[ "${api}" =~ ^(26|27|28|29)$ ]] || return 1
  [[ "$(grep -c '^handshake attempts:' "${log}" || true)" == "1" \
      && "$(grep -Fxc 'handshake attempts: 20/20 passed via `m1-smoke` (minimum 19)' "${log}" || true)" == "1" ]] \
    || return 1

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
  (( list_elapsed <= list_max )) || return 1

  for field in 'profile download elapsed ms' 'profile upload elapsed ms'; do
    value="$(profile_value "${log}" "${field}")"
    [[ "${value}" =~ ^[1-9][0-9]*$ ]] || return 1
    (( value <= 5000 )) || return 1
  done

  value="$(profile_value "${log}" 'profile adb baseline elapsed ms')"
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || return 1
  value="$(profile_value "${log}" 'profile adb baseline throughput mib per second')"
  [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1

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
}

checked=0
for log in "${logs[@]}"; do
  [[ "${log}" == "fixtures/m1-runs/README.md" ]] && continue
  checked=$((checked + 1))

  if [[ ! -s "${log}" ]]; then
    printf 'empty M1 run log: %s\n' "${log}" >&2
    exit 1
  fi
  if ! head -n 1 "${log}" | grep -q '^# '; then
    printf 'M1 run log must start with a markdown title: %s\n' "${log}" >&2
    exit 1
  fi
  for field in "${required_fields[@]}"; do
    if ! grep -q "^${field}" "${log}"; then
      printf 'M1 run log missing field "%s": %s\n' "${field}" "${log}" >&2
      exit 1
    fi
  done

  if grep -nE '/Users/|content://|Authorization:|authorization:|Bearer[[:space:]]+|access[_-]?token|refresh[_-]?token|password|secret' "${log}"; then
    printf 'M1 run log contains sensitive-looking content: %s\n' "${log}" >&2
    exit 1
  fi
  if grep -nE 'serial[=:][[:space:]]*[^<[:space:]][^[:space:]]{5,}' "${log}"; then
    printf 'M1 run log appears to contain an unredacted serial: %s\n' "${log}" >&2
    exit 1
  fi

  profile_count="$(grep -c '^evidence profile:' "${log}" || true)"
  if [[ "${profile_count}" -gt 1 ]]; then
    printf 'M1 run log contains multiple evidence profiles: %s\n' "${log}" >&2
    exit 1
  elif [[ "${profile_count}" -eq 1 ]]; then
    profile="$(sed -n 's/^evidence profile: //p' "${log}")"
    case "${profile}" in
      m1-adb-throughput-v1)
        if ! validate_adb_throughput_profile "${log}"; then
          printf 'invalid m1-adb-throughput-v1 evidence: %s\n' "${log}" >&2
          exit 1
        fi
        ;;
      *)
        printf 'unknown M1 evidence profile "%s": %s\n' "${profile}" "${log}" >&2
        exit 1
        ;;
    esac
  fi
done

status_count="$(sed -n 's/^- \([0-9][0-9]*\) test result logs$/\1/p' docs/m1-status.md 2>/dev/null || true)"
if [[ -n "${status_count}" && "${status_count}" -ne "${checked}" ]]; then
  printf 'docs/m1-status.md says %s M1 run logs, but fixtures/m1-runs contains %s.\n' \
    "${status_count}" "${checked}" >&2
  exit 1
fi

status_zh_count="$(sed -n 's/^- \([0-9][0-9]*\) 个测试结果日志$/\1/p' docs/m1-status-zh.md 2>/dev/null || true)"
if [[ -n "${status_zh_count}" && "${status_zh_count}" -ne "${checked}" ]]; then
  printf 'docs/m1-status-zh.md says %s M1 run logs, but fixtures/m1-runs contains %s.\n' \
    "${status_zh_count}" "${checked}" >&2
  exit 1
fi

printf 'M1 run log check passed (%d logs).\n' "${checked}"
