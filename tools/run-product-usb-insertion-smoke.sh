#!/bin/bash -p

set +x
set -euo pipefail
umask 077
original_arguments=("$@")
formal_requested=0
for argument in "${original_arguments[@]}"; do
  case "${argument}" in
    --serial|--device-slot|--expected-main-sha|--app-bundle|--sandboxed-app|--result-log)
      formal_requested=1
      ;;
  esac
done
if [[ "${formal_requested}" -eq 1 ]]; then
  for environment_name in $(builtin compgen -e); do
    case "${environment_name}" in
      GIT_PAGER|GIT_TERMINAL_PROMPT) ;;
      GIT_*)
        printf '%s\n' 'formal evidence rejects caller Git overrides.' >&2
        exit 1
        ;;
    esac
  done
  if [[ "${DROIDMATCH_USB_FORMAL_CLEAN:-}" != 1 || "$-" != *p* ]]; then
    script_path="${BASH_SOURCE[0]}"
    case "${script_path}" in
      /*) ;;
      *) script_path="$(builtin pwd -P)/${script_path}" ;;
    esac
    builtin exec /usr/bin/env -i \
      HOME=/var/empty TMPDIR=/private/tmp \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C \
      PYTHONDONTWRITEBYTECODE=1 \
      DROIDMATCH_USB_FORMAL_CLEAN=1 \
      /bin/bash --noprofile --norc -p \
      "${script_path}" \
      "${original_arguments[@]}"
  fi
  [[ "${HOME}" == /var/empty && "${TMPDIR}" == /private/tmp \
      && "${PATH}" == /usr/bin:/bin:/usr/sbin:/sbin \
      && "${LANG}" == C && "${LC_ALL}" == C \
      && "${PYTHONDONTWRITEBYTECODE}" == 1 ]] || exit 1
  while IFS= read -r environment_name; do
    case "${environment_name}" in
      DROIDMATCH_USB_FORMAL_CLEAN|HOME|LANG|LC_ALL|PATH|PWD|\
      PYTHONDONTWRITEBYTECODE|SHLVL|TMPDIR) ;;
      *)
        printf '%s\n' 'formal evidence environment is not isolated.' >&2
        exit 1
        ;;
    esac
  done < <(builtin compgen -e)
  while IFS= read -r inherited_function; do
    builtin unset -f "${inherited_function}"
  done < <(builtin compgen -A function)
fi
builtin unset CDPATH
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
hash -r

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
source "${repo_root}/tools/git-evidence-provenance.sh"
# shellcheck source=tools/product-usb-evidence-publication.sh
source "${repo_root}/tools/product-usb-evidence-publication.sh"

readonly evidence_profile="m1-product-usb-insertion-v3"
readonly product_bundle_id="app.droidmatch.mac"
readonly accessibility_identifier="app.droidmatch.discovery-device-card"
readonly formal_probe_pattern='^product_visible_matches=1 bundle_cdhash=([0-9a-f]{40}) dynamic_requirement_verified=true$'
readonly main_refresh_attempts=3
readonly main_refresh_interval_seconds=2
readonly device_identity_helper="${repo_root}/tools/product-usb-device-identity.py"

bundle_id="${product_bundle_id}"
expected_label=""
expected_main_sha=""
device_slot=""
serial=""
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
adb_bin=""
adb_toolchain_initial=""
adb_preflight_snapshot=""
adb_pre_signal_snapshot=""

[[ -z "${probe}" ]] || probe_override=1

usage() {
  cat <<'USAGE'
Measure attended physical USB insertion to visibility in the foreground Mac App.

Diagnostic usage:
  tools/run-product-usb-insertion-smoke.sh --expected-label <visible-device-name> [options]

Formal evidence usage:
  tools/run-product-usb-insertion-smoke.sh \
    --serial <adb-serial> \
    --device-slot <A|C|D> \
    --expected-main-sha <40-hex-origin-main-sha> \
    --app-bundle <DroidMatch.app> \
    --sandboxed-app \
    --result-log fixtures/product-usb-insertion/<UTC>-slot-<a|c|d>-<32hex-tag>.md

Options:
  --bundle-id <id>            Product bundle ID (default app.droidmatch.mac).
  --timeout-seconds <value>   Visibility gate in seconds (default 5).
  --poll-interval <value>     Accessibility polling interval (default 0.1).
  --countdown-seconds <n>     Arming countdown after Enter (default 3).
  --probe <path>              Prebuilt/fake visibility probe override; diagnostic only.
  --app-bundle <path>         Exact running release App bundle; required for a formal fixture.
  --sandboxed-app             Required formal sandbox bundle and sealed embedded adb.
  --serial <serial>           Reviewed ADB identity; required for a formal fixture, never logged raw.
  --device-slot <A|C|D>       Required matrix slot for a formal fixture.
  --expected-main-sha <sha>   Required clean current-main revision for a formal fixture.
  --result-log <path>         Opt-in formal fixture under fixtures/product-usb-insertion/.

The selected device must be physically disconnected and absent from the App.
Keep the current DroidMatch product App foreground-active. Enter arms a fixed
countdown; do not insert during that countdown. The runner checks absence again,
starts the monotonic clock before printing `INSERT NOW`, and stops only when the
identified product discovery card contains both the expected label and `ADB`.

Formal evidence derives the AX model component from the reviewed Slot A/C/D
device registry; `--expected-label` remains diagnostic-only. It requires the
sandbox product so App discovery and identity checks use the same reviewed signed
adb bytes and fixed socket; the helper executes a byte-identical private client
copy against the dedicated verified localhost server in no-auto-start remote-client
mode. Server-scope overrides are rejected. It rejects a
dirty/stale repository, a probe override, a running App
whose embedded source revision differs from clean current `origin/main`, a timing
configuration other than 3-second countdown / 5-second gate, and any staged log
that fails the dedicated privacy and schema validator. A private ADB snapshot
must prove that the selected serial was absent before the signal and was the only
new ready device afterward; its reviewed tag, model, and API are rechecked without
writing the raw serial. Physical insertion remains an attended operator attestation.

中文：目标设备开始前必须物理断开且不在 App 中显示，并保持当前产品 App 在前台。
回车只用于布防固定倒计时；倒计时期间不要插线。runner 会再次确认设备仍未出现，先启动
单调时钟，再打印 `INSERT NOW`；只有带固定标识的产品发现卡片同时包含指定名称和 `ADB`
才停止。正式证据还要求 clean current-main、运行 App 内嵌 SHA 完全匹配、固定 3 秒倒计时
和 5 秒门槛，并通过专用隐私/结构校验器。正式模式从受审查的 A/C/D 设备清单派生 AX
型号，要求所选 serial 在信号前不存在、信号后是唯一新增的 ready ADB 设备，并核对
型号/API；正式模式只接受 sandbox 产品。App 使用 resource seal 中受审查的签名后 adb，
runner 则通过固定 socket 以禁止自动启动的远端 client 模式执行逐字节相同的私有副本，
并核对专用 localhost server 进程；server scope 覆盖会被拒绝。物理插线仍由现场操作者
明确确认，原始 serial 不会写入日志。
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-id) bundle_id="${2:?missing value for --bundle-id}"; shift 2 ;;
    --expected-label) expected_label="${2:?missing value for --expected-label}"; shift 2 ;;
    --expected-main-sha) expected_main_sha="${2:?missing value for --expected-main-sha}"; shift 2 ;;
    --app-bundle) app_bundle="${2:?missing value for --app-bundle}"; shift 2 ;;
    --sandboxed-app) sandboxed_app=1; shift ;;
    --serial) serial="${2:?missing value for --serial}"; shift 2 ;;
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
    || -n "${serial}" || -n "${app_bundle}" || "${sandboxed_app}" -eq 1 ]]; then
  formal_evidence=1
  [[ -n "${result_log}" && -n "${app_bundle}" \
      && "${serial}" =~ ^[A-Za-z0-9._:-]+$ \
      && ${#serial} -ge 6 && ${#serial} -le 256 \
      && "${expected_main_sha}" =~ ^[0-9a-f]{40}$ \
      && "${device_slot}" =~ ^(A|C|D)$ \
      && "${sandboxed_app}" -eq 1 ]] || {
    printf '%s\n' 'formal evidence requires --sandboxed-app, --serial, --result-log, --app-bundle, --expected-main-sha, and Slot A/C/D.' >&2
    exit 2
  }
  [[ -z "${expected_label}" ]] || {
    printf '%s\n' 'formal evidence derives its visible label from the reviewed device registry; --expected-label is diagnostic-only.' >&2
    exit 2
  }
  droidmatch_git_override_environment_absent \
      && droidmatch_git_official_repository_contract "${repo_root}" || {
    printf '%s\n' 'formal evidence requires unredirected official Git provenance.' >&2
    exit 1
  }
  for override_name in \
    ADB_SERVER_SOCKET ADB_SERVER_PORT ANDROID_ADB_SERVER_ADDRESS \
    ANDROID_ADB_SERVER_PORT; do
    [[ -z "${!override_name+x}" ]] || {
      printf '%s\n' 'formal evidence rejects ADB server address/port overrides.' >&2
      exit 2
    }
  done
  [[ -f "${device_identity_helper}" && ! -L "${device_identity_helper}" ]] || {
    printf '%s\n' 'the reviewed product USB device identity helper is unavailable.' >&2
    exit 2
  }
  if ! selected_profile="$({
      python3 "${device_identity_helper}" profile \
        --slot "${device_slot}" --selected-serial "${serial}"
    } 2>/dev/null)"; then
    printf '%s\n' 'the selected device does not match the reviewed Slot A/C/D registry.' >&2
    exit 1
  fi
  profile_field() {
    local field="$1" count
    count="$(grep -c "^${field}=" <<<"${selected_profile}" || true)"
    [[ "${count}" == "1" ]] || return 1
    sed -n "s/^${field}=//p" <<<"${selected_profile}"
  }
  selected_registry_profile="$(profile_field registry_profile)" || exit 1
  selected_identity_tag="$(profile_field identity_tag)" || exit 1
  selected_manufacturer="$(profile_field manufacturer)" || exit 1
  selected_model="$(profile_field model)" || exit 1
  selected_android_api="$(profile_field android_api)" || exit 1
  expected_label="$(profile_field visible_label)" || exit 1
  [[ "${bundle_id}" == "${product_bundle_id}" \
      && "${timeout_seconds}" == "5" \
      && "${poll_interval}" == "0.1" \
      && "${countdown_seconds}" == "3" \
      && "${probe_override}" -eq 0 ]] || {
    printf '%s\n' 'formal evidence requires the product bundle, 5-second gate, 3-second countdown, and repository probe.' >&2
    exit 2
  }
  device_slot_lower="$(printf '%s' "${device_slot}" | tr '[:upper:]' '[:lower:]')"
  expected_result_pattern="^fixtures/product-usb-insertion/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z-slot-${device_slot_lower}-${selected_identity_tag}[.]md$"
  [[ "${result_log}" =~ ${expected_result_pattern} \
      && ! -e "${result_log}" && ! -L "${result_log}" \
      && ! -e "${result_log}.commit" && ! -L "${result_log}.commit" ]] || {
    printf '%s\n' 'formal result log must use the reviewed timestamp-slot-redacted-tag filename.' >&2
    exit 2
  }
  bash tools/check-product-usb-insertion-logs.sh \
    --directory "$(dirname "${result_log}")" >/dev/null 2>&1 || {
    printf '%s\n' 'formal evidence requires a clean product USB fixture directory.' >&2
    exit 1
  }

  droidmatch_refresh_official_main \
    "${repo_root}" "${main_refresh_attempts}" "${main_refresh_interval_seconds}" || {
    printf '%s\n' 'could not refresh origin/main before the attended run.' >&2
    exit 1
  }
  head_sha="$(droidmatch_git_head "${repo_root}")"
  origin_main_sha="$(droidmatch_evidence_git "${repo_root}" \
    rev-parse refs/remotes/origin/main 2>/dev/null)"
  pre_run_git_status="$(droidmatch_git_status "${repo_root}")" || {
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
    bundle_check_args+=(--sandboxed --evidence-ready)
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
  bundle_evidence_build="$(plutil -extract DroidMatchEvidenceBuild raw -o - \
    "${app_bundle}/Contents/Info.plist" 2>/dev/null || true)"
  [[ "${bundle_revision}" == "${expected_main_sha}" \
      && "${bundle_dirty}" == "false" \
      && "${bundle_configuration}" == "release" \
      && "${bundle_evidence_build}" == "true" ]] || {
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
else
  [[ -n "${bundle_id}" && "${expected_label}" =~ [^[:space:]] \
      && "${#expected_label}" -le 80 \
      && "${expected_label}" != *$'\n'* ]] || {
    printf '%s\n' '--expected-label and a non-empty bundle ID are required; label length is limited to 80.' >&2
    exit 2
  }
  expected_label="$(printf '%s' "${expected_label}" \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
fi

resolve_product_adb() {
  local candidate="${app_bundle}/Contents/Resources/platform-tools/adb"
  [[ "${sandboxed_app}" -eq 1 && -x "${candidate}" ]] || return 1
  adb_bin="$(cd "$(dirname "${candidate}")" && pwd -P)/$(basename "${candidate}")"
  [[ "${adb_bin}" == "${app_bundle}/Contents/Resources/platform-tools/adb" \
      && -x "${adb_bin}" ]]
}

if [[ "${formal_evidence}" -eq 1 ]]; then
  resolve_product_adb || {
    printf '%s\n' 'formal evidence could not resolve the product ADB executable.' >&2
    exit 2
  }
fi

verify_adb_toolchain_unchanged() {
  local observed
  observed="$(python3 "${device_identity_helper}" toolchain --adb "${adb_bin}" 2>/dev/null)" \
    || return 1
  [[ -z "${adb_toolchain_initial}" || "${observed}" == "${adb_toolchain_initial}" ]] \
    || return 1
  printf '%s' "${observed}"
}

command -v perl >/dev/null 2>&1 || {
  printf '%s\n' 'Perl Time::HiRes is required for a cross-process monotonic clock.' >&2
  exit 2
}
monotonic_ns() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
    -e 'printf "%.0f", clock_gettime(CLOCK_MONOTONIC) * 1000000000'
}

cleanup_private_state() {
  [[ -n "${work}" ]] || return 0
  case "${work}" in
    /private/tmp/droidmatch-product-usb.*|/tmp/droidmatch-product-usb.*) ;;
    *) return 1 ;;
  esac
  /bin/rm -rf -- "${work}" >/dev/null 2>&1 || return 1
  [[ ! -e "${work}" && ! -L "${work}" ]] || return 1
  work=""
}
cleanup() {
  local status=$?
  trap - EXIT
  if ! cleanup_private_state; then
    printf '%s\n' 'private product USB state could not be removed; evidence is refused.' >&2
    printf '%s\n' '无法移除产品 USB 私有状态；拒绝生成证据。' >&2
    exit 1
  fi
  exit "${status}"
}
trap cleanup EXIT

if [[ -z "${probe}" ]]; then
  [[ -x /usr/bin/xcrun ]] || {
    printf '%s\n' 'xcrun is required to build the product-visible probe.' >&2
    exit 2
  }
  private_tmp_root="/private/tmp"
  [[ -d "${private_tmp_root}" && ! -L "${private_tmp_root}" ]] || private_tmp_root="/tmp"
  work="$(/usr/bin/mktemp -d "${private_tmp_root}/droidmatch-product-usb.XXXXXX")"
  /bin/chmod 700 "${work}"
  probe="${work}/product-device-visible"
  /usr/bin/env -i HOME=/var/empty TMPDIR="${work}" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C \
    /usr/bin/xcrun swiftc \
    mac/Sources/DroidMatchApp/ProductAccessibilityIdentifiers.swift \
    tools/product-device-visibility-policy.swift \
    tools/product-device-visible.swift \
    -framework AppKit -framework ApplicationServices -framework Security -o "${probe}"
fi
[[ -x "${probe}" ]] || {
  printf '%s\n' 'visibility probe is not executable.' >&2
  exit 2
}

if [[ "${formal_evidence}" -eq 1 ]]; then
  if ! adb_toolchain_initial="$(verify_adb_toolchain_unchanged)"; then
    printf '%s\n' 'formal evidence requires the reviewed product ADB server to be active.' >&2
    exit 1
  fi
  adb_toolchain_field() {
    local field="$1" count
    count="$(grep -c "^${field}=" <<<"${adb_toolchain_initial}" || true)"
    [[ "${count}" == "1" ]] || return 1
    sed -n "s/^${field}=//p" <<<"${adb_toolchain_initial}"
  }
  adb_registry_profile="$(adb_toolchain_field adb_registry_profile)" || exit 1
  adb_executable_sha256="$(adb_toolchain_field adb_executable_sha256)" || exit 1
  adb_version="$(adb_toolchain_field adb_version)" || exit 1
  adb_build="$(adb_toolchain_field adb_build)" || exit 1
  adb_server_socket="$(adb_toolchain_field adb_server_socket)" || exit 1
  adb_server_pid="$(adb_toolchain_field adb_server_pid)" || exit 1
  adb_preflight_snapshot="${work}/adb-preflight.json"
  if ! python3 "${device_identity_helper}" capture \
      --adb "${adb_bin}" \
      --selected-serial "${serial}" \
      --output "${adb_preflight_snapshot}" >/dev/null 2>&1; then
    printf '%s\n' 'formal evidence requires the selected ADB device to be physically absent before arming.' >&2
    exit 1
  fi
fi

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

if [[ "${formal_evidence}" -eq 1 ]]; then
  verify_adb_toolchain_unchanged >/dev/null || {
    printf '%s\n' 'the product ADB server changed before INSERT NOW.' >&2
    exit 1
  }
  adb_pre_signal_snapshot="${work}/adb-pre-signal.json"
  if ! python3 "${device_identity_helper}" capture \
      --adb "${adb_bin}" \
      --selected-serial "${serial}" \
      --same-as "${adb_preflight_snapshot}" \
      --output "${adb_pre_signal_snapshot}" >/dev/null 2>&1; then
    printf '%s\n' 'the ADB inventory changed before INSERT NOW; measurement refused.' >&2
    exit 1
  fi
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
  if ! selected_identity="$({
      python3 "${device_identity_helper}" verify \
        --adb "${adb_bin}" \
        --slot "${device_slot}" \
        --selected-serial "${serial}" \
        --before "${adb_pre_signal_snapshot}"
    } 2>/dev/null)"; then
    printf '%s\n' 'the product-visible card could not be cross-checked against the reviewed ADB profile.' >&2
    exit 1
  fi
  verify_adb_toolchain_unchanged >/dev/null || {
    printf '%s\n' 'the product ADB server changed after the timed observation.' >&2
    exit 1
  }
  identity_field() {
    local field="$1" count
    count="$(grep -c "^${field}=" <<<"${selected_identity}" || true)"
    [[ "${count}" == "1" ]] || return 1
    sed -n "s/^${field}=//p" <<<"${selected_identity}"
  }
  [[ "$(identity_field registry_profile)" == "${selected_registry_profile}" \
      && "$(identity_field identity_tag)" == "${selected_identity_tag}" \
      && "$(identity_field manufacturer)" == "${selected_manufacturer}" \
      && "$(identity_field model)" == "${selected_model}" \
      && "$(identity_field android_api)" == "${selected_android_api}" \
      && "$(identity_field visible_label)" == "${expected_label}" \
      && "$(identity_field adb_identity_verified)" == "true" \
      && "$(identity_field adb_insertion_delta_verified)" == "true" ]] || {
    printf '%s\n' 'the selected-device identity proof was malformed or inconsistent.' >&2
    exit 1
  }
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
  post_bundle_evidence_build="$(plutil -extract DroidMatchEvidenceBuild raw -o - \
    "${app_bundle}/Contents/Info.plist" 2>/dev/null || true)"
  post_bundle_executable_sha256="$(shasum -a 256 \
    "${app_bundle}/Contents/MacOS/DroidMatch" 2>/dev/null | awk '{print $1}')"
  [[ "${post_bundle_revision}" == "${bundle_revision}" \
      && "${post_bundle_dirty}" == "${bundle_dirty}" \
      && "${post_bundle_configuration}" == "${bundle_configuration}" \
      && "${post_bundle_evidence_build}" == "${bundle_evidence_build}" \
      && "${post_bundle_executable_sha256}" == "${bundle_executable_sha256}" ]] || {
    printf '%s\n' 'product App artifact provenance changed during the attended run.' >&2
    exit 1
  }
  droidmatch_git_override_environment_absent \
      && droidmatch_git_official_repository_contract "${repo_root}" \
      && droidmatch_refresh_official_main \
        "${repo_root}" "${main_refresh_attempts}" "${main_refresh_interval_seconds}" || {
    printf '%s\n' 'could not refresh origin/main after the attended run.' >&2
    exit 1
  }
  post_head_sha="$(droidmatch_git_head "${repo_root}")"
  post_origin_main_sha="$(droidmatch_evidence_git "${repo_root}" \
    rev-parse refs/remotes/origin/main 2>/dev/null)"
  post_run_git_status="$(droidmatch_git_status "${repo_root}")" || {
    printf '%s\n' 'could not verify repository cleanliness after the attended run.' >&2
    exit 1
  }
  [[ "${post_head_sha}" == "${expected_main_sha}" \
      && "${post_origin_main_sha}" == "${expected_main_sha}" \
      && -z "${post_run_git_status}" ]] || {
    printf '%s\n' 'repository provenance changed during the attended run.' >&2
    exit 1
  }
  if ! post_selected_identity="$({
      python3 "${device_identity_helper}" verify \
        --adb "${adb_bin}" \
        --slot "${device_slot}" \
        --selected-serial "${serial}" \
        --before "${adb_pre_signal_snapshot}"
    } 2>/dev/null)" \
      || [[ "${post_selected_identity}" != "${selected_identity}" ]]; then
    printf '%s\n' 'selected-device identity changed before publication.' >&2
    exit 1
  fi
  verify_adb_toolchain_unchanged >/dev/null || {
    printf '%s\n' 'the product ADB server changed before publication.' >&2
    exit 1
  }
  cleanup_private_state || {
    printf '%s\n' 'private product USB state could not be removed before publication.' >&2
    printf '%s\n' '发布前无法移除产品 USB 私有状态。' >&2
    exit 1
  }

  mkdir -p "$(dirname "${result_log}")" 2>/dev/null || {
    printf '%s\n' 'could not prepare the product USB evidence directory.' >&2
    exit 1
  }
  # The helper creates the persistent companion through a pinned directory FD
  # with O_EXCL/O_NOFOLLOW; the shell never redirects into an evidence path.
  # 中文：helper 通过已固定目录 FD 与 O_EXCL/O_NOFOLLOW 创建持久伴随文件；
  # shell 绝不重定向到证据路径。
  staged_log="${result_log}.commit"
  if ! companion_digest="$(
    {
      printf '# M1 Product USB Insertion Evidence\n\n'
      printf 'status: passed\n'
      printf 'evidence profile: %s\n' "${evidence_profile}"
      printf 'profile result: passed\n'
      printf 'date: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')"
      printf 'selected device registry: %s\n' "${selected_registry_profile}"
      printf 'device slot: %s\n' "${device_slot}"
      printf 'device identity tag: %s\n' "${selected_identity_tag}"
      printf 'device manufacturer: %s\n' "${selected_manufacturer}"
      printf 'device model: %s\n' "${selected_model}"
      printf 'device android api: %s\n' "${selected_android_api}"
      printf 'device label: %s\n' "${expected_label}"
      printf 'adb selected absent before arming: true\n'
      printf 'adb inventory unchanged before signal: true\n'
      printf 'adb insertion delta verified: true\n'
      printf 'adb identity verified: true\n'
      printf 'identity reverified before publication: true\n'
      printf 'adb toolchain registry: %s\n' "${adb_registry_profile}"
      printf 'adb executable sha256: %s\n' "${adb_executable_sha256}"
      printf 'adb version: %s\n' "${adb_version}"
      printf 'adb build: %s\n' "${adb_build}"
      printf 'adb server socket: %s\n' "${adb_server_socket}"
      printf 'adb server stable: true\n'
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
    } | create_product_usb_commit_companion \
        "${result_log}" \
        "tools/check-product-usb-insertion-logs.sh"
  )"; then
    printf '%s\n' 'could not safely create the product USB commit companion; the fixture directory may now be blocked and must be inspected before retry.' >&2
    printf '%s\n' '无法安全创建产品 USB commit 伴随文件；fixture 目录可能已被阻断，重试前必须先检查。' >&2
    exit 1
  fi
  [[ "${companion_digest}" =~ ^[0-9a-f]{64}$ ]] || {
    printf '%s\n' 'product USB commit companion returned an invalid digest; publication refused.' >&2
    exit 1
  }
  set +e
  publish_product_usb_staged_log \
    "${staged_log}" \
    "${result_log}" \
    "tools/check-product-usb-insertion-logs.sh" \
    "${companion_digest}"
  publication_status=$?
  set -e
  if [[ "${publication_status}" -eq "${PRODUCT_USB_PUBLICATION_UNCERTAIN_STATUS}" ]]; then
    if [[ -f "${staged_log}" && ! -L "${staged_log}" \
        && -f "${result_log}" && ! -L "${result_log}" \
        && -s "${staged_log}" && -s "${result_log}" ]] \
        && cmp -s "${staged_log}" "${result_log}" \
        && bash tools/check-product-usb-insertion-logs.sh \
          --log "${result_log}" >/dev/null 2>&1; then
      printf '%s\n' 'product USB publication is uncertain after result creation, but a complete validated pair exists; do not delete or rerun automatically, and inspect the pair before counting it as evidence.' >&2
      printf '%s\n' '产品 USB 发布在创建结果后状态不确定，但已存在完整验证文件对；不得自动删除或重试，计入证据前必须先检查。' >&2
    else
      printf '%s\n' 'product USB publication is uncertain and left a blocked orphan/mismatch; do not delete or rerun automatically, and inspect the fixture directory.' >&2
      printf '%s\n' '产品 USB 发布状态不确定并留下被门禁阻断的孤立/不一致项；不得自动删除或重试，必须检查 fixture 目录。' >&2
    fi
    exit "${PRODUCT_USB_PUBLICATION_UNCERTAIN_STATUS}"
  elif [[ "${publication_status}" -ne 0 ]]; then
    printf '%s\n' 'could not complete no-clobber publication; the commit companion is retained and must be inspected before retry.' >&2
    printf '%s\n' '无法完成 no-clobber 发布；commit 伴随文件已保留，重试前必须先检查。' >&2
    exit "${publication_status}"
  fi
fi

printf 'product_usb_insertion_elapsed_ms=%s threshold_ms=%s label=%q boundary=monotonic-before-insert-now\n' \
  "${elapsed_ms}" "${threshold_ms}" "${expected_label}"
printf '产品 USB 插入可见时延=%s 毫秒（门槛 %s 毫秒）。\n' \
  "${elapsed_ms}" "${threshold_ms}"
if [[ "${formal_evidence}" -eq 1 ]]; then
  printf 'Product USB insertion evidence written: %s\n' "${result_log}"
fi
