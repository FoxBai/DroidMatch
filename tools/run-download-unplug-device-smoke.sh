#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

serial=""
source_path=""
destination=""
expected_bytes=""
disconnect_timeout=120
reconnect_timeout=300
poll_interval=1
request_timeout=30
adb_bin="${DROIDMATCH_ADB:-$(command -v adb || true)}"
harness_bin="${DROIDMATCH_HARNESS:-${repo_root}/mac/.build/debug/droidmatch-harness}"
local_port=""
download_pid=""
destination_is_temporary=0

usage() {
  cat <<'USAGE'
Run an attended physical-USB download interruption and resume probe.

Usage:
  tools/run-download-unplug-device-smoke.sh --serial <serial> \
    --source-path <dm://path> --expected-bytes <bytes> [options]

Options:
  --destination <path>             Final local path; default is a unique /tmp path.
  --disconnect-timeout <seconds>   Time to observe the selected device leave ADB (default 120).
  --reconnect-timeout <seconds>    Time to observe the same device return ready (default 300).
  --poll-interval <seconds>        Poll interval; decimals allowed (default 1).
  --request-timeout <seconds>      Harness request timeout (default 30).
  --adb <path>                     adb executable override.
  --harness <path>                 prebuilt harness override.

This probe never installs an APK and never guesses a device. It requires a human
to physically unplug and reconnect the selected device. A caller-supplied final
destination is retained; a probe-created /tmp destination is removed on exit.
中文：本探针不会安装 APK、不会猜测设备，需要人工拔出并重新连接指定设备。
用户指定的最终文件会保留；探针自行创建的 /tmp 文件会在退出时删除。
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) serial="${2:?missing value for --serial}"; shift 2 ;;
    --source-path) source_path="${2:?missing value for --source-path}"; shift 2 ;;
    --destination) destination="${2:?missing value for --destination}"; shift 2 ;;
    --expected-bytes) expected_bytes="${2:?missing value for --expected-bytes}"; shift 2 ;;
    --disconnect-timeout) disconnect_timeout="${2:?missing value}"; shift 2 ;;
    --reconnect-timeout) reconnect_timeout="${2:?missing value}"; shift 2 ;;
    --poll-interval) poll_interval="${2:?missing value}"; shift 2 ;;
    --request-timeout) request_timeout="${2:?missing value}"; shift 2 ;;
    --adb) adb_bin="${2:?missing value}"; shift 2 ;;
    --harness) harness_bin="${2:?missing value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "${serial}" ]] || { printf '%s\n' '--serial is required; the probe never guesses.' >&2; exit 2; }
