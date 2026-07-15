#!/usr/bin/env bash

set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
source "${repo_root}/tools/git-main-read.sh"
# shellcheck source=tools/product-usb-evidence-publication.sh
source "${repo_root}/tools/product-usb-evidence-publication.sh"

readonly evidence_profile="m1-product-usb-insertion-v1"
readonly product_bundle_id="app.droidmatch.mac"
readonly accessibility_identifier="app.droidmatch.discovery-device-card"
readonly formal_probe_pattern='^product_visible_matches=1 bundle_cdhash=([0-9a-f]{40}) dynamic_requirement_verified=true$'
readonly main_refresh_attempts=3
readonly main_refresh_interval_seconds=2

bundle_id="${product_bundle_id}"
expected_label=""
expected_main_sha=""
device_slot=""
app_bundle=""
sandboxed_app=0
timeout_seconds=5
poll_interval=0.1
countdown_seconds=3
probe="${DROIDMATCH_PRODUCT_VISIBLE_PROBE:-}"
probe_override=0
result_log=""
work=""
staged_log=""

[[ -z "${probe}" ]] || probe_override=1

usage() {
  cat <<'USAGE'
Measure attended physical USB insertion to visibility in the foreground Mac App.

Diagnostic usage:
  tools/run-product-usb-insertion-smoke.sh --expected-label <visible-device-name> [options]

Formal evidence usage:
  tools/run-product-usb-insertion-smoke.sh \
    --expected-label <visible-device-name> \
    --device-slot <A|C|D> \
    --expected-main-sha <40-hex-origin-main-sha> \
    --app-bundle <DroidMatch.app> \
    --result-log fixtures/product-usb-insertion/<name>.md

Options:
  --bundle-id <id>            Product bundle ID (default app.droidmatch.mac).
  --timeout-seconds <value>   Visibility gate in seconds (default 5).
  --poll-interval <value>     Accessibility polling interval (default 0.1).
  --countdown-seconds <n>     Arming countdown after Enter (default 3).
  --probe <path>              Prebuilt/fake visibility probe override; diagnostic only.
  --app-bundle <path>         Exact running release App bundle; required for a formal fixture.
  --sandboxed-app             Validate the formal bundle with sandbox entitlements.
  --device-slot <A|C|D>       Required matrix slot for a formal fixture.
  --expected-main-sha <sha>   Required clean current-main revision for a formal fixture.
  --result-log <path>         Opt-in formal fixture under fixtures/product-usb-insertion/.

The selected device must be physically disconnected and absent from the App.
Keep the current DroidMatch product App foreground-active. Enter arms a fixed
countdown; do not insert during that countdown. The runner checks absence again,
starts the monotonic clock before printing `INSERT NOW`, and stops only when the
identified product discovery card contains both the expected label and `ADB`.

Formal evidence rejects a dirty/stale repository, a probe override, a running App
whose embedded source revision differs from clean current `origin/main`, a timing
configuration other than 3-second countdown / 5-second gate, and any staged log
that fails the dedicated privacy and schema validator.

中文：目标设备开始前必须物理断开且不在 App 中显示，并保持当前产品 App 在前台。
回车只用于布防固定倒计时；倒计时期间不要插线。runner 会再次确认设备仍未出现，先启动
单调时钟，再打印 `INSERT NOW`；只有带固定标识的产品发现卡片同时包含指定名称和 `ADB`
才停止。正式证据还要求 clean current-main、运行 App 内嵌 SHA 完全匹配、固定 3 秒倒计时
和 5 秒门槛，并通过专用隐私/结构校验器。
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-id) bundle_id="${2:?missing value for --bundle-id}"; shift 2 ;;
    --expected-label) expected_label="${2:?missing value for --expected-label}"; shift 2 ;;
    --expected-main-sha) expected_main_sha="${2:?missing value for --expected-main-sha}"; shift 2 ;;
    --app-bundle) app_bundle="${2:?missing value for --app-bundle}"; shift 2 ;;
    --sandboxed-app) sandboxed_app=1; shift ;;
    --device-slot) device_slot="${2:?missing value for --device-slot}"; shift 2 ;;
    --timeout-seconds) timeout_seconds="${2:?missing value for --timeout-seconds}"; shift 2 ;;
    --poll-interval) poll_interval="${2:?missing value for --poll-interval}"; shift 2 ;;
    --countdown-seconds) countdown_seconds="${2:?missing value for --countdown-seconds}"; shift 2 ;;
    --probe) probe="${2:?missing value for --probe}"; probe_override=1; shift 2 ;;
    --result-log) result_log="${2:?missing value for --result-log}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '%s\n' 'unknown product USB insertion option.' >&2; exit 2 ;;
  esac
