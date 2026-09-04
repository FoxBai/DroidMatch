#!/usr/bin/env bash

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
strict_probe_output_regex='^product_visible_matches=1 bundle_cdhash=([0-9a-f]{40}) dynamic_requirement_verified=true$'
source "${repo_root}/tools/product-usb-evidence-publication.sh"
if [[ "${PRODUCT_USB_PUBLICATION_UNCERTAIN_STATUS}" -ne 3 ]]; then
  printf '%s\n' 'publication uncertainty status drifted.' >&2
  exit 1
fi
work="$(mktemp -d)"
provenance_residue=""
cleanup() {
  if [[ -n "${provenance_residue}" ]]; then
    rm -f "${provenance_residue}" >/dev/null 2>&1 || true
  fi
  rm -rf "${work}"
}
trap cleanup EXIT
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
if [[ "$(grep -c 'droidmatch_refresh_official_main' \
    "${repo_root}/tools/run-product-usb-insertion-smoke.sh")" -ne 2 ]]; then
  printf '%s\n' 'formal runner does not refresh official main at both boundaries.' >&2
  exit 1
fi
grep -Fq 'droidmatch_refresh_official_main()' \
  "${repo_root}/tools/git-evidence-provenance.sh"

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
if [[ "$(cat "${work}/calls")" != '3' ]]; then
  printf '%s\n' 'runner sampled the product visibility probe more than once per poll.' >&2
  exit 1
fi

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

mkdir -p "${work}/PathCheck.app"
provenance_residue="${repo_root}/tools/.droidmatch-product-usb-provenance-$$-${RANDOM}.dmg"
if [[ -e "${provenance_residue}" || -L "${provenance_residue}" ]]; then
  printf '%s\n' 'offline provenance residue path already exists.' >&2
  exit 1
fi
printf '%s\n' 'ignored product input' >"${provenance_residue}"
set +e
formal_admission_output="$({
  /bin/bash "${repo_root}/tools/run-product-usb-insertion-smoke.sh" \
    --serial 'TEST-SERIAL-123' \
    --device-slot C \
    --expected-main-sha 1111111111111111111111111111111111111111 \
    --app-bundle "${work}/PathCheck.app" \
    --sandboxed-app \
    --result-log fixtures/product-usb-insertion/2026-08-13T00-00-00Z-slot-c-11111111111111111111111111111111.md
} 2>&1)"
formal_admission_status=$?
set -e
if [[ "${formal_admission_status}" -ne 1 ]]; then
  printf '%s\n' 'formal runner did not reject the explicit provenance residue.' >&2
  exit 1
fi
grep -Fq 'formal evidence requires unredirected official Git provenance.' \
  <<<"${formal_admission_output}"
if [[ "${formal_admission_output}" == *'TEST-SERIAL-123'* ]]; then
  printf '%s\n' 'formal provenance refusal disclosed the raw test serial.' >&2
  exit 1
fi

mkdir -p "${work}/alternate/tools"
cat >"${work}/alternate/tools/run-product-usb-insertion-smoke.sh" <<'FAKE_RUNNER'
#!/bin/bash
: >"${ATTACK_MARKER:?}"
FAKE_RUNNER
chmod +x "${work}/alternate/tools/run-product-usb-insertion-smoke.sh"
set +e
(
  cd "${repo_root}"
  CDPATH="${work}/alternate" ATTACK_MARKER="${work}/redirected" \
    /bin/bash tools/run-product-usb-insertion-smoke.sh \
      --serial 'TEST-SERIAL-123' --device-slot C \
      --expected-main-sha 1111111111111111111111111111111111111111 \
      --app-bundle "${work}/PathCheck.app" --sandboxed-app \
      --result-log fixtures/product-usb-insertion/2026-08-13T00-00-00Z-slot-c-11111111111111111111111111111111.md \
      >/dev/null 2>&1
)
cdpath_admission_status=$?
set -e
if [[ "${cdpath_admission_status}" -ne 1 || -e "${work}/redirected" ]]; then
  printf '%s\n' 'formal runner allowed CDPATH to redirect its clean re-exec.' >&2
  exit 1
fi

set +e
/usr/bin/env -i \
  HOME=/var/empty TMPDIR=/private/tmp \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C \
  PYTHONDONTWRITEBYTECODE=0 DROIDMATCH_USB_FORMAL_CLEAN=1 \
  /bin/bash --noprofile --norc -p \
    "${repo_root}/tools/run-product-usb-insertion-smoke.sh" \
    --serial 'TEST-SERIAL-123' --device-slot C \
    --expected-main-sha 1111111111111111111111111111111111111111 \
    --app-bundle "${work}/PathCheck.app" --sandboxed-app \
    --result-log fixtures/product-usb-insertion/2026-08-13T00-00-00Z-slot-c-11111111111111111111111111111111.md \
    >/dev/null 2>&1
