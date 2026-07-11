#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
printf '0\n' >"${work}/calls"

cat >"${work}/probe" <<'FAKE_PROBE'
#!/usr/bin/env bash
set -euo pipefail
work="${FAKE_WORK:?}"
calls="$(cat "${work}/calls")"
calls=$((calls + 1))
printf '%s\n' "${calls}" >"${work}/calls"
if [[ "${FAKE_MODE:-normal}" == slow && "${calls}" -ge 2 ]]; then
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
    --probe "${work}/probe")"

grep -q 'READY: press Enter' <<<"${output}"
grep -q '准备完成' <<<"${output}"
grep -q 'product_usb_insertion_elapsed_ms=' <<<"${output}"
grep -q 'threshold_ms=2000' <<<"${output}"
grep -q 'label=MEIZU\\ M20' <<<"${output}"

printf '4\n' >"${work}/calls"
if printf '\n' | FAKE_WORK="${work}" \
  bash "${repo_root}/tools/run-product-usb-insertion-smoke.sh" \
    --expected-label 'MEIZU M20' --timeout-seconds 2 --poll-interval 0.01 \
    --probe "${work}/probe" >/dev/null 2>&1; then
  printf '%s\n' 'runner accepted a label that was already visible.' >&2
  exit 1
fi

printf '0\n' >"${work}/calls"
if printf '\n' | FAKE_WORK="${work}" FAKE_MODE=slow \
  bash "${repo_root}/tools/run-product-usb-insertion-smoke.sh" \
    --expected-label 'MEIZU M20' --timeout-seconds 0.01 --poll-interval 0.001 \
    --probe "${work}/probe" >/dev/null 2>&1; then
  printf '%s\n' 'runner accepted a visible result returned after the time gate.' >&2
  exit 1
fi

printf 'product USB insertion smoke offline test passed.\n'
