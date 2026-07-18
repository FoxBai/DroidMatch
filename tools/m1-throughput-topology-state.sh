#!/usr/bin/env bash

# Finalize the private supervisor state only after its process has exited.
droidmatch_finish_direct_usb_monitor() {
  local monitor_status="$1" guard="$2" status_file="$3" child_status
  local status_bytes status_lines
  [[ "${monitor_status}" == 0 ]] || return 1
  [[ -f "${guard}" && ! -L "${guard}" ]] || return 1
  [[ -f "${status_file}" && ! -L "${status_file}" ]] || return 1
  status_bytes="$(wc -c <"${status_file}" | tr -d '[:space:]')" || return 1
  status_lines="$(wc -l <"${status_file}" | tr -d '[:space:]')" || return 1
  IFS= read -r child_status <"${status_file}" || return 1
  [[ "${status_lines}" == 1 \
      && "${status_bytes}" == "$(( ${#child_status} + 1 ))" ]] || return 1
  [[ "${child_status}" =~ ^([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$ ]] \
    || return 1
  rm -f "${guard}" "${status_file}" || return 1
  [[ ! -e "${guard}" && ! -L "${guard}" \
      && ! -e "${status_file}" && ! -L "${status_file}" ]] || return 1
  printf '%s\n' "${child_status}"
}
