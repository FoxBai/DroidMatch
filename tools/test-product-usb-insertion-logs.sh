#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="${repo_root}/tools/check-product-usb-insertion-logs.sh"
source "${repo_root}/tools/product-usb-evidence-publication.sh"
cd "${repo_root}"
work="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-product-usb-log-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
real_grep="$(command -v grep)"
real_ln="$(command -v ln)"
real_rm="$(command -v rm)"
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
cat >"${work}/bin/ln" <<'FAKE_LN'
#!/usr/bin/env bash
set -euo pipefail

target=""
for target in "$@"; do :; done
[[ -n "${target}" ]] || exit 78
case "${FAKE_PRODUCT_USB_LN_MODE:-pass}" in
  pass) ;;
  fail) exit 79 ;;
  regular-race)
    printf '%s\n' 'concurrent-writer-sentinel' >"${target}"
    ;;
  directory-symlink-race)
    mkdir "${target}.directory"
    "${REAL_LN:?}" -s "${target}.directory" "${target}"
    ;;
  *) exit 80 ;;
esac
exec "${REAL_LN:?}" "$@"
FAKE_LN
cat >"${work}/bin/rm" <<'FAKE_RM'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${FAKE_PRODUCT_USB_RM_MODE:-pass}" == 'staged-unlink-failure' ]]; then
  for argument in "$@"; do
    if [[ "${argument}" == *'/.product-usb-stage-'* ]]; then
      exit 81
    fi
  done
fi
exec "${REAL_RM:?}" "$@"
FAKE_RM
chmod +x "${work}/bin/grep" "${work}/bin/ln" "${work}/bin/rm"

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

expect_checker_rejection() {
  local mode="$1" path="$2" label="$3"
  if bash "${checker}" "${mode}" "${path}" >/dev/null 2>&1; then
    printf 'product USB evidence checker accepted non-regular input: %s\n' \
      "${label}" >&2
    exit 1
  fi
}

# Both entry points reject filesystem indirection before reading content. A FIFO
# must be rejected by its type check rather than opened and allowed to block.
single_symlink="${work}/single-symlink.md"
"${real_ln}" -s "${valid}" "${single_symlink}"
expect_checker_rejection --log "${single_symlink}" 'single-log symlink'

single_directory="${work}/single-directory.md"
mkdir "${single_directory}"
expect_checker_rejection --log "${single_directory}" 'single-log directory'

single_fifo="${work}/single-fifo.md"
mkfifo "${single_fifo}"
expect_checker_rejection --log "${single_fifo}" 'single-log FIFO'

directory_symlink_entries="${work}/directory-symlink-entries"
mkdir "${directory_symlink_entries}"
cp "${valid}" "${directory_symlink_entries}/valid.md"
"${real_ln}" -s "${valid}" "${directory_symlink_entries}/linked.md"
expect_checker_rejection \
  --directory "${directory_symlink_entries}" 'directory-mode symlink entry'

directory_directory_entries="${work}/directory-directory-entries"
mkdir "${directory_directory_entries}"
cp "${valid}" "${directory_directory_entries}/valid.md"
mkdir "${directory_directory_entries}/nested.md"
expect_checker_rejection \
  --directory "${directory_directory_entries}" 'directory-mode directory entry'

directory_fifo_entries="${work}/directory-fifo-entries"
mkdir "${directory_fifo_entries}"
cp "${valid}" "${directory_fifo_entries}/valid.md"
mkfifo "${directory_fifo_entries}/pipe.md"
expect_checker_rejection \
  --directory "${directory_fifo_entries}" 'directory-mode FIFO entry'

directory_target="${work}/real-directory"
directory_link="${work}/linked-directory"
mkdir "${directory_target}"
"${real_ln}" -s "${directory_target}" "${directory_link}"
expect_checker_rejection --directory "${directory_link}" 'directory path symlink'

run_publication() (
  export PATH="${work}/bin:${PATH}"
  export REAL_GREP="${real_grep}"
  export REAL_LN="${real_ln}"
  export REAL_RM="${real_rm}"
  export FAKE_PRODUCT_USB_LN_MODE="$1"
  export FAKE_PRODUCT_USB_RM_MODE="$2"
  publish_product_usb_staged_log "$3" "$4" "${checker}"
)

expect_publication_failure() {
  local label="$1" ln_mode="$2" rm_mode="$3" staged="$4" result="$5"
  local output status
  set +e
  output="$(run_publication \
    "${ln_mode}" "${rm_mode}" "${staged}" "${result}" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -eq 0 ]]; then
    printf 'product USB publisher accepted failure case: %s\n' "${label}" >&2
    exit 1
  fi
  if [[ "${output}" == *'Product USB insertion evidence written'* \
      || "${output}" == *'product_usb_insertion_elapsed_ms='* ]]; then
    printf 'product USB publisher reported success for failure case: %s\n' \
      "${label}" >&2
    exit 1
  fi
}

