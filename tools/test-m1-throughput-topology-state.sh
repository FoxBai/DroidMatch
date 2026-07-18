#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tools/m1-throughput-topology-state.sh
source "${repo_root}/tools/m1-throughput-topology-state.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-topology-state-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

guard="${work}/guard"
status_file="${work}/status"
printf '%s\n' unverified >"${guard}"
printf '%s\n' 37 >"${status_file}"
[[ "$(droidmatch_finish_direct_usb_monitor 0 "${guard}" "${status_file}")" == 37 ]]
[[ ! -e "${guard}" && ! -e "${status_file}" ]]

for invalid in empty negative overflow text spaced multiline missing-newline; do
  printf '%s\n' unverified >"${guard}"
  case "${invalid}" in
    empty) : >"${status_file}" ;;
    negative) printf '%s\n' -1 >"${status_file}" ;;
    overflow) printf '%s\n' 256 >"${status_file}" ;;
    text) printf '%s\n' private >"${status_file}" ;;
    spaced) printf '%s\n' '3 7' >"${status_file}" ;;
    multiline) printf '3\n7\n' >"${status_file}" ;;
    missing-newline) printf 37 >"${status_file}" ;;
  esac
  ! droidmatch_finish_direct_usb_monitor 0 "${guard}" "${status_file}" >/dev/null
  [[ -f "${guard}" && -f "${status_file}" ]]
  rm -f "${guard}" "${status_file}"
done

printf '%s\n' unverified >"${guard}"
printf '%s\n' 0 >"${status_file}"
! droidmatch_finish_direct_usb_monitor 86 "${guard}" "${status_file}" >/dev/null
[[ -f "${guard}" && -f "${status_file}" ]]
rm -f "${guard}" "${status_file}"

printf '%s\n' unverified >"${work}/real-guard"
ln -s "${work}/real-guard" "${guard}"
printf '%s\n' 0 >"${status_file}"
! droidmatch_finish_direct_usb_monitor 0 "${guard}" "${status_file}" >/dev/null
[[ -L "${guard}" && -f "${status_file}" ]]

printf '%s\n' 'M1 throughput topology state tests passed.'
printf '%s\n' '中文：M1 吞吐拓扑状态测试通过。'
