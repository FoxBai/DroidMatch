#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
strict_probe_output_regex='^product_visible_matches=1 bundle_cdhash=([0-9a-f]{40}) dynamic_requirement_verified=true$'
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf '0\n' >"${work}/calls"

grep -Fq "readonly formal_probe_pattern='${strict_probe_output_regex}'" \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"

[[ 'product_visible_matches=1 bundle_cdhash=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb dynamic_requirement_verified=true' \
    =~ ${strict_probe_output_regex} ]] || {
  printf '%s\n' 'formal probe output policy rejected the exact success line' >&2
  exit 1
}
if [[ $'product_visible_matches=1\nbundle_cdhash=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\ndynamic_requirement_verified=true' \
    =~ ${strict_probe_output_regex} ]]; then
  printf '%s\n' 'formal probe output policy accepted multiline output' >&2
  exit 1
fi

# Both formal provenance reads use one directly tested read-only retry helper;
# neither the probe nor the physical attestation has a test override.
# 中文：正式流程前后共用同一个直接测试的只读重试函数；probe 与人工确认均无测试后门。
[[ "$(grep -c 'refresh_origin_branch_with_retry' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh")" -eq 2 ]]
refresh_bin="${work}/refresh-bin"
refresh_state="${work}/refresh-state"
mkdir -p "${refresh_bin}" "${refresh_state}"
cat >"${refresh_bin}/git" <<'FAKE_REFRESH_GIT'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'fetch --quiet origin refs/heads/main:refs/remotes/origin/main' ]] || exit 90
count=0
[[ ! -f "${REFRESH_STATE:?}/count" ]] || read -r count <"${REFRESH_STATE}/count"
count=$((count + 1))
printf '%s\n' "${count}" >"${REFRESH_STATE}/count"
(( count > ${REFRESH_FAIL_UNTIL:-0} )) || exit 91
FAKE_REFRESH_GIT
cat >"${refresh_bin}/sleep" <<'FAKE_REFRESH_SLEEP'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == 2 ]]
FAKE_REFRESH_SLEEP
chmod +x "${refresh_bin}/git" "${refresh_bin}/sleep"

refresh_output="$(
  PATH="${refresh_bin}:${PATH}" REFRESH_STATE="${refresh_state}" REFRESH_FAIL_UNTIL=1 \
    bash -c 'source "$1"; refresh_origin_branch_with_retry origin main 3 2' \
      _ "${repo_root}/tools/git-main-read.sh" 2>&1
)"
grep -q 'origin/main refresh failed; retrying (1/3)' <<<"${refresh_output}"
[[ "$(<"${refresh_state}/count")" -eq 2 ]]

rm -f "${refresh_state}/count"
set +e
unreadable_refresh_output="$(
  PATH="${refresh_bin}:${PATH}" REFRESH_STATE="${refresh_state}" REFRESH_FAIL_UNTIL=3 \
    bash -c 'source "$1"; refresh_origin_branch_with_retry origin main 3 2' \
      _ "${repo_root}/tools/git-main-read.sh" 2>&1
)"
unreadable_refresh_status=$?
set -e
[[ "${unreadable_refresh_status}" -eq 1 ]]
grep -q 'origin/main refresh failed; retrying (2/3)' \
  <<<"${unreadable_refresh_output}"
[[ "$(<"${refresh_state}/count")" -eq 3 ]]

cat >"${work}/probe" <<'FAKE_PROBE'
#!/usr/bin/env bash
set -euo pipefail
work="${FAKE_WORK:?}"
calls="$(cat "${work}/calls")"
calls=$((calls + 1))
printf '%s\n' "${calls}" >"${work}/calls"
if [[ "${FAKE_MODE:-normal}" == early && "${calls}" -ge 2 ]]; then
  exit 0
fi
if [[ "${FAKE_MODE:-normal}" == slow && "${calls}" -ge 3 ]]; then
  sleep 0.05
  exit 0
fi
if [[ "${FAKE_MODE:-normal}" == pulse ]]; then
  [[ "${calls}" -eq 3 ]] && exit 0
  exit 1
fi
(( calls >= 4 )) && exit 0
exit 1
FAKE_PROBE
chmod +x "${work}/probe"

output="$(printf '\n' | FAKE_WORK="${work}" \
  bash "${repo_root}/tools/run-product-usb-insertion-smoke.sh" \
    --expected-label 'MEIZU M20' --timeout-seconds 2 --poll-interval 0.01 \
    --countdown-seconds 0 \
    --probe "${work}/probe")"

grep -q 'READY: press Enter to arm' <<<"${output}"
grep -q '准备完成' <<<"${output}"
grep -q 'INSERT NOW:' <<<"${output}"
grep -q 'product_usb_insertion_elapsed_ms=' <<<"${output}"
grep -q 'threshold_ms=2000' <<<"${output}"
grep -q 'label=MEIZU\\ M20' <<<"${output}"
grep -q 'boundary=monotonic-before-insert-now' <<<"${output}"

# One poll is one observation. A second probe in the same iteration would
# overwrite this single successful pulse and falsify the attended timing.
# 中文：每轮轮询只能采样一次；同轮二次 probe 会覆盖短暂成功并污染人工时延。
printf '0\n' >"${work}/calls"
pulse_output="$(printf '\n' | FAKE_WORK="${work}" FAKE_MODE=pulse \
  bash "${repo_root}/tools/run-product-usb-insertion-smoke.sh" \
    --expected-label 'MEIZU M20' --timeout-seconds 2 --poll-interval 0.01 \
    --countdown-seconds 0 \
    --probe "${work}/probe")"