# Successful publication creates one regular result and removes the staging
# link only after the strict single-log validator has accepted the record.
success_staged="${work}/.product-usb-stage-success"
success_result="${work}/publication-success.md"
cp "${valid}" "${success_staged}"
run_publication pass pass "${success_staged}" "${success_result}"
[[ -f "${success_result}" && ! -L "${success_result}" ]]
[[ ! -e "${success_staged}" && ! -L "${success_staged}" ]]
bash "${checker}" --log "${success_result}" >/dev/null

existing_staged="${work}/.product-usb-stage-existing"
existing_result="${work}/publication-existing.md"
cp "${valid}" "${existing_staged}"
printf '%s\n' 'existing-writer-sentinel' >"${existing_result}"
expect_publication_failure \
  existing-target pass pass "${existing_staged}" "${existing_result}"
grep -Fqx 'existing-writer-sentinel' "${existing_result}"

dangling_staged="${work}/.product-usb-stage-dangling"
dangling_result="${work}/publication-dangling.md"
cp "${valid}" "${dangling_staged}"
"${real_ln}" -s "${work}/missing-target" "${dangling_result}"
expect_publication_failure \
  dangling-symlink pass pass "${dangling_staged}" "${dangling_result}"
[[ -L "${dangling_result}" && ! -e "${dangling_result}" ]]

directory_staged="${work}/.product-usb-stage-directory-symlink"
directory_result="${work}/publication-directory-symlink.md"
directory_result_target="${work}/publication-directory-symlink-target"
cp "${valid}" "${directory_staged}"
mkdir "${directory_result_target}"
"${real_ln}" -s "${directory_result_target}" "${directory_result}"
expect_publication_failure \
  directory-symlink pass pass "${directory_staged}" "${directory_result}"
[[ -L "${directory_result}" ]]
[[ -z "$(find "${directory_result_target}" -mindepth 1 -print -quit)" ]]

staged_symlink="${work}/.product-usb-stage-symlink"
staged_symlink_result="${work}/publication-staged-symlink.md"
"${real_ln}" -s "${valid}" "${staged_symlink}"
expect_publication_failure \
  staged-symlink pass pass "${staged_symlink}" "${staged_symlink_result}"
[[ -L "${staged_symlink}" && ! -e "${staged_symlink_result}" ]]

regular_race_staged="${work}/.product-usb-stage-regular-race"
regular_race_result="${work}/publication-regular-race.md"
cp "${valid}" "${regular_race_staged}"
expect_publication_failure \
  regular-file-race regular-race pass \
  "${regular_race_staged}" "${regular_race_result}"
grep -Fqx 'concurrent-writer-sentinel' "${regular_race_result}"

directory_race_staged="${work}/.product-usb-stage-directory-race"
directory_race_result="${work}/publication-directory-race.md"
cp "${valid}" "${directory_race_staged}"
expect_publication_failure \
  directory-symlink-race directory-symlink-race pass \
  "${directory_race_staged}" "${directory_race_result}"
[[ -L "${directory_race_result}" ]]
[[ -z "$(find "${directory_race_result}.directory" -mindepth 1 -print -quit)" ]]

invalid_staged="${work}/.product-usb-stage-invalid"
invalid_result="${work}/publication-invalid.md"
sed 's/^status: passed$/status: failed/' "${valid}" >"${invalid_staged}"
expect_publication_failure \
  validator-failure pass pass "${invalid_staged}" "${invalid_result}"
[[ ! -e "${invalid_result}" && ! -L "${invalid_result}" ]]

ln_failure_staged="${work}/.product-usb-stage-ln-failure"
ln_failure_result="${work}/publication-ln-failure.md"
cp "${valid}" "${ln_failure_staged}"
expect_publication_failure \
  ln-failure fail pass "${ln_failure_staged}" "${ln_failure_result}"
[[ ! -e "${ln_failure_result}" && ! -L "${ln_failure_result}" ]]

unlink_failure_staged="${work}/.product-usb-stage-unlink-failure"
unlink_failure_result="${work}/publication-unlink-failure.md"
cp "${valid}" "${unlink_failure_staged}"
expect_publication_failure \
  staging-unlink-failure pass staged-unlink-failure \
  "${unlink_failure_staged}" "${unlink_failure_result}"
[[ -f "${unlink_failure_staged}" && ! -L "${unlink_failure_staged}" ]]
[[ -f "${unlink_failure_result}" && ! -L "${unlink_failure_result}" ]]
bash "${checker}" --log "${unlink_failure_result}" >/dev/null
"${real_rm}" -f "${unlink_failure_staged}" "${unlink_failure_result}"

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
