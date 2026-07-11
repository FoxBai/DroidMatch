#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

serial=""
entry_count=1005
page_size=1000
timeout_seconds=20
adb_bin="${DROIDMATCH_ADB:-$(command -v adb || true)}"

usage() {
  cat <<'USAGE'
Run a disposable app-sandbox large-directory pagination probe.

Usage:
  tools/run-large-directory-device-smoke.sh --serial <serial> [options]

Options:
  --serial <serial>          Explicit authorized writable test device.
  --entries <count>          Empty entries to create. Default: 1005; max: 10000.
  --page-size <count>        Protocol page size. Default: 1000; max: 1000.
  --timeout-seconds <value>  Per-request timeout. Default: 20.
  --adb <path>               adb executable override.

The probe refuses an existing directory, prints aggregate counts only, and uses
an EXIT trap to remove exactly its generated app-sandbox directory and forward.
中文：probe 拒绝复用已有目录，只输出聚合计数，并由 EXIT trap 精确清理本次目录与 forward。
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) serial="${2:?missing value for --serial}"; shift 2 ;;
    --entries) entry_count="${2:?missing value for --entries}"; shift 2 ;;
    --page-size) page_size="${2:?missing value for --page-size}"; shift 2 ;;
    --timeout-seconds) timeout_seconds="${2:?missing value for --timeout-seconds}"; shift 2 ;;
    --adb) adb_bin="${2:?missing value for --adb}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "${serial}" ]]; then
  printf '%s\n' '--serial is required; this probe never guesses among devices.' >&2
  exit 2
fi
if [[ ! -x "${adb_bin}" ]]; then
  printf 'adb executable is unavailable: %s\n' "${adb_bin}" >&2
  exit 2
fi
if ! [[ "${entry_count}" =~ ^[1-9][0-9]*$ ]] || (( entry_count > 10000 )); then
  printf '%s\n' '--entries must be an integer from 1 through 10000.' >&2
  exit 2
fi
if ! [[ "${page_size}" =~ ^[1-9][0-9]*$ ]] || (( page_size > 1000 )); then
  printf '%s\n' '--page-size must be an integer from 1 through 1000.' >&2
  exit 2
fi
if ! [[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]]; then
  printf '%s\n' '--timeout-seconds must be a positive integer.' >&2
  exit 2
fi

device_state="$(${adb_bin} -s "${serial}" get-state 2>/dev/null || true)"
if [[ "${device_state}" != "device" ]]; then
  printf 'selected device is not ready: %s\n' "${device_state:-missing}" >&2
  exit 1
fi
if ! "${adb_bin}" -s "${serial}" shell pm path app.droidmatch >/dev/null 2>&1; then
  printf '%s\n' 'app.droidmatch must already be installed; the probe will not replace product data.' >&2
  exit 1
fi

probe_name="dm-large-directory-probe-$$"
remote_root="files/droidmatch-sandbox"
local_port=""
created=0

cleanup() {
  if [[ -n "${local_port}" ]]; then
    "${adb_bin}" -s "${serial}" forward --remove "tcp:${local_port}" >/dev/null 2>&1 || true
  fi
  if [[ "${created}" -eq 1 ]]; then
    "${adb_bin}" -s "${serial}" shell \
      "run-as app.droidmatch rm -rf '${remote_root}/${probe_name}'" >/dev/null 2>&1 || true
  fi
  "${adb_bin}" -s "${serial}" shell am force-stop app.droidmatch >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${adb_bin}" -s "${serial}" shell \
  "run-as app.droidmatch sh -c 'test ! -e ${remote_root}/${probe_name} && mkdir -p ${remote_root}/${probe_name}'"
created=1
"${adb_bin}" -s "${serial}" shell \
  "run-as app.droidmatch sh -c 'i=0; while [ \"\$i\" -lt ${entry_count} ]; do name=\$(printf \"entry-%05d.bin\" \"\$i\"); : > ${remote_root}/${probe_name}/\"\$name\"; i=\$((i + 1)); done'"

seeded_count="$(
  "${adb_bin}" -s "${serial}" shell \
    "run-as app.droidmatch sh -c 'ls -1 ${remote_root}/${probe_name} | wc -l'" \
    | tr -d '\r[:space:]'
)"
if [[ "${seeded_count}" != "${entry_count}" ]]; then
  printf 'seed count mismatch: expected %s, got %s\n' "${entry_count}" "${seeded_count}" >&2
  exit 1
fi

swift build --package-path mac --product droidmatch-harness >/dev/null
"${adb_bin}" -s "${serial}" shell am force-stop app.droidmatch >/dev/null
"${adb_bin}" -s "${serial}" shell am start -W \
  -n app.droidmatch/.m1.DebugHarnessActivity --ei port 39001 >/dev/null
local_port="$("${adb_bin}" -s "${serial}" forward tcp:0 tcp:39001 | tr -d '\r[:space:]')"

mac/.build/debug/droidmatch-harness list-dir-all \
  --port "${local_port}" \
  --path "dm://app-sandbox/${probe_name}/" \
  --page-size "${page_size}" \
  --expected-total "${entry_count}" \
  --timeout-seconds "${timeout_seconds}"
printf 'large-directory device probe passed entries=%s cleanup=scheduled\n' "${entry_count}"
