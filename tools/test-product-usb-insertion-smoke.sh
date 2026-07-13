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