done

[[ -n "${bundle_id}" && "${expected_label}" =~ [^[:space:]] \
    && "${#expected_label}" -le 80 \
    && "${expected_label}" != *$'\n'* ]] || {
  printf '%s\n' '--expected-label and a non-empty bundle ID are required; label length is limited to 80.' >&2
  exit 2
}
expected_label="$(printf '%s' "${expected_label}" \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
for value in "${timeout_seconds}" "${poll_interval}"; do
  [[ "${value}" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] || {
    printf '%s\n' 'timeout and poll interval must be positive numbers.' >&2
    exit 2
  }
  awk -v value="${value}" 'BEGIN { exit !(value > 0) }' || {
    printf '%s\n' 'timeout and poll interval must be greater than zero.' >&2
    exit 2
  }
done
[[ "${countdown_seconds}" =~ ^[0-9]+$ ]] || {
  printf '%s\n' '--countdown-seconds must be a non-negative integer.' >&2
  exit 2
}

formal_evidence=0
if [[ -n "${result_log}" || -n "${expected_main_sha}" || -n "${device_slot}" \
    || -n "${app_bundle}" || "${sandboxed_app}" -eq 1 ]]; then
  formal_evidence=1
  [[ -n "${result_log}" && -n "${app_bundle}" \
      && "${expected_main_sha}" =~ ^[0-9a-f]{40}$ \
      && "${device_slot}" =~ ^(A|C|D)$ ]] || {
    printf '%s\n' 'formal evidence requires --result-log, --app-bundle, --expected-main-sha, and Slot A/C/D.' >&2
    exit 2
  }
  [[ "${bundle_id}" == "${product_bundle_id}" \
      && "${timeout_seconds}" == "5" \
      && "${poll_interval}" == "0.1" \
      && "${countdown_seconds}" == "3" \
      && "${probe_override}" -eq 0 ]] || {
    printf '%s\n' 'formal evidence requires the product bundle, 5-second gate, 3-second countdown, and repository probe.' >&2
    exit 2
  }
  [[ "${expected_label}" != *'/'* && "${expected_label}" != *'\\'* \
      && ! "${expected_label}" =~ [[:cntrl:]] ]] || {
    printf '%s\n' 'formal evidence requires a privacy-bounded visible model label.' >&2
    exit 2
  }
  [[ "${result_log}" =~ ^fixtures/product-usb-insertion/[A-Za-z0-9._-]+[.]md$ \
      && ! -e "${result_log}" && ! -L "${result_log}" ]] || {
    printf '%s\n' 'formal result log must be a new simple Markdown path under fixtures/product-usb-insertion/.' >&2
    exit 2
  }

  refresh_origin_branch_with_retry \
    origin main "${main_refresh_attempts}" "${main_refresh_interval_seconds}" || {
    printf '%s\n' 'could not refresh origin/main before the attended run.' >&2
    exit 1
  }
  head_sha="$(git rev-parse HEAD 2>/dev/null)"
  origin_main_sha="$(git rev-parse refs/remotes/origin/main 2>/dev/null)"
  pre_run_git_status="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null)" || {
    printf '%s\n' 'could not verify repository cleanliness before the attended run.' >&2
    exit 1
  }
  [[ "${head_sha}" == "${expected_main_sha}" \
      && "${origin_main_sha}" == "${expected_main_sha}" \
      && -z "${pre_run_git_status}" ]] || {
    printf '%s\n' 'formal evidence requires clean HEAD, expected SHA, and fresh origin/main to match.' >&2
    exit 1
  }

  [[ -d "${app_bundle}" && "${app_bundle}" == *.app ]] || {
    printf '%s\n' '--app-bundle must identify an existing DroidMatch.app bundle.' >&2
    exit 2
  }
  app_bundle="$(cd "${app_bundle}" && pwd -P)"
  bundle_check_args=(tools/check-mac-app-bundle.py)
  bundle_sandboxed_value=false
  if [[ "${sandboxed_app}" -eq 1 ]]; then
    bundle_check_args+=(--sandboxed)
    bundle_sandboxed_value=true
  fi
  bundle_check_args+=("${app_bundle}")
  python3 "${bundle_check_args[@]}" >/dev/null 2>&1 || {
    printf '%s\n' 'the requested product App bundle failed artifact verification.' >&2
    exit 1
  }
  bundle_revision="$(plutil -extract DroidMatchSourceRevision raw -o - \
    "${app_bundle}/Contents/Info.plist" 2>/dev/null || true)"
  bundle_dirty="$(plutil -extract DroidMatchSourceDirty raw -o - \
    "${app_bundle}/Contents/Info.plist" 2>/dev/null || true)"
  bundle_configuration="$(plutil -extract DroidMatchBuildConfiguration raw -o - \
    "${app_bundle}/Contents/Info.plist" 2>/dev/null || true)"
  [[ "${bundle_revision}" == "${expected_main_sha}" \
      && "${bundle_dirty}" == "false" \
      && "${bundle_configuration}" == "release" ]] || {
    printf '%s\n' 'formal evidence requires a clean release bundle from the expected revision.' >&2
    exit 1
  }
  bundle_executable_sha256="$(shasum -a 256 \
    "${app_bundle}/Contents/MacOS/DroidMatch" 2>/dev/null | awk '{print $1}')"
  [[ "${bundle_executable_sha256}" =~ ^[0-9a-f]{64}$ ]] || {
    printf '%s\n' 'could not fingerprint the requested product executable.' >&2
    exit 1
  }
  if ! { exec 9<>/dev/tty; } 2>/dev/null || [[ ! -t 9 ]]; then
    printf '%s\n' 'formal evidence requires an attended controlling terminal.' >&2
    exit 1
  fi
fi

command -v perl >/dev/null 2>&1 || {
  printf '%s\n' 'Perl Time::HiRes is required for a cross-process monotonic clock.' >&2
  exit 2
}
monotonic_ns() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
    -e 'printf "%.0f", clock_gettime(CLOCK_MONOTONIC) * 1000000000'
}

