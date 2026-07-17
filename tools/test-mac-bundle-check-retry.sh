#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-bundle-retry-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

mock_bin="${test_root}/bin"
mkdir -p "${mock_bin}"

cat >"${mock_bin}/python3" <<'MOCK_PYTHON'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_STATE}/calls"
call_count="$(wc -l <"${MOCK_STATE}/calls" | tr -d ' ')"
IFS=',' read -r -a outcomes <<<"${MOCK_OUTCOMES}"
outcome="${outcomes[$((call_count - 1))]:-unexpected}"
case "${outcome}" in
  success)
    printf 'Mac App bundle check passed: mock\n'
    ;;
  transient)
    printf 'Mac App bundle check failed: embedded adb is not runnable\n' >&2
    exit 1
    ;;
  permanent)
    printf 'Mac App bundle check failed: embedded adb signature is invalid\n' >&2
    exit 1
    ;;
  near-match)
    printf 'Mac App bundle check failed: embedded adb is not runnable \n' >&2
    exit 23
    ;;
  *)
    printf 'unexpected mock outcome\n' >&2
    exit 64
    ;;
esac
MOCK_PYTHON

cat >"${mock_bin}/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_STATE}/sleeps"
MOCK_SLEEP
chmod +x "${mock_bin}/python3" "${mock_bin}/sleep"

# shellcheck source=mac-bundle-check-retry.sh
source "${repo_root}/tools/mac-bundle-check-retry.sh"

run_case() {
  local name="$1"
  local outcomes="$2"
  local sandboxed="$3"
  local state="${test_root}/${name}"
  mkdir -p "${state}"
  MOCK_STATE="${state}" MOCK_OUTCOMES="${outcomes}" \
    PATH="${mock_bin}:${PATH}" \
    droidmatch_check_app_with_retry \
      /mock/checker.py /mock/DroidMatch.app "${sandboxed}" \
      >"${state}/stdout" 2>"${state}/stderr"
}

run_case transient-recovery transient,transient,success true
[[ "$(wc -l <"${test_root}/transient-recovery/calls" | tr -d ' ')" == 3 ]]
[[ "$(wc -l <"${test_root}/transient-recovery/sleeps" | tr -d ' ')" == 2 ]]
[[ "$(sort -u "${test_root}/transient-recovery/sleeps")" == 5 ]]
[[ "$(tail -n 1 "${test_root}/transient-recovery/calls")" \
  == "/mock/checker.py --sandboxed /mock/DroidMatch.app" ]]
grep -q 'Mac App bundle check passed' "${test_root}/transient-recovery/stdout"

if run_case permanent-failure permanent true; then
  printf 'Permanent bundle failure unexpectedly retried or passed.\n' >&2
  exit 1
fi
[[ "$(wc -l <"${test_root}/permanent-failure/calls" | tr -d ' ')" == 1 ]]
[[ ! -e "${test_root}/permanent-failure/sleeps" ]]
grep -q 'embedded adb signature is invalid' "${test_root}/permanent-failure/stderr"

if run_case near-match-failure near-match true; then
  printf 'Near-match bundle failure unexpectedly retried or passed.\n' >&2
  exit 1
else
  near_match_status=$?
fi
[[ "${near_match_status}" == 23 ]]
[[ "$(wc -l <"${test_root}/near-match-failure/calls" | tr -d ' ')" == 1 ]]
[[ ! -e "${test_root}/near-match-failure/sleeps" ]]

if run_case exhausted transient,transient,transient true; then
  printf 'Exhausted transient bundle failure unexpectedly passed.\n' >&2
  exit 1
fi
[[ "$(wc -l <"${test_root}/exhausted/calls" | tr -d ' ')" == 3 ]]
[[ "$(wc -l <"${test_root}/exhausted/sleeps" | tr -d ' ')" == 2 ]]
[[ "$(sort -u "${test_root}/exhausted/sleeps")" == 5 ]]
grep -q 'embedded adb is not runnable' "${test_root}/exhausted/stderr"

run_case ordinary-success success false
[[ "$(tail -n 1 "${test_root}/ordinary-success/calls")" \
  == "/mock/checker.py /mock/DroidMatch.app" ]]

printf 'App bundle retry tests passed.\n'