[[ "${source_path}" == dm://* ]] || { printf '%s\n' '--source-path must be a dm:// path.' >&2; exit 2; }
[[ "${expected_bytes}" =~ ^[1-9][0-9]*$ ]] || { printf '%s\n' '--expected-bytes must be a positive integer.' >&2; exit 2; }
for value in "${disconnect_timeout}" "${reconnect_timeout}" "${poll_interval}" "${request_timeout}"; do
  [[ "${value}" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] || { printf 'invalid positive duration: %s\n' "${value}" >&2; exit 2; }
  awk -v value="${value}" 'BEGIN { exit !(value > 0) }' || { printf 'duration must be greater than zero: %s\n' "${value}" >&2; exit 2; }
done
[[ -x "${adb_bin}" ]] || { printf 'adb executable is unavailable: %s\n' "${adb_bin}" >&2; exit 2; }

if [[ -z "${destination}" ]]; then
  destination="${TMPDIR:-/tmp}/droidmatch-download-unplug-$$.bin"
  destination_is_temporary=1
fi
for path in "${destination}" "${destination}.droidmatch-part" "${destination}.droidmatch-transfer.json"; do
  [[ ! -e "${path}" ]] || { printf 'refusing existing local path: %s\n' "${path}" >&2; exit 1; }
done

device_state() { "${adb_bin}" -s "${serial}" get-state 2>/dev/null | tr -d '\r[:space:]' || true; }
device_present() {
  "${adb_bin}" devices 2>/dev/null | awk -v wanted="${serial}" 'NR > 1 && $1 == wanted { found=1 } END { exit !found }'
}
remove_forward() {
  if [[ -n "${local_port}" ]]; then
    "${adb_bin}" -s "${serial}" forward --remove "tcp:${local_port}" >/dev/null 2>&1 || true
    local_port=""
  fi
}
cleanup() {
  if [[ -n "${download_pid}" ]] && kill -0 "${download_pid}" 2>/dev/null; then
    kill "${download_pid}" 2>/dev/null || true
    wait "${download_pid}" 2>/dev/null || true
  fi
  remove_forward
  "${adb_bin}" -s "${serial}" shell am force-stop app.droidmatch >/dev/null 2>&1 || true
  if [[ "${destination_is_temporary}" -eq 1 ]]; then
    rm -f -- "${destination}" "${destination}.droidmatch-part" \
      "${destination}.droidmatch-transfer.json"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

[[ "$(device_state)" == device ]] || { printf '%s\n' 'selected device is not ready/authorized.' >&2; exit 1; }
"${adb_bin}" -s "${serial}" shell pm path app.droidmatch >/dev/null 2>&1 || {
  printf '%s\n' 'app.droidmatch must already be installed; this probe never installs it.' >&2; exit 1;
}
if [[ "${DROIDMATCH_SKIP_BUILD:-0}" != 1 ]]; then
  swift build --package-path mac --product droidmatch-harness >/dev/null
fi
[[ -x "${harness_bin}" ]] || { printf 'harness executable is unavailable: %s\n' "${harness_bin}" >&2; exit 2; }

start_endpoint() {
  "${adb_bin}" -s "${serial}" shell am force-stop app.droidmatch >/dev/null
  "${adb_bin}" -s "${serial}" shell am start -W \
    -n app.droidmatch/.m1.DebugHarnessActivity --ei port 39001 >/dev/null
  local_port="$("${adb_bin}" -s "${serial}" forward tcp:0 tcp:39001 | tr -d '\r[:space:]')"
  [[ "${local_port}" =~ ^[1-9][0-9]*$ ]] || { printf '%s\n' 'adb did not allocate a dynamic forward.' >&2; exit 1; }
}

start_endpoint
"${harness_bin}" download --port "${local_port}" --timeout-seconds "${request_timeout}" \
  --source-path "${source_path}" --destination "${destination}" &
download_pid=$!

printf '%s\n' 'UNPLUG NOW: physically disconnect the selected Android device.'
printf '%s\n' '现在拔线：请从指定 Android 设备上物理拔出 USB 线。'
deadline="$(awk -v now="$(date +%s)" -v timeout="${disconnect_timeout}" 'BEGIN { print now + timeout }')"
first_status=""
while device_present; do
  if ! kill -0 "${download_pid}" 2>/dev/null; then
    set +e; wait "${download_pid}"; first_status=$?; set -e
    download_pid=""
    if [[ "${first_status}" -eq 0 ]]; then
      printf '%s\n' 'first download completed before physical disconnect.' >&2
      exit 1
    fi
  fi
  awk -v now="$(date +%s)" -v deadline="${deadline}" 'BEGIN { exit !(now >= deadline) }' && {
    printf '%s\n' 'timed out before observing the selected device leave ADB.' >&2; exit 1;
  }
  sleep "${poll_interval}"
done

remove_forward
if [[ -z "${first_status}" ]]; then
  set +e; wait "${download_pid}"; first_status=$?; set -e
  download_pid=""
fi
[[ "${first_status}" -ne 0 ]] || { printf '%s\n' 'interrupted download unexpectedly succeeded.' >&2; exit 1; }
partial="${destination}.droidmatch-part"
sidecar="${destination}.droidmatch-transfer.json"
[[ -f "${partial}" && -s "${sidecar}" ]] || { printf '%s\n' 'interrupted download did not preserve partial and sidecar state.' >&2; exit 1; }
partial_bytes="$(wc -c <"${partial}" | tr -d '[:space:]')"
(( partial_bytes > 0 && partial_bytes < expected_bytes )) || {
  printf 'invalid durable partial size: %s (expected 0 < partial < %s).\n' "${partial_bytes}" "${expected_bytes}" >&2; exit 1;
}

printf 'DISCONNECT OBSERVED: durable partial bytes=%s. Reconnect the same device.\n' "${partial_bytes}"
printf '已观察到断线：持久 partial=%s 字节。请重新连接同一台设备。\n' "${partial_bytes}"
deadline="$(awk -v now="$(date +%s)" -v timeout="${reconnect_timeout}" 'BEGIN { print now + timeout }')"
while [[ "$(device_state)" != device ]]; do
  awk -v now="$(date +%s)" -v deadline="${deadline}" 'BEGIN { exit !(now >= deadline) }' && {
    printf '%s\n' 'timed out waiting for the same selected device to return ready/authorized.' >&2; exit 1;
  }
  sleep "${poll_interval}"
done

start_endpoint
"${harness_bin}" download --resume --port "${local_port}" --timeout-seconds "${request_timeout}" \
  --source-path "${source_path}" --destination "${destination}"
final_bytes="$(wc -c <"${destination}" | tr -d '[:space:]')"
[[ "${final_bytes}" == "${expected_bytes}" ]] || {
  printf 'final size mismatch: expected %s, got %s.\n' "${expected_bytes}" "${final_bytes}" >&2; exit 1;
}
[[ ! -e "${partial}" && ! -e "${sidecar}" ]] || {
  printf '%s\n' 'successful resume left partial transfer state behind.' >&2; exit 1;
}
printf 'physical download interruption/resume passed final_bytes=%s\n' "${final_bytes}"
printf '物理下载断线/续传通过，最终字节数=%s。\n' "${final_bytes}"