cleanup() {
  if [[ -n "${staged_log}" ]]; then
    rm -f "${staged_log}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${work}" ]]; then
    rm -rf "${work}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ -z "${probe}" ]]; then
  command -v xcrun >/dev/null 2>&1 || {
    printf '%s\n' 'xcrun is required to build the product-visible probe.' >&2
    exit 2
  }
  work="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-product-usb.XXXXXX")"
  probe="${work}/product-device-visible"
  xcrun swiftc \
    mac/Sources/DroidMatchApp/ProductAccessibilityIdentifiers.swift \
    tools/product-device-visibility-policy.swift \
    tools/product-device-visible.swift \
    -framework AppKit -framework ApplicationServices -framework Security -o "${probe}"
fi
[[ -x "${probe}" ]] || {
  printf '%s\n' 'visibility probe is not executable.' >&2
  exit 2
}

run_probe() {
  if [[ "${formal_evidence}" -eq 1 ]]; then
    "${probe}" "${bundle_id}" "${expected_label}" "${expected_main_sha}" "${app_bundle}"
  else
    "${probe}" "${bundle_id}" "${expected_label}"
  fi
}

set +e
initial_probe_output="$(run_probe)"
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

printf 'READY: press Enter to arm; do not insert during the countdown.\n'
printf '准备完成：按回车布防；倒计时期间不要插入 USB 线。\n'
if [[ "${formal_evidence}" -eq 1 ]]; then
  read_source_fd=9
else
  read_source_fd=0
fi
if ! IFS= read -r _ <&"${read_source_fd}"; then
  printf '%s\n' 'attended prompt ended before Enter was received.' >&2
  exit 1
fi
for ((remaining = countdown_seconds; remaining > 0; remaining -= 1)); do
  printf 'ARMING: %s\n' "${remaining}"
  sleep 1
done

set +e
pre_signal_probe_output="$(run_probe)"
pre_signal_status=$?
set -e
if [[ "${pre_signal_status}" -eq 0 ]]; then
  printf '%s\n' 'device became visible before INSERT NOW; measurement refused.' >&2
  exit 1
