#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="${repo_root}/tools/check-product-usb-insertion-logs.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-product-usb-log-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
real_grep="$(command -v grep)"
mkdir "${work}/bin"
cat >"${work}/bin/grep" <<'FAKE_GREP'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_GREP_CONTROL_FAILURE:-0}" == "1" \
    && "$*" == *'[[:cntrl:]]'* ]]; then
  exit 74
fi
exec "${REAL_GREP:?}" "$@"
FAKE_GREP
chmod +x "${work}/bin/grep"

valid="${work}/valid.md"
cat >"${valid}" <<'EOF'
# M1 Product USB Insertion Evidence

status: passed
evidence profile: m1-product-usb-insertion-v1
profile result: passed
date: 2026-07-13 00:00:00Z
device slot: C
device label: MEIZU M20
bundle id: app.droidmatch.mac
profile source revision: 1111111111111111111111111111111111111111
profile expected main revision: 1111111111111111111111111111111111111111
profile origin main revision: 1111111111111111111111111111111111111111
bundle source revision: 1111111111111111111111111111111111111111
bundle source dirty: false
bundle build configuration: release
bundle sandboxed: false
bundle executable sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
running code requirement verified: true
running app count: 1
running bundle matched requested app: true
bundle verification: passed
repository clean before run: true
repository clean after run: true
preflight matching elements: 0
pre-signal matching elements: 0
operator arm acknowledged: true
operator physical insertion attested: true
measurement clock: CLOCK_MONOTONIC
measurement boundary: monotonic-before-insert-now
countdown seconds: 3
poll interval ms: 100
threshold ms: 5000
elapsed ms: 2431
completion matching elements: 1
product visible: true
accessibility identifier: app.droidmatch.discovery-device-card
probe override: false
EOF

bash "${checker}" --log "${valid}" >/dev/null

set +e
grep_failure_output="$(
  PATH="${work}/bin:${PATH}" \
  REAL_GREP="${real_grep}" \
  FAKE_GREP_CONTROL_FAILURE=1 \
    bash "${checker}" --log "${valid}" 2>&1
)"
grep_failure_status=$?
set -e
if [[ "${grep_failure_status}" -eq 0 ]]; then
  printf '%s\n' 'product USB evidence checker accepted a grep failure' >&2
  exit 1
fi
grep -Fq 'invalid product USB insertion evidence' <<<"${grep_failure_output}"

privacy="${work}/privacy.md"
sed 's/device label: MEIZU M20/device label: PASSWORD=PRODUCT-USB-PRIVATE-VALUE/' \
  "${valid}" >"${privacy}"
set +e
privacy_output="$(bash "${checker}" --log "${privacy}" 2>&1)"
privacy_status=$?
set -e
if [[ "${privacy_status}" -eq 0 ]]; then
  printf '%s\n' 'product USB evidence checker accepted sensitive content' >&2
  exit 1
fi
if [[ "${privacy_output}" == *'PRODUCT-USB-PRIVATE-VALUE'* ]]; then
  printf '%s\n' 'product USB evidence checker echoed sensitive content' >&2
  exit 1
fi

reject_mutation() {
  local name="$1" from="$2" to="$3"
  local invalid="${work}/${name}.md"
  sed "s/${from}/${to}/" "${valid}" >"${invalid}"
  if bash "${checker}" --log "${invalid}" >/dev/null 2>&1; then
    printf 'product USB evidence checker accepted mutation: %s\n' "${name}" >&2
    exit 1
  fi
}

reject_mutation elapsed 'elapsed ms: 2431' 'elapsed ms: 5001'
reject_mutation elapsed-overflow \
  'elapsed ms: 2431' \
  'elapsed ms: 9223372036854775808'
reject_mutation zero-elapsed 'elapsed ms: 2431' 'elapsed ms: 0'
reject_mutation dirty 'bundle source dirty: false' 'bundle source dirty: true'
reject_mutation override 'probe override: false' 'probe override: true'
reject_mutation revision \
  'bundle source revision: 1111111111111111111111111111111111111111' \
  'bundle source revision: 2222222222222222222222222222222222222222'
reject_mutation cdhash-case \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'bundle code cdhash: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
reject_mutation cdhash-length \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
reject_mutation cdhash-short \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
reject_mutation cdhash-sha256-length \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
reject_mutation cdhash-nonhex \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'bundle code cdhash: gbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
reject_mutation cdhash-empty \
  'bundle code cdhash: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'bundle code cdhash: '
reject_mutation dynamic-requirement \
  'running code requirement verified: true' \
  'running code requirement verified: false'
reject_mutation profile \
  'evidence profile: m1-product-usb-insertion-v1' \
  'evidence profile: unknown'

duplicate="${work}/duplicate.md"
cp "${valid}" "${duplicate}"
printf '%s\n' 'status: failed' >>"${duplicate}"
if bash "${checker}" --log "${duplicate}" >/dev/null 2>&1; then
  printf '%s\n' 'product USB evidence checker accepted duplicate status' >&2
  exit 1
fi

sensitive="${work}/sensitive.md"
cp "${valid}" "${sensitive}"
printf '%s\n' 'notes: /Users/private/secret' >>"${sensitive}"
if bash "${checker}" --log "${sensitive}" >/dev/null 2>&1; then
  printf '%s\n' 'product USB evidence checker accepted sensitive content' >&2
  exit 1
fi

unknown="${work}/unknown-field.md"
cp "${valid}" "${unknown}"
printf '%s\n' 'notes: extra field' >>"${unknown}"
if bash "${checker}" --log "${unknown}" >/dev/null 2>&1; then
  printf '%s\n' 'product USB evidence checker accepted an unknown field' >&2
  exit 1
fi

printf '%s\n' 'product USB insertion evidence validator tests passed.'
printf '%s\n' '中文：产品 USB 插入证据校验器测试通过。'
