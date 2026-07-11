#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle_id="app.droidmatch.mac"
expected_label=""
timeout_seconds=5
poll_interval=0.1
probe="${DROIDMATCH_PRODUCT_VISIBLE_PROBE:-}"
work=""

usage() {
  cat <<'USAGE'
Measure attended physical USB insertion to visibility in the foreground Mac App.

Usage:
  tools/run-product-usb-insertion-smoke.sh --expected-label <visible-device-name> [options]

Options:
  --bundle-id <id>            Product bundle ID (default app.droidmatch.mac).
  --timeout-seconds <value>   Visibility gate in seconds (default 5).
  --poll-interval <value>     Accessibility polling interval (default 0.1).
  --probe <path>              Prebuilt/fake visibility probe override.

The selected device must be physically disconnected and absent from the App
before this runner starts. Keep DroidMatch foreground-active. Press Enter and
immediately insert the cable; the timer includes human insertion time and stops
only when one discovery button contains both the expected label and `ADB` in the
product Accessibility tree. Trusted-device history and file names do not count.

This is an attended measurement. It never reads ADB, never operates Android,
and never archives or claims a physical-device pass automatically.

中文：开始前目标设备必须已物理断开且未显示在 App 中，并保持 DroidMatch 在前台。
按回车后立即插线；计时包含人工插线时间，只在产品可访问性树的发现按钮同时出现指定
名称与 `ADB` 时停止；受信任设备历史或文件名不算设备可见。
本工具不读取 ADB、不操作 Android，也不会自动归档或宣称真机通过。
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-id) bundle_id="${2:?missing value for --bundle-id}"; shift 2 ;;
    --expected-label) expected_label="${2:?missing value for --expected-label}"; shift 2 ;;
    --timeout-seconds) timeout_seconds="${2:?missing value}"; shift 2 ;;
    --poll-interval) poll_interval="${2:?missing value}"; shift 2 ;;
    --probe) probe="${2:?missing value for --probe}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "${bundle_id}" && -n "${expected_label}" ]] || {
  printf '%s\n' '--expected-label and a non-empty bundle ID are required.' >&2; exit 2;
}
for value in "${timeout_seconds}" "${poll_interval}"; do
  [[ "${value}" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] || {
    printf 'invalid positive duration: %s\n' "${value}" >&2; exit 2;
  }
  awk -v value="${value}" 'BEGIN { exit !(value > 0) }' || {
    printf 'duration must be greater than zero: %s\n' "${value}" >&2; exit 2;
  }
done
command -v perl >/dev/null 2>&1 || {
  printf '%s\n' 'Perl Time::HiRes is required for a cross-process monotonic clock.' >&2
  exit 2
}
monotonic_ns() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
    -e 'printf "%.0f", clock_gettime(CLOCK_MONOTONIC) * 1000000000'
}

if [[ -z "${probe}" ]]; then
  command -v xcrun >/dev/null 2>&1 || {
    printf '%s\n' 'xcrun is required to build the product-visible probe.' >&2; exit 2;
  }
  work="$(mktemp -d)"
  trap 'rm -rf "${work}"' EXIT
  probe="${work}/product-device-visible"
  xcrun swiftc "${repo_root}/tools/product-device-visibility-policy.swift" \
    "${repo_root}/tools/product-device-visible.swift" \
    -framework AppKit -framework ApplicationServices -o "${probe}"
fi
[[ -x "${probe}" ]] || { printf 'visibility probe is not executable: %s\n' "${probe}" >&2; exit 2; }

set +e
"${probe}" "${bundle_id}" "${expected_label}"
initial_status=$?
set -e
if [[ "${initial_status}" -eq 0 ]]; then
  printf '%s\n' 'expected device label is already visible; physically disconnect it first.' >&2
  exit 1
fi
if [[ "${initial_status}" -ne 1 ]]; then
  printf 'product-visible preflight failed with status %s.\n' "${initial_status}" >&2
  exit "${initial_status}"
fi

printf 'READY: press Enter and immediately physically insert the USB cable.\n'
printf '准备完成：按回车后立即物理插入 USB 线。\n'
IFS= read -r _
start_ns="$(monotonic_ns)"
timeout_ns="$(awk -v seconds="${timeout_seconds}" 'BEGIN { printf "%.0f", seconds * 1000000000 }')"

while true; do
  set +e
  "${probe}" "${bundle_id}" "${expected_label}"
  status=$?
  set -e
  now_ns="$(monotonic_ns)"
  elapsed_ns=$((now_ns - start_ns))
  if [[ "${status}" -eq 0 ]]; then
    if (( elapsed_ns > timeout_ns )); then
      printf 'device label became product-visible only after the %s-second gate.\n' \
        "${timeout_seconds}" >&2
      exit 1
    fi
    elapsed_ms=$((elapsed_ns / 1000000))
    threshold_ms="$(awk -v seconds="${timeout_seconds}" 'BEGIN { printf "%.0f", seconds * 1000 }')"
    printf 'product_usb_insertion_elapsed_ms=%s threshold_ms=%s label=%q\n' \
      "${elapsed_ms}" "${threshold_ms}" "${expected_label}"
    printf '产品 USB 插入可见时延=%s 毫秒（门槛 %s 毫秒）。\n' \
      "${elapsed_ms}" "${threshold_ms}"
    exit 0
  fi
  if [[ "${status}" -ne 1 ]]; then
    printf 'product-visible probe failed with status %s.\n' "${status}" >&2
    exit "${status}"
  fi
  if (( elapsed_ns >= timeout_ns )); then
    printf 'device label did not become product-visible within %s seconds.\n' \
      "${timeout_seconds}" >&2
    exit 1
  fi
  sleep "${poll_interval}"
done