fi
if [[ "${pre_signal_status}" -ne 1 ]]; then
  printf 'product-visible pre-signal check failed with status %s.\n' \
    "${pre_signal_status}" >&2
  exit "${pre_signal_status}"
fi

start_ns="$(monotonic_ns)"
printf 'INSERT NOW: physically insert the selected USB cable.\n'
printf '现在插入：请物理插入所选 USB 线。\n'
timeout_ns="$(awk -v seconds="${timeout_seconds}" 'BEGIN { printf "%.0f", seconds * 1000000000 }')"

while true; do
  set +e
  probe_output="$(run_probe)"
  status=$?
  set -e
  now_ns="$(monotonic_ns)"
  elapsed_ns=$((now_ns - start_ns))
  if [[ "${status}" -eq 0 ]]; then
    if (( elapsed_ns > timeout_ns )); then
      printf 'device became product-visible only after the %s-second gate.\n' \
        "${timeout_seconds}" >&2
      exit 1
    fi
    break
  fi
  if [[ "${status}" -ne 1 ]]; then
    printf 'product-visible probe failed with status %s.\n' "${status}" >&2
    exit "${status}"
  fi
  if (( elapsed_ns >= timeout_ns )); then
    printf 'device did not become product-visible within %s seconds.\n' \
      "${timeout_seconds}" >&2
    exit 1
  fi
  sleep "${poll_interval}"
done

elapsed_ms=$((elapsed_ns / 1000000))
threshold_ms="$(awk -v seconds="${timeout_seconds}" 'BEGIN { printf "%.0f", seconds * 1000 }')"

