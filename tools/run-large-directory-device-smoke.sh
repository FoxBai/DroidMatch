#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

serial=""
entry_count=1005
page_size=1000
timeout_seconds=20
measure_memory=0
adb_bin="${DROIDMATCH_ADB:-$(command -v adb || true)}"
harness_bin="${DROIDMATCH_HARNESS:-${repo_root}/mac/.build/debug/droidmatch-harness}"

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
  --measure-memory           Sample aggregate app PSS while listing. This is a
                             diagnostic run; do not use its elapsed time as a gate.
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
    --measure-memory) measure_memory=1; shift ;;
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
list_output_file=""
list_pid=""
created=0

cleanup() {
  if [[ -n "${list_pid}" ]] && kill -0 "${list_pid}" 2>/dev/null; then
    kill "${list_pid}" 2>/dev/null || true
    wait "${list_pid}" 2>/dev/null || true
  fi
  if [[ -n "${local_port}" ]]; then
    "${adb_bin}" -s "${serial}" forward --remove "tcp:${local_port}" >/dev/null 2>&1 || true
  fi
  if [[ "${created}" -eq 1 ]]; then
    "${adb_bin}" -s "${serial}" shell \
      "run-as app.droidmatch rm -rf '${remote_root}/${probe_name}'" >/dev/null 2>&1 || true
  fi
  if [[ -n "${list_output_file}" ]]; then
    rm -f "${list_output_file}"
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

if [[ -z "${DROIDMATCH_HARNESS:-}" ]]; then
  swift build --package-path mac --product droidmatch-harness >/dev/null
elif [[ ! -x "${harness_bin}" ]]; then
  printf '%s\n' 'DROIDMATCH_HARNESS must name an executable test harness' >&2
  exit 2
fi
"${adb_bin}" -s "${serial}" shell am force-stop app.droidmatch >/dev/null
"${adb_bin}" -s "${serial}" shell am start -W \
  -n app.droidmatch/.m1.DebugHarnessActivity --ei port 39001 >/dev/null
local_port="$("${adb_bin}" -s "${serial}" forward tcp:0 tcp:39001 | tr -d '\r[:space:]')"

list_directory() {
  "${harness_bin}" list-dir-all \
    --port "${local_port}" \
    --path "dm://app-sandbox/${probe_name}/" \
    --page-size "${page_size}" \
    --expected-total "${entry_count}" \
    --timeout-seconds "${timeout_seconds}"
}

total_pss_kib() {
  # Android 14 prints `TOTAL PSS: <integer> ...`; unknown OEM/API formats
  # fail the numeric check instead of being archived as a misleading sample.
  "${adb_bin}" -s "${serial}" shell dumpsys meminfo app.droidmatch 2>/dev/null \
    | tr -d '\r' \
    | awk '/TOTAL PSS:/ { print $3; exit }'
}

if [[ "${measure_memory}" -eq 0 ]]; then
  list_directory
else
  baseline_pss="$(total_pss_kib)"
  if ! [[ "${baseline_pss}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' 'could not read aggregate app PSS before the listing probe' >&2
    exit 1
  fi
  peak_pss="${baseline_pss}"
  list_output_file="$(mktemp "${TMPDIR:-/tmp}/droidmatch-large-directory.XXXXXX")"
  list_directory >"${list_output_file}" 2>&1 &
  list_pid=$!
  while kill -0 "${list_pid}" 2>/dev/null; do
    sampled_pss="$(total_pss_kib || true)"
    if [[ "${sampled_pss}" =~ ^[0-9]+$ ]] && (( sampled_pss > peak_pss )); then
      peak_pss="${sampled_pss}"
    fi
    sleep 0.1
  done
  set +e
  wait "${list_pid}"
  list_status=$?
  set -e
  list_pid=""
  if [[ "${list_status}" -ne 0 ]]; then
    printf '%s\n' 'list-dir-all failed; captured output withheld by the privacy boundary' >&2
    exit "${list_status}"
  fi
  aggregate_output="$(
    grep -E '^list-dir-all passed pages=[0-9]+ page_counts=[0-9,]+ entries=[0-9]+ elapsed_ms=[0-9]+$' \
      "${list_output_file}" || true
  )"
  if [[ -z "${aggregate_output}" ]] || [[ "${aggregate_output}" == *$'\n'* ]]; then
    printf '%s\n' 'list-dir-all returned an unexpected output shape; captured output withheld' >&2
    exit 1
  fi
  printf '%s\n' "${aggregate_output}"
  printf 'memory_pss_kib baseline=%s peak=%s delta=%s sampling=diagnostic\n' \
    "${baseline_pss}" "${peak_pss}" "$((peak_pss - baseline_pss))"
fi

# Run the same idempotent cleanup used by EXIT, then prove only aggregate
# absence for this runner's exact resources. No generated name is printed.
cleanup
if "${adb_bin}" -s "${serial}" shell \
    "run-as app.droidmatch test -e '${remote_root}/${probe_name}'" >/dev/null 2>&1; then
  printf '%s\n' 'generated probe directory remained after cleanup' >&2
  exit 1
fi
if "${adb_bin}" -s "${serial}" forward --list \
    | awk -v local="tcp:${local_port}" '$2 == local && $3 == "tcp:39001" { found=1 } END { exit !found }'; then
  printf '%s\n' 'generated debug forward remained after cleanup' >&2
  exit 1
fi
created=0
local_port=""
list_output_file=""
printf 'large-directory device probe passed entries=%s cleanup=verified\n' "${entry_count}"
