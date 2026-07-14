#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-dmg-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

mock_bin="${test_root}/bin"
state_dir="${test_root}/state"
app_path="${test_root}/DroidMatch.app"
mkdir -p "${mock_bin}" "${state_dir}" "${app_path}"

cat >"${mock_bin}/hdiutil" <<'MOCK_HDIUTIL'
#!/usr/bin/env bash
set -euo pipefail

command_name="${1:-}"
shift || true
case "${command_name}" in
  create)
    source_folder=""
    previous=""
    for argument in "$@"; do
      if [[ "${previous}" == "-srcfolder" ]]; then
        source_folder="${argument}"
      fi
      previous="${argument}"
    done
    output_path="${!#}"
    printf '%s\n' "${source_folder}" >"${MOCK_STATE_DIR}/source-folder"
    printf 'mock-dmg\n' >"${output_path}"
    ;;
  verify)
    count=0
    if [[ -f "${MOCK_STATE_DIR}/verify-count" ]]; then
      read -r count <"${MOCK_STATE_DIR}/verify-count"
    fi
    count=$((count + 1))
    printf '%s\n' "${count}" >"${MOCK_STATE_DIR}/verify-count"
    case "${MOCK_VERIFY_MODE}" in
      transient_then_success)
        if [[ "${count}" -le 2 ]]; then
          printf 'hdiutil: verify failed - Resource temporarily unavailable\n' >&2
          exit 1
        fi
        ;;
      transient_forever)
        printf 'hdiutil: verify failed - Resource temporarily unavailable\n' >&2
        exit 1
        ;;
      permanent)
        printf 'hdiutil: verify failed - invalid disk image\n' >&2
        exit 1
        ;;
      *)
        exit 64
        ;;
    esac
    ;;
  attach)
    mount_path=""
    previous=""
    for argument in "$@"; do
      if [[ "${previous}" == "-mountpoint" ]]; then
        mount_path="${argument}"
      fi
      previous="${argument}"
    done
    source_folder="$(<"${MOCK_STATE_DIR}/source-folder")"
    /bin/cp -R "${source_folder}/." "${mount_path}/"
    ;;
  detach)
    ;;
  *)
    exit 64
    ;;
esac
MOCK_HDIUTIL

cat >"${mock_bin}/plutil" <<'MOCK_PLUTIL'
#!/usr/bin/env bash
printf '0.1.0\n'
MOCK_PLUTIL

cat >"${mock_bin}/ditto" <<'MOCK_DITTO'
#!/usr/bin/env bash
set -euo pipefail
/bin/cp -R "$1" "$2"
MOCK_DITTO

cat >"${mock_bin}/python3" <<'MOCK_PYTHON'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_STATE_DIR}/python-calls"
MOCK_PYTHON

cat >"${mock_bin}/shasum" <<'MOCK_SHASUM'
#!/usr/bin/env bash
set -euo pipefail
printf '%064d  %s\n' 0 "${3:-unknown}"
MOCK_SHASUM

cat >"${mock_bin}/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${1:-}" >>"${MOCK_STATE_DIR}/sleep-calls"
MOCK_SLEEP

chmod +x "${mock_bin}"/*

run_build() {
  local mode="$1"
  local output_path="$2"
  MOCK_STATE_DIR="${state_dir}" \
  MOCK_VERIFY_MODE="${mode}" \
  PATH="${mock_bin}:${PATH}" \
    bash "${repo_root}/tools/build-mac-dmg.sh" \
      --app "${app_path}" \
      --output "${output_path}"
}

reset_state() {
  rm -f "${state_dir}"/*
}

success_output="${test_root}/success.dmg"
run_build transient_then_success "${success_output}" >"${test_root}/success.out" 2>&1
[[ "$(<"${state_dir}/verify-count")" == "3" ]]
[[ "$(wc -l <"${state_dir}/sleep-calls" | tr -d ' ')" == "2" ]]
[[ -s "${success_output}" && -s "${success_output}.sha256" ]]
grep -q 'hdiutil verify temporarily unavailable; retrying (1/3)' "${test_root}/success.out"
grep -q '中文：hdiutil verify 暂时不可用；正在重试（2/3）' "${test_root}/success.out"

reset_state
set +e
run_build permanent "${test_root}/permanent.dmg" >"${test_root}/permanent.out" 2>&1
permanent_status=$?
set -e
[[ "${permanent_status}" -ne 0 ]]
[[ "$(<"${state_dir}/verify-count")" == "1" ]]
[[ ! -e "${state_dir}/sleep-calls" ]]
[[ ! -e "${test_root}/permanent.dmg.sha256" ]]
grep -q 'invalid disk image' "${test_root}/permanent.out"
if grep -q 'retrying' "${test_root}/permanent.out"; then
  printf 'non-transient hdiutil failures must not be retried\n' >&2
  exit 1
fi

reset_state
set +e
run_build transient_forever "${test_root}/exhausted.dmg" >"${test_root}/exhausted.out" 2>&1
exhausted_status=$?
set -e
[[ "${exhausted_status}" -ne 0 ]]
[[ "$(<"${state_dir}/verify-count")" == "3" ]]
[[ "$(wc -l <"${state_dir}/sleep-calls" | tr -d ' ')" == "2" ]]
[[ ! -e "${test_root}/exhausted.dmg.sha256" ]]
grep -q 'Resource temporarily unavailable' "${test_root}/exhausted.out"

printf 'Mac DMG transient retry tests passed.\n'
printf '中文：Mac DMG 瞬时重试测试通过。\n'
