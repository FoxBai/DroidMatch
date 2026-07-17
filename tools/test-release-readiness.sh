#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mock_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-release-readiness.XXXXXX")"
trap 'rm -rf "${mock_root}"' EXIT

mkdir -p "${mock_root}/bin" "${mock_root}/DroidMatch.app"
command_log="${mock_root}/commands.log"
: >"${command_log}"

cat > "${mock_root}/bin/mock-command" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${MOCK_COMMAND_LOG:-}" ]]; then
  printf '%s %s\n' "$(basename "$0")" "$*" >>"${MOCK_COMMAND_LOG}"
fi

case "$(basename "$0")" in
  git)
    if [[ "${1:-}" == "rev-parse" ]]; then
      head_sha='0123456789abcdef0123456789abcdef01234567'
      if [[ -n "${MOCK_GIT_REV_COUNTER_FILE:-}" ]]; then
        rev_count=0
        if [[ -f "${MOCK_GIT_REV_COUNTER_FILE}" ]]; then
          read -r rev_count <"${MOCK_GIT_REV_COUNTER_FILE}"
        fi
        rev_count=$((rev_count + 1))
        printf '%s\n' "${rev_count}" >"${MOCK_GIT_REV_COUNTER_FILE}"
        if [[ "${rev_count}" -gt 1 && -n "${MOCK_HEAD_AFTER:-}" ]]; then
          head_sha="${MOCK_HEAD_AFTER}"
        fi
      fi
      printf '%s\n' "${head_sha}"
    elif [[ "${1:-}" == "status" ]]; then
      [[ "${MOCK_GIT_STATUS_FAILURE:-0}" != "1" ]] || exit 1
      dirty="${MOCK_DIRTY:-0}"
      if [[ -n "${MOCK_GIT_STATUS_COUNTER_FILE:-}" ]]; then
        status_count=0
        if [[ -f "${MOCK_GIT_STATUS_COUNTER_FILE}" ]]; then
          read -r status_count <"${MOCK_GIT_STATUS_COUNTER_FILE}"
        fi
        status_count=$((status_count + 1))
        printf '%s\n' "${status_count}" >"${MOCK_GIT_STATUS_COUNTER_FILE}"
        if [[ "${status_count}" -gt 1 ]]; then
          dirty="${MOCK_DIRTY_AFTER:-${dirty}}"
        fi
      fi
      if [[ "${dirty}" == "1" ]]; then
        printf '%s\n' ' M local-change'
      fi
    fi
    ;;
  security)
    if [[ "${MOCK_IDENTITY:-0}" == "1" ]]; then
      printf '%s\n' '1) TEST-HASH "Developer ID Application: TEST-SUBJECT-DO-NOT-LEAK"'
    else
      printf '%s\n' '0 valid identities found'
    fi
    ;;
  xcrun)
    if [[ "${1:-}" == "--find" ]]; then
      [[ "${MOCK_NOTARYTOOL:-0}" == "1" ]]
    elif [[ "${1:-}" == "stapler" ]]; then
      [[ "${MOCK_STAPLE:-0}" == "1" ]]
    fi
    ;;
  codesign)
    if [[ "$*" == --verify\ --deep\ --strict\ * ]]; then
      [[ "${MOCK_VERIFY:-${MOCK_SIGNATURE:-0}}" == "1" ]]
    elif [[ "$*" == -dv\ --verbose=4\ * && "${MOCK_SIGNATURE:-0}" == "1" ]]; then
      printf '%s\n' 'Authority=Developer ID Application: TEST-SUBJECT-DO-NOT-LEAK' >&2
    else
      exit 1
    fi
    ;;
  plutil)
    [[ "${1:-}" == "-extract" && "${3:-}" == "raw" \
      && "${4:-}" == "-o" && "${5:-}" == "-" ]] || exit 64
    case "${2:-}" in
      DroidMatchSourceRevision)
        printf '%s\n' "${MOCK_ARTIFACT_REVISION:-0123456789abcdef0123456789abcdef01234567}"
        ;;
      DroidMatchSourceDirty)
        printf '%s\n' "${MOCK_ARTIFACT_DIRTY:-false}"
        ;;
      DroidMatchBuildConfiguration)
        printf '%s\n' "${MOCK_ARTIFACT_CONFIGURATION:-release}"
        ;;
      *)
        exit 64
        ;;
    esac
    ;;
  python3)
    [[ "${1:-}" == */tools/check-mac-app-bundle.py \
      && "${2:-}" == "--sandboxed" \
      && "${3:-}" == *.app \
      && "${MOCK_BUNDLE_BOUNDARY:-1}" == "1" ]]
    ;;
  gh)
    case "${1:-}" in
      auth)
        exit 0
        ;;
      repo)
        [[ "${MOCK_REPO_QUERY:-1}" == "1" ]] || exit 1
        printf '%s\n' 'FoxBai/DroidMatch'
        ;;
      api)
        case "${2:-}" in
          repos/*/commits/main)
            [[ "${MOCK_MAIN_QUERY:-1}" == "1" ]] || exit 1
            main_sha="${MOCK_MAIN_SHA:-0123456789abcdef0123456789abcdef01234567}"
            if [[ -n "${MOCK_MAIN_SHA_AFTER:-}" ]]; then
              query_count=0
              if [[ -f "${MOCK_MAIN_COUNTER_FILE}" ]]; then
                read -r query_count < "${MOCK_MAIN_COUNTER_FILE}"
              fi
              query_count=$((query_count + 1))
              printf '%s\n' "${query_count}" > "${MOCK_MAIN_COUNTER_FILE}"
              if [[ "${query_count}" -gt 1 ]]; then
                main_sha="${MOCK_MAIN_SHA_AFTER}"
              fi
            fi
            printf '%s\n' "${main_sha}"
            ;;
          repos/*/branches/main/protection)
            [[ "${MOCK_PROTECTION_QUERY:-1}" == "1" ]] || exit 1
            printf '%s\n' "${MOCK_PROTECTION_STATE:-invalid}"
            ;;
          repos/*)
            [[ "${MOCK_REPO_SETTINGS_QUERY:-1}" == "1" ]] || exit 1
            printf '%s\n' "${MOCK_REPO_SETTINGS_STATE:-valid}"
            ;;
          *)
            exit 64
            ;;
        esac
        ;;
      run)
        [[ "${MOCK_RUN_QUERY:-1}" == "1" ]] || exit 1
        printf '%s\n' "${MOCK_RUN_STATE:-missing}"
        ;;
    esac
    ;;
  *)
    exit 64
    ;;
esac
MOCK
chmod +x "${mock_root}/bin/mock-command"
for command in git security xcrun codesign plutil python3 gh; do
  ln -s mock-command "${mock_root}/bin/${command}"
done

run_preflight() {
  MOCK_COMMAND_LOG="${command_log}" \
    PATH="${mock_root}/bin:${PATH}" \
    "${repo_root}/tools/check-release-readiness.sh" "$@"
}

pass_output="$(
  MOCK_IDENTITY=1 \
  MOCK_NOTARYTOOL=1 \
  MOCK_SIGNATURE=1 \
  MOCK_STAPLE=1 \
  MOCK_PROTECTION_STATE=valid \
  MOCK_RUN_STATE=$'completed\tsuccess\tpush\tmain\t0123456789abcdef0123456789abcdef01234567' \
  run_preflight --github --artifact "${mock_root}/DroidMatch.app"
)"
grep -q 'Automated release preflight passed' <<<"${pass_output}"
if grep -q 'BLOCKED\|TEST-SUBJECT-DO-NOT-LEAK' <<<"${pass_output}"; then
  printf 'release preflight leaked a subject or blocked the passing fixture\n' >&2
  exit 1
fi
grep -Fq "codesign --verify --deep --strict ${mock_root}/DroidMatch.app" \
  "${command_log}"
grep -Fq "python3 ${repo_root}/tools/check-mac-app-bundle.py --sandboxed ${mock_root}/DroidMatch.app" \
  "${command_log}"

head_counter="${mock_root}/local-head-query-count"
rm -f "${head_counter}"
set +e
local_head_race_output="$(
  MOCK_IDENTITY=1 \
  MOCK_NOTARYTOOL=1 \
  MOCK_SIGNATURE=1 \
  MOCK_STAPLE=1 \
  MOCK_GIT_REV_COUNTER_FILE="${head_counter}" \
  MOCK_HEAD_AFTER=ffffffffffffffffffffffffffffffffffffffff \
  run_preflight --artifact "${mock_root}/DroidMatch.app" 2>&1
)"
local_head_race_status=$?
set -e
if [[ "${local_head_race_status}" -ne 1 ]]; then
  printf 'release preflight must reject a local HEAD change during slow checks\n' >&2
  exit 1
fi
grep -q 'Release preflight blocked: 1 automated check(s) failed' \
  <<<"${local_head_race_output}"
grep -q 'local HEAD or worktree changed during release checks' \
  <<<"${local_head_race_output}"

status_counter="${mock_root}/local-status-query-count"
rm -f "${status_counter}"
set +e
local_dirty_race_output="$(
  MOCK_IDENTITY=1 \
  MOCK_NOTARYTOOL=1 \
  MOCK_SIGNATURE=1 \
  MOCK_STAPLE=1 \
  MOCK_GIT_STATUS_COUNTER_FILE="${status_counter}" \
  MOCK_DIRTY_AFTER=1 \
  run_preflight --artifact "${mock_root}/DroidMatch.app" 2>&1
)"
local_dirty_race_status=$?
set -e
if [[ "${local_dirty_race_status}" -ne 1 ]]; then
  printf 'release preflight must reject a worktree change during slow checks\n' >&2
  exit 1
fi
grep -q 'Release preflight blocked: 1 automated check(s) failed' \
  <<<"${local_dirty_race_output}"
grep -q 'local HEAD or worktree changed during release checks' \
  <<<"${local_dirty_race_output}"

assert_artifact_failure() {
  local expected_message="$1"
  shift
  local assignment case_output case_status

  set +e
  case_output="$(
    (
      export MOCK_IDENTITY=1
      export MOCK_NOTARYTOOL=1
      export MOCK_SIGNATURE=1
      export MOCK_STAPLE=1
      for assignment in "$@"; do
        export "${assignment}"
      done
      run_preflight --artifact "${mock_root}/DroidMatch.app"
    ) 2>&1
  )"
  case_status=$?
  set -e

  if [[ "${case_status}" -ne 1 ]]; then
    printf 'release preflight accepted an invalid artifact case: %s\n%s\n' \
      "${expected_message}" "${case_output}" >&2
    exit 1
  fi
  grep -Fq "${expected_message}" <<<"${case_output}"
  if grep -Fq 'TEST-SUBJECT-DO-NOT-LEAK' <<<"${case_output}" \
      || grep -Fq "${mock_root}" <<<"${case_output}"; then
    printf 'artifact failure leaked a certificate subject or private path\n' >&2
    exit 1
  fi
}

assert_artifact_failure \
  'artifact code signature or resource seal is invalid' \
  'MOCK_VERIFY=0'
assert_artifact_failure \
  'artifact source revision is missing or differs from HEAD' \
  'MOCK_ARTIFACT_REVISION=ffffffffffffffffffffffffffffffffffffffff'
assert_artifact_failure \
  'artifact source-dirty provenance is missing or not false' \
  'MOCK_ARTIFACT_DIRTY=true'
assert_artifact_failure \
  'artifact build configuration is missing or not release' \
  'MOCK_ARTIFACT_CONFIGURATION=debug'
assert_artifact_failure \
  'artifact does not match the sandbox product boundary' \
  'MOCK_BUNDLE_BOUNDARY=0'

set +e
governance_output="$(
  MOCK_IDENTITY=1 \
  MOCK_NOTARYTOOL=1 \
  MOCK_SIGNATURE=1 \
  MOCK_STAPLE=1 \
  MOCK_PROTECTION_STATE=invalid \
  MOCK_RUN_STATE=$'completed\tsuccess\tpush\tmain\t0123456789abcdef0123456789abcdef01234567' \
  run_preflight --github --artifact "${mock_root}/DroidMatch.app" 2>&1
)"
governance_status=$?
set -e
if [[ "${governance_status}" -ne 1 ]]; then
  printf 'release preflight must reject readable but incomplete Phase A controls\n' >&2
  exit 1
fi
grep -q 'Release preflight blocked: 1 automated check(s) failed' <<<"${governance_output}"
grep -q 'main protection is unreadable or differs from Phase A' <<<"${governance_output}"

set +e
repository_settings_output="$(
  MOCK_IDENTITY=1 \
  MOCK_NOTARYTOOL=1 \
  MOCK_SIGNATURE=1 \
  MOCK_STAPLE=1 \
  MOCK_PROTECTION_STATE=valid \
  MOCK_REPO_SETTINGS_STATE=invalid \
  MOCK_RUN_STATE=$'completed\tsuccess\tpush\tmain\t0123456789abcdef0123456789abcdef01234567' \
  run_preflight --github --artifact "${mock_root}/DroidMatch.app" 2>&1
)"
repository_settings_status=$?
set -e
if [[ "${repository_settings_status}" -ne 1 ]]; then
  printf 'release preflight must reject weaker repository-level merge or secret-protection settings\n' >&2
  exit 1
fi
grep -q 'Release preflight blocked: 1 automated check(s) failed' <<<"${repository_settings_output}"
grep -q 'repository merge or secret-protection settings are unreadable or differ from baseline' \
  <<<"${repository_settings_output}"

set +e
stale_head_output="$(
  MOCK_IDENTITY=1 \
  MOCK_NOTARYTOOL=1 \
  MOCK_SIGNATURE=1 \
  MOCK_STAPLE=1 \
  MOCK_MAIN_SHA=ffffffffffffffffffffffffffffffffffffffff \
  MOCK_PROTECTION_STATE=valid \
  MOCK_RUN_STATE=$'completed\tsuccess\tpush\tmain\t0123456789abcdef0123456789abcdef01234567' \
  run_preflight --github --artifact "${mock_root}/DroidMatch.app" 2>&1
)"
stale_head_status=$?
set -e
if [[ "${stale_head_status}" -ne 1 ]]; then
  printf 'release preflight must reject a HEAD that is not the live main tip\n' >&2
  exit 1
fi
grep -q 'Release preflight blocked: 1 automated check(s) failed' <<<"${stale_head_output}"
grep -q 'HEAD is unreadable or differs from the live main tip' <<<"${stale_head_output}"

set +e
status_failure_output="$(
  MOCK_GIT_STATUS_FAILURE=1 \
  MOCK_IDENTITY=1 \
  MOCK_NOTARYTOOL=1 \
  MOCK_SIGNATURE=1 \
  MOCK_STAPLE=1 \
  MOCK_PROTECTION_STATE=valid \
  MOCK_RUN_STATE=$'completed\tsuccess\tpush\tmain\t0123456789abcdef0123456789abcdef01234567' \
  run_preflight --github --artifact "${mock_root}/DroidMatch.app" 2>&1
)"
status_failure_status=$?
set -e
if [[ "${status_failure_status}" -ne 1 ]]; then
  printf 'release preflight accepted an unreadable worktree state\n' >&2
  exit 1
fi
grep -q 'Release preflight blocked: 1 automated check(s) failed' \
  <<<"${status_failure_output}"
grep -q 'worktree state could not be verified' <<<"${status_failure_output}"

set +e
ambiguous_run_output="$(
  MOCK_IDENTITY=1 \
  MOCK_NOTARYTOOL=1 \
  MOCK_SIGNATURE=1 \
  MOCK_STAPLE=1 \
  MOCK_PROTECTION_STATE=valid \
  MOCK_RUN_STATE=$'completed\tsuccess\tpull_request\tmain\t0123456789abcdef0123456789abcdef01234567' \
  run_preflight --github --artifact "${mock_root}/DroidMatch.app" 2>&1
)"
ambiguous_run_status=$?
set -e
if [[ "${ambiguous_run_status}" -ne 1 ]]; then
  printf 'release preflight must not accept a PR run as exact-main push evidence\n' >&2
  exit 1
fi
grep -q 'Release preflight blocked: 1 automated check(s) failed' \
  <<<"${ambiguous_run_output}"
grep -q 'hosted main-push gates for exact HEAD are missing or unsuccessful' \
  <<<"${ambiguous_run_output}"

race_counter="${mock_root}/main-query-count"
rm -f "${race_counter}"
set +e
main_race_output="$(
  MOCK_IDENTITY=1 \
  MOCK_NOTARYTOOL=1 \
  MOCK_SIGNATURE=1 \
  MOCK_STAPLE=1 \
  MOCK_PROTECTION_STATE=valid \
  MOCK_MAIN_SHA_AFTER=ffffffffffffffffffffffffffffffffffffffff \
  MOCK_MAIN_COUNTER_FILE="${race_counter}" \
  MOCK_RUN_STATE=$'completed\tsuccess\tpush\tmain\t0123456789abcdef0123456789abcdef01234567' \
  run_preflight --github --artifact "${mock_root}/DroidMatch.app" 2>&1
)"
main_race_status=$?
set -e
if [[ "${main_race_status}" -ne 1 ]]; then
  printf 'release preflight must reject main advancing during GitHub checks\n' >&2
  exit 1
fi
grep -q 'Release preflight blocked: 1 automated check(s) failed' \
  <<<"${main_race_output}"
grep -q 'live main changed or became unreadable during GitHub checks' \
  <<<"${main_race_output}"

set +e
blocked_output="$(
  MOCK_DIRTY=1 \
  MOCK_RUN_STATE=$'in_progress\t\tpush\tmain\t0123456789abcdef0123456789abcdef01234567' \
  run_preflight --github 2>&1
)"
blocked_status=$?
set -e
if [[ "${blocked_status}" -ne 1 ]]; then
  printf 'release preflight must exit 1 for automated blockers\n' >&2
  exit 1
fi
grep -q 'Release preflight blocked: 5 automated check(s) failed' <<<"${blocked_output}"
if grep -q 'TEST-SUBJECT-DO-NOT-LEAK' <<<"${blocked_output}"; then
  printf 'release preflight leaked a mock credential subject\n' >&2
  exit 1
fi

private_path="${mock_root}/private-user-name/Missing.app"
set +e
failure_output="$(
  MOCK_IDENTITY=1 \
  MOCK_NOTARYTOOL=1 \
  MOCK_REPO_QUERY=0 \
  MOCK_MAIN_QUERY=0 \
  MOCK_RUN_QUERY=0 \
  run_preflight --github --artifact "${private_path}" 2>&1
)"
failure_status=$?
set -e
if [[ "${failure_status}" -ne 1 ]]; then
  printf 'release preflight must convert query failures into blockers\n' >&2
  exit 1
fi
grep -q 'repository identity could not be resolved' <<<"${failure_output}"
grep -q 'hosted main-push gates for exact HEAD could not be read' <<<"${failure_output}"
if grep -q 'private-user-name\|Missing.app' <<<"${failure_output}"; then
  printf 'release preflight leaked an artifact path\n' >&2
  exit 1
fi

printf 'Release readiness preflight tests passed.\n'
printf '中文：发布就绪预检测试通过。\n'
