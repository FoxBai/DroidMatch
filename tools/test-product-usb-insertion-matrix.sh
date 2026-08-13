#!/usr/bin/env bash

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="${repo_root}/tools/check-product-usb-insertion-logs.sh"
identity_helper="${repo_root}/tools/product-usb-device-identity.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-product-usb-matrix.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
toolchain_output="$(python3 "${identity_helper}" toolchain)"

profile_value() {
  local output="$1" field="$2" count
  count="$(grep -c "^${field}=" <<<"${output}" || true)"
  [[ "${count}" == "1" ]]
  sed -n "s/^${field}=//p" <<<"${output}"
}

write_fixture() {
  local directory="$1" name="$2" slot="$3" requested_sha="${4:-}" output
  local registry tag manufacturer model api label path source_sha adb_sha
  output="$(python3 "${identity_helper}" profile --slot "${slot}")"
  registry="$(profile_value "${output}" registry_profile)"
  tag="$(profile_value "${output}" identity_tag)"
  manufacturer="$(profile_value "${output}" manufacturer)"
  model="$(profile_value "${output}" model)"
  api="$(profile_value "${output}" android_api)"
  label="$(profile_value "${output}" visible_label)"
  adb_sha="$(profile_value "${toolchain_output}" adb_executable_sha256)"
  if [[ -n "${requested_sha}" ]]; then
    source_sha="${requested_sha}"
  else
    case "${slot}" in
      A) source_sha="1111111111111111111111111111111111111111" ;;
      C) source_sha="2222222222222222222222222222222222222222" ;;
      D) source_sha="3333333333333333333333333333333333333333" ;;
    esac
  fi
  path="${directory}/${name}.md"
  cat >"${path}" <<EOF
# M1 Product USB Insertion Evidence

status: passed
evidence profile: m1-product-usb-insertion-v2
profile result: passed
date: 2026-08-13 00:00:00Z
selected device registry: ${registry}
device slot: ${slot}
device identity tag: ${tag}
device manufacturer: ${manufacturer}
device model: ${model}
device android api: ${api}
device label: ${label}
adb selected absent before arming: true
adb inventory unchanged before signal: true
adb insertion delta verified: true
adb identity verified: true
identity reverified before publication: true
adb toolchain registry: m1-product-usb-adb-v1
adb executable sha256: ${adb_sha}
adb version: 37.0.0
adb build: 14910828
adb server socket: tcp:localhost:47137
adb server stable: true
bundle id: app.droidmatch.mac
profile source revision: ${source_sha}
profile expected main revision: ${source_sha}
profile origin main revision: ${source_sha}
bundle source revision: ${source_sha}
bundle source dirty: false
bundle build configuration: release
bundle sandboxed: true
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
  cp "${path}" "${path}.commit"
}

partial="${work}/partial"
mkdir "${partial}"
write_fixture "${partial}" slot-a A
write_fixture "${partial}" slot-c C
bash "${checker}" --directory "${partial}" >/dev/null
set +e
partial_output="$(
  bash "${checker}" --directory "${partial}" --require-complete-matrix 2>&1
)"
partial_status=$?
set -e
[[ "${partial_status}" -ne 0 ]]
grep -Fq 'missing slots: D' <<<"${partial_output}"

cross_revision="${work}/cross-revision"
mkdir "${cross_revision}"
write_fixture "${cross_revision}" slot-a A
write_fixture "${cross_revision}" slot-c C
write_fixture "${cross_revision}" slot-d D
if bash "${checker}" --directory "${cross_revision}" \
    --require-complete-matrix >/dev/null 2>&1; then
  printf '%s\n' 'complete matrix accepted Slots A/C/D from different source revisions.' >&2
  exit 1
fi

complete="${work}/complete"
mkdir "${complete}"
complete_sha="4444444444444444444444444444444444444444"
write_fixture "${complete}" slot-a A "${complete_sha}"
write_fixture "${complete}" slot-c C "${complete_sha}"
write_fixture "${complete}" slot-d D "${complete_sha}"
bash "${checker}" --directory "${complete}" --require-complete-matrix >/dev/null

relabelled="${work}/relabelled"
mkdir "${relabelled}"
write_fixture "${relabelled}" same-device C
sed -e 's/device slot: C/device slot: A/' \
  "${relabelled}/same-device.md" >"${relabelled}/same-device.md.mutated"
mv "${relabelled}/same-device.md.mutated" "${relabelled}/same-device.md"
cp "${relabelled}/same-device.md" "${relabelled}/same-device.md.commit"
if bash "${checker}" --directory "${relabelled}" >/dev/null 2>&1; then
  printf '%s\n' 'product USB matrix accepted one Slot C device relabelled as Slot A.' >&2
  exit 1
fi

wrong_api="${work}/wrong-api"
mkdir "${wrong_api}"
write_fixture "${wrong_api}" slot-a A
sed 's/device android api: 26/device android api: 34/' \
  "${wrong_api}/slot-a.md" >"${wrong_api}/slot-a.md.mutated"
mv "${wrong_api}/slot-a.md.mutated" "${wrong_api}/slot-a.md"
cp "${wrong_api}/slot-a.md" "${wrong_api}/slot-a.md.commit"
if bash "${checker}" --directory "${wrong_api}" >/dev/null 2>&1; then
  printf '%s\n' 'product USB matrix accepted API 34 as the reviewed Slot A device.' >&2
  exit 1
fi

if bash "${checker}" --log "${complete}/slot-a.md" \
    --require-complete-matrix >/dev/null 2>&1; then
  printf '%s\n' 'complete-matrix mode accepted a single-log invocation.' >&2
  exit 1
fi

printf '%s\n' 'product USB selected-device matrix tests passed.'
printf '%s\n' '中文：产品 USB 所选设备矩阵测试通过。'
