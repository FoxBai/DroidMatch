#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

serial="${DROIDMATCH_SERIAL:-}"
remote_port="${DROIDMATCH_ANDROID_PORT:-39001}"
local_port="${DROIDMATCH_LOCAL_PORT:-0}"
timeout_seconds="${DROIDMATCH_SMOKE_TIMEOUT_SECONDS:-10}"
skip_build=0
download_source_path=""
download_destination=""
open_launcher=0

usage() {
  cat <<'USAGE'
Run the M1 debug APK on one adb-visible Android device and execute the Mac smoke harness.

Usage:
  tools/run-m1-device-smoke.sh [options]

Options:
  --serial <serial>              adb device serial. Required when multiple devices are ready.
  --remote-port <port>           Android endpoint port. Default: 39001.
  --local-port <port>            Mac forward port, or 0 for adb-allocated. Default: 0.
  --timeout-seconds <seconds>    Harness TCP timeout. Default: 10.
  --source-path <dm-path>        Optional logical path to download after m1-smoke.
  --destination <path>           Destination for --source-path download.
  --open-launcher                Also launch the app through the launcher entry after install.
  --skip-build                   Use the existing debug APK instead of running check-m1-skeleton.
  -h, --help                     Show this help.

Environment:
  DROIDMATCH_ADB                 adb executable path.
  DROIDMATCH_SERIAL              Default serial.
  DROIDMATCH_ANDROID_PORT        Default remote port.
  DROIDMATCH_LOCAL_PORT          Default local port.
  DROIDMATCH_SMOKE_TIMEOUT_SECONDS
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      serial="${2:?missing value for --serial}"
      shift 2
      ;;
    --remote-port)
      remote_port="${2:?missing value for --remote-port}"
      shift 2
      ;;
    --local-port)
      local_port="${2:?missing value for --local-port}"
      shift 2
      ;;
    --timeout-seconds)
      timeout_seconds="${2:?missing value for --timeout-seconds}"
      shift 2
      ;;
    --source-path)
      download_source_path="${2:?missing value for --source-path}"
      shift 2
      ;;
    --destination)
      download_destination="${2:?missing value for --destination}"
      shift 2
      ;;
    --open-launcher)
      open_launcher=1
      shift
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "${download_source_path}" && -z "${download_destination}" ]]; then
  download_destination="/tmp/droidmatch-device-smoke-download.bin"
fi

adb_bin="${DROIDMATCH_ADB:-}"
if [[ -z "${adb_bin}" ]]; then
  android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}"
  if [[ -x "${android_sdk}/platform-tools/adb" ]]; then
    adb_bin="${android_sdk}/platform-tools/adb"
  else
    adb_bin="adb"
  fi
fi

select_serial() {
  if [[ -n "${serial}" ]]; then
    return
  fi

  local ready=()
  local line device_serial device_state
  while IFS= read -r line; do
    [[ -z "${line}" || "${line}" == "List of devices attached"* ]] && continue
    device_serial="$(awk '{print $1}' <<<"${line}")"
    device_state="$(awk '{print $2}' <<<"${line}")"
    if [[ "${device_state}" == "device" ]]; then
      ready+=("${device_serial}")
    fi
  done < <("${adb_bin}" devices -l)

  if [[ "${#ready[@]}" -eq 1 ]]; then
    serial="${ready[0]}"
    return
  fi

  if [[ "${#ready[@]}" -eq 0 ]]; then
    printf 'No adb device is in "device" state. Check USB cable, Android USB debugging authorization, and `adb devices -l`.\n' >&2
    exit 1
  fi

  printf 'Multiple adb devices are ready; pass --serial. Ready serials:\n' >&2
  printf '  %s\n' "${ready[@]}" >&2
  exit 1
}

run_swift_harness() {
  swift run --package-path mac droidmatch-harness "$@"
}

cleanup() {
  if [[ -n "${allocated_local_port:-}" ]]; then
    "${adb_bin}" -s "${serial}" forward --remove "tcp:${allocated_local_port}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "${skip_build}" -eq 0 ]]; then
  bash tools/check-m1-skeleton.sh
fi

apk_path="android/app/build/outputs/apk/debug/app-debug.apk"
if [[ ! -s "${apk_path}" ]]; then
  printf 'Missing debug APK: %s. Run tools/check-m1-skeleton.sh first or omit --skip-build.\n' "${apk_path}" >&2
  exit 1
fi

select_serial
printf 'Using adb device serial=%s\n' "${serial}"

"${adb_bin}" -s "${serial}" install -r -g "${apk_path}"

launcher_output="$("${adb_bin}" -s "${serial}" shell cmd package resolve-activity --brief \
  -a android.intent.action.MAIN \
  -c android.intent.category.LAUNCHER \
  app.droidmatch 2>/dev/null | tr -d '\r')"
if ! grep -q 'app.droidmatch/app.droidmatch.m1.DiagnosticsActivity' <<<"${launcher_output}"; then
  printf 'Installed APK does not resolve DroidMatch DiagnosticsActivity as the launcher entry.\n' >&2
  printf '%s\n' "${launcher_output}" >&2
  exit 1
fi
printf 'Launcher entry verified: app.droidmatch/app.droidmatch.m1.DiagnosticsActivity\n'

if [[ "${open_launcher}" -eq 1 ]]; then
  "${adb_bin}" -s "${serial}" shell monkey -p app.droidmatch -c android.intent.category.LAUNCHER 1
fi

"${adb_bin}" -s "${serial}" logcat -c >/dev/null || true
"${adb_bin}" -s "${serial}" shell am force-stop app.droidmatch >/dev/null || true
"${adb_bin}" -s "${serial}" shell am start -W \
  -n app.droidmatch/app.droidmatch.m1.DebugHarnessActivity \
  --ei port "${remote_port}"

forward_output="$(run_swift_harness forward --serial "${serial}" --local-port "${local_port}" --remote-port "${remote_port}")"
printf '%s\n' "${forward_output}"
allocated_local_port="$(sed -n 's/.*local_port=\([0-9][0-9]*\).*/\1/p' <<<"${forward_output}" | tail -1)"
if [[ -z "${allocated_local_port}" ]]; then
  printf 'Could not parse allocated local_port from forward output.\n' >&2
  exit 1
fi

run_swift_harness m1-smoke --port "${allocated_local_port}" --timeout-seconds "${timeout_seconds}"

if [[ -n "${download_source_path}" ]]; then
  run_swift_harness download \
    --port "${allocated_local_port}" \
    --timeout-seconds "${timeout_seconds}" \
    --source-path "${download_source_path}" \
    --destination "${download_destination}"
fi

printf 'M1 device smoke passed serial=%s local_port=%s remote_port=%s\n' \
  "${serial}" "${allocated_local_port}" "${remote_port}"