if [[ "${formal_evidence}" -eq 1 ]]; then
  [[ "${probe_output}" =~ ${formal_probe_pattern} ]] || {
    printf '%s\n' 'the successful product-visible probe did not prove dynamic code identity.' >&2
    exit 1
  }
  bundle_code_cdhash="${BASH_REMATCH[1]}"
  attestation_challenge="$(printf '%s-%s-%s' "$(monotonic_ns)" "$$" "${RANDOM}" \
    | shasum -a 256 | awk '{print substr($1, 1, 8)}')"
  printf 'CONFIRM: type INSERTED %s to attest that you physically inserted the selected cable after INSERT NOW.\n' \
    "${attestation_challenge}"
  printf '确认：请输入 INSERTED %s，证明你在 INSERT NOW 后物理插入了所选线缆。\n' \
    "${attestation_challenge}"
  if ! IFS= read -r physical_attestation <&9 \
      || [[ "${physical_attestation}" != "INSERTED ${attestation_challenge}" ]]; then
    printf '%s\n' 'physical insertion attestation was not confirmed; evidence refused.' >&2
    exit 1
  fi
  python3 "${bundle_check_args[@]}" >/dev/null 2>&1 || {
    printf '%s\n' 'the product App bundle changed or failed verification during the attended run.' >&2
    exit 1
  }
  post_bundle_revision="$(plutil -extract DroidMatchSourceRevision raw -o - \
    "${app_bundle}/Contents/Info.plist" 2>/dev/null || true)"
  post_bundle_dirty="$(plutil -extract DroidMatchSourceDirty raw -o - \
    "${app_bundle}/Contents/Info.plist" 2>/dev/null || true)"
  post_bundle_configuration="$(plutil -extract DroidMatchBuildConfiguration raw -o - \
    "${app_bundle}/Contents/Info.plist" 2>/dev/null || true)"
  post_bundle_executable_sha256="$(shasum -a 256 \
    "${app_bundle}/Contents/MacOS/DroidMatch" 2>/dev/null | awk '{print $1}')"
  [[ "${post_bundle_revision}" == "${bundle_revision}" \
      && "${post_bundle_dirty}" == "${bundle_dirty}" \
      && "${post_bundle_configuration}" == "${bundle_configuration}" \
      && "${post_bundle_executable_sha256}" == "${bundle_executable_sha256}" ]] || {
    printf '%s\n' 'product App artifact provenance changed during the attended run.' >&2
    exit 1
  }
  refresh_origin_branch_with_retry \
    origin main "${main_refresh_attempts}" "${main_refresh_interval_seconds}" || {
    printf '%s\n' 'could not refresh origin/main after the attended run.' >&2
    exit 1
  }
  post_head_sha="$(git rev-parse HEAD 2>/dev/null)"
  post_origin_main_sha="$(git rev-parse refs/remotes/origin/main 2>/dev/null)"
  post_run_git_status="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null)" || {
    printf '%s\n' 'could not verify repository cleanliness after the attended run.' >&2
    exit 1
  }
  [[ "${post_head_sha}" == "${expected_main_sha}" \
      && "${post_origin_main_sha}" == "${expected_main_sha}" \
      && -z "${post_run_git_status}" ]] || {
    printf '%s\n' 'repository provenance changed during the attended run.' >&2
    exit 1
  }

  mkdir -p "$(dirname "${result_log}")" 2>/dev/null || {
    printf '%s\n' 'could not prepare the product USB evidence directory.' >&2
    exit 1
  }
  staged_log="$(mktemp "$(dirname "${result_log}")/.product-usb-insertion.XXXXXX" 2>/dev/null)" || {
    printf '%s\n' 'could not stage the product USB evidence log.' >&2
    exit 1
  }
  {
    printf '# M1 Product USB Insertion Evidence\n\n'
    printf 'status: passed\n'
    printf 'evidence profile: %s\n' "${evidence_profile}"
    printf 'profile result: passed\n'
    printf 'date: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')"
    printf 'device slot: %s\n' "${device_slot}"
    printf 'device label: %s\n' "${expected_label}"
    printf 'bundle id: %s\n' "${bundle_id}"
    printf 'profile source revision: %s\n' "${head_sha}"
    printf 'profile expected main revision: %s\n' "${expected_main_sha}"
    printf 'profile origin main revision: %s\n' "${origin_main_sha}"
    printf 'bundle source revision: %s\n' "${expected_main_sha}"
    printf 'bundle source dirty: false\n'
    printf 'bundle build configuration: release\n'
    printf 'bundle sandboxed: %s\n' "${bundle_sandboxed_value}"
    printf 'bundle executable sha256: %s\n' "${bundle_executable_sha256}"
    printf 'bundle code cdhash: %s\n' "${bundle_code_cdhash}"
    printf 'running code requirement verified: true\n'
    printf 'running app count: 1\n'
    printf 'running bundle matched requested app: true\n'
    printf 'bundle verification: passed\n'
    printf 'repository clean before run: true\n'
    printf 'repository clean after run: true\n'
    printf 'preflight matching elements: 0\n'
    printf 'pre-signal matching elements: 0\n'
    printf 'operator arm acknowledged: true\n'
    printf 'operator physical insertion attested: true\n'
    printf 'measurement clock: CLOCK_MONOTONIC\n'
    printf 'measurement boundary: monotonic-before-insert-now\n'
    printf 'countdown seconds: %s\n' "${countdown_seconds}"
    printf 'poll interval ms: 100\n'
    printf 'threshold ms: %s\n' "${threshold_ms}"
    printf 'elapsed ms: %s\n' "${elapsed_ms}"
    printf 'completion matching elements: 1\n'
    printf 'product visible: true\n'
    printf 'accessibility identifier: %s\n' "${accessibility_identifier}"
    printf 'probe override: false\n'
  } >"${staged_log}" || {
    printf '%s\n' 'could not write the staged product USB evidence log.' >&2
    exit 1
  }
  if ! publish_product_usb_staged_log \
      "${staged_log}" \
      "${result_log}" \
      "tools/check-product-usb-insertion-logs.sh"; then
    printf '%s\n' 'could not complete no-clobber publication of the product USB fixture as a regular file.' >&2
    exit 1
  fi
  staged_log=""
fi

printf 'product_usb_insertion_elapsed_ms=%s threshold_ms=%s label=%q boundary=monotonic-before-insert-now\n' \
  "${elapsed_ms}" "${threshold_ms}" "${expected_label}"
printf '产品 USB 插入可见时延=%s 毫秒（门槛 %s 毫秒）。\n' \
  "${elapsed_ms}" "${threshold_ms}"
if [[ "${formal_evidence}" -eq 1 ]]; then
  printf 'Product USB insertion evidence written: %s\n' "${result_log}"
fi