grep -q 'product_usb_insertion_elapsed_ms=' <<<"${pulse_output}"
[[ "$(cat "${work}/calls")" == '3' ]]

printf '4\n' >"${work}/calls"
if printf '\n' | FAKE_WORK="${work}" \
  bash "${repo_root}/tools/run-product-usb-insertion-smoke.sh" \
    --expected-label 'MEIZU M20' --timeout-seconds 2 --poll-interval 0.01 \
    --countdown-seconds 0 \
    --probe "${work}/probe" >/dev/null 2>&1; then
  printf '%s\n' 'runner accepted a label that was already visible.' >&2
  exit 1
fi

printf '0\n' >"${work}/calls"
if printf '\n' | FAKE_WORK="${work}" FAKE_MODE=early \
  bash "${repo_root}/tools/run-product-usb-insertion-smoke.sh" \
    --expected-label 'MEIZU M20' --timeout-seconds 2 --poll-interval 0.01 \
    --countdown-seconds 0 \
    --probe "${work}/probe" >/dev/null 2>&1; then
  printf '%s\n' 'runner accepted insertion before the INSERT NOW boundary.' >&2
  exit 1
fi

printf '0\n' >"${work}/calls"
if printf '\n' | FAKE_WORK="${work}" FAKE_MODE=slow \
  bash "${repo_root}/tools/run-product-usb-insertion-smoke.sh" \
    --expected-label 'MEIZU M20' --timeout-seconds 0.01 --poll-interval 0.001 \
    --countdown-seconds 0 \
    --probe "${work}/probe" >/dev/null 2>&1; then
  printf '%s\n' 'runner accepted a visible result returned after the time gate.' >&2
  exit 1
fi

if printf '\n' | FAKE_WORK="${work}" \
  bash "${repo_root}/tools/run-product-usb-insertion-smoke.sh" \
    --expected-label 'MEIZU M20' \
    --device-slot C \
    --expected-main-sha 1111111111111111111111111111111111111111 \
    --result-log fixtures/product-usb-insertion/offline-invalid.md \
    --probe "${work}/probe" >/dev/null 2>&1; then
  printf '%s\n' 'formal evidence accepted a probe override.' >&2
  exit 1
fi

start_line="$(grep -n '^start_ns=' "${repo_root}/tools/run-product-usb-insertion-smoke.sh" | cut -d: -f1)"
signal_line="$(grep -n "^printf 'INSERT NOW:" "${repo_root}/tools/run-product-usb-insertion-smoke.sh" | cut -d: -f1)"
[[ "${start_line}" =~ ^[0-9]+$ && "${signal_line}" =~ ^[0-9]+$ ]]
(( start_line < signal_line ))
grep -Fq '.accessibilityIdentifier(ProductAccessibilityIdentifiers.discoveryDeviceCard)' \
  "${repo_root}/mac/Sources/DroidMatchApp/DeviceDashboardView.swift"
grep -Fq 'exec 9<>/dev/tty' "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq 'INSERTED ${attestation_challenge}' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq 'source "${repo_root}/tools/product-usb-evidence-publication.sh"' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq 'publish_product_usb_staged_log' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq '&& ! -e "${result_log}" && ! -L "${result_log}"' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq 'AXIsProcessTrustedWithOptions(options)' \
  "${repo_root}/tools/product-device-visible.swift"
grep -Fq 'kAXTrustedCheckOptionPrompt.takeUnretainedValue()' \
  "${repo_root}/tools/product-device-visible.swift"
grep -Fq 'ChatGPT for Codex Desktop or Terminal' \
  "${repo_root}/tools/product-device-visible.swift"
if grep -Fq 'AXMakeProcessTrusted' "${repo_root}/tools/product-device-visible.swift"; then
  printf '%s\n' 'product visibility probe must not attempt privileged TCC mutation.' >&2
  exit 1
fi

# A silent git-status failure must never be interpreted as a clean repository by
# either the formal attended runner or the product bundle provenance builder.
fake_bin="${work}/fake-bin"
mkdir -p "${fake_bin}" "${work}/Fake.app"
cat >"${fake_bin}/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail
joined="$*"
case "${joined}" in
  *'fetch'*) exit 0 ;;
  *'rev-parse HEAD'*) printf '%s\n' '1111111111111111111111111111111111111111' ;;
  *'rev-parse refs/remotes/origin/main'*) printf '%s\n' '1111111111111111111111111111111111111111' ;;
  *'status --porcelain=v1 --untracked-files=all'*) exit 42 ;;
  *) exit 43 ;;
esac
FAKE_GIT
chmod +x "${fake_bin}/git"

status_failure_log="fixtures/product-usb-insertion/offline-status-failure.md"
if PATH="${fake_bin}:${PATH}" \
  bash "${repo_root}/tools/run-product-usb-insertion-smoke.sh" \
    --expected-label 'MEIZU M20' \
    --device-slot C \
    --expected-main-sha 1111111111111111111111111111111111111111 \
    --app-bundle "${work}/Fake.app" \
    --result-log "${status_failure_log}" >/dev/null 2>&1; then
  printf '%s\n' 'formal runner treated a failed git status as clean.' >&2
  exit 1
fi
[[ ! -e "${repo_root}/${status_failure_log}" ]]

if PATH="${fake_bin}:${PATH}" \
  bash "${repo_root}/tools/build-mac-app.sh" \
    --configuration release \
    --output "${work}/ShouldNotBuild.app" >/dev/null 2>&1; then
  printf '%s\n' 'product builder treated a failed git status as clean.' >&2
  exit 1
fi
[[ ! -e "${work}/ShouldNotBuild.app" ]]

printf 'product USB insertion smoke offline test passed.\n'