unisolated_runner_status=$?
set -e
if [[ "${unisolated_runner_status}" -ne 1 ]]; then
  printf '%s\n' 'formal runner accepted a caller-forged clean marker.' >&2
  exit 1
fi

rm -f "${provenance_residue}"
provenance_residue=""

start_line="$(grep -n '^start_ns=' "${repo_root}/tools/run-product-usb-insertion-smoke.sh" | cut -d: -f1)"
signal_line="$(grep -n "^printf 'INSERT NOW:" "${repo_root}/tools/run-product-usb-insertion-smoke.sh" | cut -d: -f1)"
if [[ ! "${start_line}" =~ ^[0-9]+$ || ! "${signal_line}" =~ ^[0-9]+$ ]] \
    || (( start_line >= signal_line )); then
  printf '%s\n' 'timing must start before the attended insertion signal.' >&2
  exit 1
fi
directory_gate_line="$(grep -n '^  bash tools/check-product-usb-insertion-logs[.]sh' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh" | cut -d: -f1)"
first_refresh_line="$(grep -n '^  droidmatch_refresh_official_main' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh" | head -n 1 | cut -d: -f1)"
tty_line="$(grep -n 'exec 9<>/dev/tty' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh" | cut -d: -f1)"
if [[ ! "${directory_gate_line}" =~ ^[0-9]+$ \
    || ! "${first_refresh_line}" =~ ^[0-9]+$ \
    || ! "${tty_line}" =~ ^[0-9]+$ ]] \
    || (( directory_gate_line >= first_refresh_line \
      || directory_gate_line >= tty_line )); then
  printf '%s\n' 'directory preflight must precede Git and attended actions.' >&2
  exit 1
fi
companion_line="$(grep -n '^  staged_log="${result_log}[.]commit"$' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh" | cut -d: -f1)"
publication_line="$(grep -n '^  publish_product_usb_staged_log' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh" | cut -d: -f1)"
if [[ ! "${companion_line}" =~ ^[0-9]+$ \
    || ! "${publication_line}" =~ ^[0-9]+$ ]] \
    || (( companion_line >= publication_line )); then
  printf '%s\n' 'commit companion must be created before publication.' >&2
  exit 1
fi
grep -Fq '.accessibilityIdentifier(ProductAccessibilityIdentifiers.discoveryDeviceCard)' \
  "${repo_root}/mac/Sources/DroidMatchApp/DeviceDashboardView.swift"
grep -Fq 'exec 9<>/dev/tty' "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq 'INSERTED ${attestation_challenge}' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq '&& "${probe_override}" -eq 0 ]]' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq 'expected_result_pattern="^fixtures/product-usb-insertion/' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq 'source "${repo_root}/tools/product-usb-evidence-publication.sh"' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq 'publish_product_usb_staged_log' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq 'staged_log="${result_log}.commit"' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq '} | create_product_usb_commit_companion' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq '[[ "${companion_digest}" =~ ^[0-9a-f]{64}$ ]]' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq '"${companion_digest}"' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
if grep -Fq 'set -o noclobber' \
    "${repo_root}/tools/run-product-usb-insertion-smoke.sh"; then
  printf '%s\n' 'formal companion creation must not use Bash noclobber redirection.' >&2
  exit 1
fi
if grep -Fq 'rm -f "${staged_log}"' \
    "${repo_root}/tools/run-product-usb-insertion-smoke.sh"; then
  printf '%s\n' 'formal publication must never delete a companion by pathname.' >&2
  exit 1
fi
grep -Fq 'if [[ "${publication_status}" -eq "${PRODUCT_USB_PUBLICATION_UNCERTAIN_STATUS}" ]]' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq 'exit "${PRODUCT_USB_PUBLICATION_UNCERTAIN_STATUS}"' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq 'do not delete or rerun automatically' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq '&& ! -e "${result_log}" && ! -L "${result_log}"' \
  "${repo_root}/tools/run-product-usb-insertion-smoke.sh"
grep -Fq '&& ! -e "${result_log}.commit" && ! -L "${result_log}.commit"' \
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

printf 'product USB insertion smoke offline test passed.\n'
