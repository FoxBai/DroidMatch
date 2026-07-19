#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool="${repo_root}/tools/push-main-with-gates.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-push-main-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

mock_bin="${test_root}/bin"
state_dir="${test_root}/state"
mock_log="${test_root}/commands.log"
mkdir -p "${mock_bin}" "${state_dir}"

readonly base_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
readonly candidate_sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
readonly advanced_sha="cccccccccccccccccccccccccccccccccccccccc"

cat >"${mock_bin}/mock-command" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

command_name="$(basename "$0")"
printf '%s %s\n' "${command_name}" "$*" >>"${MOCK_LOG:?}"

increment_counter() {
  local name="$1"
  local count=0
  if [[ -f "${MOCK_STATE_DIR:?}/${name}" ]]; then
    read -r count <"${MOCK_STATE_DIR}/${name}"
  fi
  count=$((count + 1))
  printf '%s\n' "${count}" >"${MOCK_STATE_DIR}/${name}"
  printf '%s' "${count}"
}

argument_after() {
  local wanted="$1"
  shift
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "${wanted}" && $# -ge 2 ]]; then
      printf '%s' "$2"
      return 0
    fi
    shift
  done
  return 1
}

case "${command_name}" in
  date)
    printf '%s\n' '20260715T010203Z'
    ;;
  sleep)
    ;;
  python3)
    [[ "${1:-}" == tools/check-maintainer-contract.py ]] || exit 93
    [[ "${MOCK_PREFLIGHT_FAIL:-0}" != 1 ]] || exit 94
    ;;
  git)
    case "${1:-}" in
      status)
        [[ "${MOCK_STATUS_QUERY_FAIL:-0}" != 1 ]] || exit 70
        if [[ "${MOCK_DIRTY:-0}" == 1 ]]; then
          printf '%s\n' ' M user-change'
        fi
        ;;
      rev-parse)
        case "${2:-}" in
          HEAD)
            printf '%s\n' "${MOCK_CANDIDATE_SHA:?}"
            ;;
          refs/remotes/origin/main)
            read_count="$(increment_counter main-read-count)"
            if [[ -f "${MOCK_STATE_DIR}/main-pushed" \
                && "${MOCK_FINAL_MAIN_ADVANCE:-0}" == 1 \
                && "${read_count}" -ge 4 ]]; then
              printf '%s\n' "${MOCK_ADVANCED_SHA:?}"
            elif [[ -f "${MOCK_STATE_DIR}/main-pushed" ]]; then
              printf '%s\n' "${MOCK_CANDIDATE_SHA}"
            elif [[ -n "${MOCK_MAIN_ADVANCE_ON_READ:-}" \
                && "${read_count}" -ge "${MOCK_MAIN_ADVANCE_ON_READ}" ]]; then
              printf '%s\n' "${MOCK_ADVANCED_SHA:?}"
            else
              printf '%s\n' "${MOCK_BASE_SHA:?}"
            fi
            ;;
          *) exit 71 ;;
        esac
        ;;
      fetch)
        fetch_count="$(increment_counter fetch-count)"
        if [[ "${MOCK_FETCH_FAIL:-0}" == 1 \
            || ( -n "${MOCK_FETCH_ERROR_ON_CALL:-}" \
              && "${fetch_count}" -eq "${MOCK_FETCH_ERROR_ON_CALL}" ) \
            || ( -n "${MOCK_FETCH_ERROR_ON_OR_AFTER:-}" \
              && "${fetch_count}" -ge "${MOCK_FETCH_ERROR_ON_OR_AFTER}" ) ]]; then
          exit 72
        fi
        ;;
      merge-base)
        [[ "${MOCK_DIVERGED:-0}" != 1 ]] || exit 73
        ;;
      check-ref-format)
        ;;
      ls-remote)
        [[ "${MOCK_REF_QUERY_FAIL:-0}" != 1 ]] || exit 79
        if [[ "${MOCK_REF_EXISTS:-0}" == 1 ]]; then
          printf '%s\t%s\n' "${MOCK_CANDIDATE_SHA:?}" "${@: -1}"
        fi
        ;;
      push)
        if [[ "$*" == *' --delete '* ]]; then
          [[ "${MOCK_CLEANUP_FAIL:-0}" != 1 ]] || exit 74
          : >"${MOCK_STATE_DIR}/cleanup"
          exit 0
        fi
        refspec="${@: -1}"
        if [[ "${refspec}" == *':refs/heads/codex/main-gate/'* ]]; then
          [[ "${MOCK_CANDIDATE_PUSH_FAIL:-0}" != 1 ]] || exit 75
          candidate_ref="${refspec#*:refs/heads/}"
          printf '%s\n' "${candidate_ref}" >"${MOCK_STATE_DIR}/candidate-ref"
          exit 0
        fi
        if [[ "${refspec}" == *':refs/heads/main' ]]; then
          main_push_count="$(increment_counter main-push-count)"
          if [[ "${MOCK_MAIN_PUSH_APPLIED_ON_FAILURE:-0}" == 1 \
              && "${main_push_count}" -eq 1 ]]; then
            : >"${MOCK_STATE_DIR}/main-pushed"
            printf '%s\n' "fatal: unable to access remote: Failed to connect to host port 443" >&2
            exit 76
          fi
          if [[ "${MOCK_MAIN_PUSH_TRANSIENT_ALWAYS:-0}" == 1 \
              || ( -n "${MOCK_MAIN_PUSH_TRANSIENT_ON_CALL:-}" \
                && "${main_push_count}" -eq "${MOCK_MAIN_PUSH_TRANSIENT_ON_CALL}" ) ]]; then
            printf '%s\n' "fatal: unable to access remote: Failed to connect to host port 443" >&2
            exit 76
          fi
          if [[ "${MOCK_MAIN_PUSH_SPOOF_TRANSIENT:-0}" == 1 ]]; then
            printf '%s\n' 'remote: Failed to connect to policy port 443' >&2
            exit 76
          fi
          [[ "${MOCK_MAIN_PUSH_FAIL:-0}" != 1 ]] || exit 76
          : >"${MOCK_STATE_DIR}/main-pushed"
          exit 0
        fi
        exit 77
        ;;
      *) exit 78 ;;
    esac
    ;;
  gh)
    case "${1:-}" in
      auth)
        [[ "${MOCK_AUTH_FAIL:-0}" != 1 ]] || exit 80
        ;;
      repo)
        [[ "${MOCK_REPO_FAIL:-0}" != 1 ]] || exit 81
        printf '%s\n' 'FoxBai/DroidMatch'
        ;;
      api)
        [[ "${2:-}" == repos/FoxBai/DroidMatch/branches/main/protection ]] || exit 91
        protection_count="$(increment_counter protection-count)"
        if [[ "${MOCK_PROTECTION_ERROR:-0}" == 1 \
            || ( -n "${MOCK_PROTECTION_ERROR_ON_CALL:-}" \
              && "${protection_count}" -eq "${MOCK_PROTECTION_ERROR_ON_CALL}" ) ]]; then
          exit 92
        fi
        if [[ "${MOCK_PROTECTION_INVALID:-0}" == 1 \
            || ( -n "${MOCK_PROTECTION_INVALID_ON_CALL:-}" \
              && "${protection_count}" -ge "${MOCK_PROTECTION_INVALID_ON_CALL}" ) ]]; then
          printf '%s\n' 'invalid'
        else
          printf '%s\n' 'valid'
        fi
        ;;
      run)
        case "${2:-}" in
          list)
            branch="$(argument_after --branch "$@")"
            commit="$(argument_after --commit "$@")"
            event="$(argument_after --event "$@")"
            [[ "${commit}" == "${MOCK_CANDIDATE_SHA:?}" && "${event}" == push ]] \
              || exit 82
            if [[ "${MOCK_DISCOVERY_MISSING:-0}" == 1 ]]; then
              exit 0
            elif [[ "${branch}" == main ]]; then
              [[ -f "${MOCK_STATE_DIR:?}/main-pushed" ]] || exit 83
              printf '%s\n' '202'
            else
              [[ -f "${MOCK_STATE_DIR:?}/candidate-ref" ]] || exit 84
              [[ "${branch}" == "$(cat "${MOCK_STATE_DIR}/candidate-ref")" ]] || exit 85
              printf '%s\n' '101'
            fi
            ;;
          view)
            run_id="${3:-}"
            candidate_ref="$(cat "${MOCK_STATE_DIR:?}/candidate-ref")"
            if [[ "${MOCK_RUN_QUERY_FAIL:-0}" == 1 ]]; then
              exit 86
            elif [[ "${run_id}" == 101 ]]; then
              printf '%s|%s|%s|%s|%s\n' \
                "${MOCK_CANDIDATE_STATUS:-completed}" \
                "${MOCK_CANDIDATE_CONCLUSION:-success}" \
                "${MOCK_CANDIDATE_EVENT:-push}" \
                "${MOCK_CANDIDATE_BRANCH:-${candidate_ref}}" \
                "${MOCK_CANDIDATE_SHA}"
            elif [[ "${run_id}" == 202 ]]; then
              printf '%s|%s|push|main|%s\n' \
                "${MOCK_MAIN_STATUS:-completed}" \
                "${MOCK_MAIN_CONCLUSION:-success}" \
                "${MOCK_CANDIDATE_SHA}"
            else
              exit 87
            fi
            ;;
          *) exit 88 ;;
        esac
        ;;
      *) exit 89 ;;
    esac
    ;;
  *) exit 90 ;;
esac
MOCK
chmod +x "${mock_bin}/mock-command"
for command_name in git gh date sleep python3; do
  ln -s mock-command "${mock_bin}/${command_name}"
done

reset_case() {
  rm -rf "${state_dir}"
  mkdir -p "${state_dir}"
  : >"${mock_log}"
}

run_tool() {
  (
    PATH="${mock_bin}:${PATH}"
    MOCK_LOG="${mock_log}"
    MOCK_STATE_DIR="${state_dir}"
    MOCK_BASE_SHA="${MOCK_BASE_SHA:-${base_sha}}"
    MOCK_CANDIDATE_SHA="${MOCK_CANDIDATE_SHA:-${candidate_sha}}"
    MOCK_ADVANCED_SHA="${MOCK_ADVANCED_SHA:-${advanced_sha}}"
    while IFS= read -r mock_variable; do
      export "${mock_variable}"
    done < <(compgen -A variable MOCK_)
    export PATH
    "${tool}" "$@"
  )
}

expect_failure() {
  local expected_status="$1"
  shift
  set +e
  case_output="$(run_tool "$@" 2>&1)"
  case_status=$?
  set -e
  if [[ "${case_status}" -ne "${expected_status}" ]]; then
    printf 'unexpected status %s, expected %s\n%s\n' \
      "${case_status}" "${expected_status}" "${case_output}" >&2
    exit 1
  fi
}

reset_case
expect_failure 2
grep -q -- '--confirm-direct-main' <<<"${case_output}"
if grep -q '^git push ' "${mock_log}"; then
  printf 'missing confirmation must not mutate the remote\n' >&2
  exit 1
fi

reset_case
pass_output="$(run_tool --confirm-direct-main)"
grep -q "Direct-main integration passed: ${candidate_sha}" <<<"${pass_output}"
grep -q 'Candidate run: https://github.com/FoxBai/DroidMatch/actions/runs/101' \
  <<<"${pass_output}"
grep -q 'Main run: https://github.com/FoxBai/DroidMatch/actions/runs/202' \
  <<<"${pass_output}"
candidate_push_line="$(grep -n '^git push origin .*refs/heads/codex/main-gate/' "${mock_log}" | cut -d: -f1)"
preflight_line="$(grep -n '^python3 tools/check-maintainer-contract.py$' "${mock_log}" | cut -d: -f1)"
main_push_line="$(grep -n "^git push origin ${candidate_sha}:refs/heads/main" "${mock_log}" | cut -d: -f1)"
cleanup_line="$(grep -n '^git push --quiet origin --delete codex/main-gate/' "${mock_log}" | cut -d: -f1)"
[[ -n "${preflight_line}" && -n "${candidate_push_line}" \
    && -n "${main_push_line}" && -n "${cleanup_line}" ]]
[[ "${preflight_line}" -lt "${candidate_push_line}" \
    && "${candidate_push_line}" -lt "${main_push_line}" \
    && "${main_push_line}" -lt "${cleanup_line}" ]]
if grep -q -- '--force\|workflow run\|pull-request\| pr ' "${mock_log}"; then
  printf 'passing direct-main flow used a forbidden bypass or PR path\n' >&2
  exit 1
fi
grep -q '^git status --porcelain=v1 --untracked-files=all$' "${mock_log}"
grep -q '^git ls-remote --heads origin refs/heads/codex/main-gate/' "${mock_log}"

reset_case
transient_fetch_output="$(
  MOCK_FETCH_ERROR_ON_CALL=3 run_tool --confirm-direct-main 2>&1
)"
grep -q "Direct-main integration passed: ${candidate_sha}" \
  <<<"${transient_fetch_output}"
grep -q 'origin/main refresh failed; retrying (1/3)' \
  <<<"${transient_fetch_output}"
[[ "$(<"${state_dir}/fetch-count")" -eq 5 ]]
[[ "$(grep -c '^git push origin .*refs/heads/codex/main-gate/' "${mock_log}")" -eq 1 ]]
[[ "$(grep -c "^git push origin ${candidate_sha}:refs/heads/main" "${mock_log}")" -eq 1 ]]

reset_case
set +e
unreadable_main_output="$(MOCK_FETCH_FAIL=1 run_tool --confirm-direct-main 2>&1)"
unreadable_main_status=$?
set -e
[[ "${unreadable_main_status}" -eq 1 ]]
grep -q 'origin/main could not be refreshed' <<<"${unreadable_main_output}"
[[ "$(<"${state_dir}/fetch-count")" -eq 3 ]]
if grep -q '^git push ' "${mock_log}"; then
  printf 'persistently unreadable main must fail before remote mutation\n' >&2
  exit 1
fi

reset_case
set +e
post_push_fetch_output="$(
  MOCK_FETCH_ERROR_ON_OR_AFTER=3 run_tool --confirm-direct-main 2>&1
)"
post_push_fetch_status=$?
set -e
[[ "${post_push_fetch_status}" -eq 1 ]]
grep -q 'origin/main could not be refreshed after push' \
  <<<"${post_push_fetch_output}"
[[ -f "${state_dir}/main-pushed" && -f "${state_dir}/cleanup" ]]
[[ "$(grep -c "^git push origin ${candidate_sha}:refs/heads/main" "${mock_log}")" -eq 1 ]]

reset_case
set +e
dirty_output="$(MOCK_DIRTY=1 run_tool --confirm-direct-main 2>&1)"
dirty_status=$?
set -e
[[ "${dirty_status}" -eq 1 ]]
grep -q 'worktree has uncommitted changes' <<<"${dirty_output}"
if grep -q '^git push ' "${mock_log}"; then
  printf 'dirty worktree must fail before remote mutation\n' >&2
  exit 1
fi

reset_case
set +e
preflight_output="$(MOCK_PREFLIGHT_FAIL=1 run_tool --confirm-direct-main 2>&1)"
preflight_status=$?
set -e
[[ "${preflight_status}" -eq 1 ]]
grep -q 'local maintainer-contract preflight rejected the candidate' \
  <<<"${preflight_output}"
if grep -q '^git push ' "${mock_log}"; then
  printf 'failed local preflight must not mutate the remote\n' >&2
  exit 1
fi

reset_case
set +e
no_op_output="$(MOCK_CANDIDATE_SHA="${base_sha}" run_tool --confirm-direct-main 2>&1)"
no_op_status=$?
set -e
[[ "${no_op_status}" -eq 1 ]]
grep -q 'HEAD is already live main' <<<"${no_op_output}"

reset_case
set +e
diverged_output="$(MOCK_DIVERGED=1 run_tool --confirm-direct-main 2>&1)"
diverged_status=$?
set -e
[[ "${diverged_status}" -eq 1 ]]
grep -q 'HEAD is not a fast-forward descendant' <<<"${diverged_output}"

reset_case
set +e
protection_output="$(MOCK_PROTECTION_INVALID=1 run_tool --confirm-direct-main 2>&1)"
protection_status=$?
set -e
[[ "${protection_status}" -eq 1 ]]
grep -q 'main protection differs from Phase A before candidate CI' <<<"${protection_output}"

reset_case
transient_protection_output="$(
  MOCK_PROTECTION_ERROR_ON_CALL=2 run_tool --confirm-direct-main 2>&1
)"
grep -q "Direct-main integration passed: ${candidate_sha}" \
  <<<"${transient_protection_output}"
grep -q 'main protection read failed; retrying (1/3)' \
  <<<"${transient_protection_output}"
[[ "$(<"${state_dir}/protection-count")" -eq 4 ]]

reset_case
set +e
unreadable_protection_output="$(
  MOCK_PROTECTION_ERROR=1 run_tool --confirm-direct-main 2>&1
)"
unreadable_protection_status=$?
set -e
[[ "${unreadable_protection_status}" -eq 1 ]]
grep -q 'main protection is unreadable after 3 attempts before candidate CI' \
  <<<"${unreadable_protection_output}"
[[ "$(<"${state_dir}/protection-count")" -eq 3 ]]
if grep -q '^git push ' "${mock_log}"; then
  printf 'persistently unreadable protection must fail before remote mutation\n' >&2
  exit 1
fi

reset_case
set +e
event_output="$(MOCK_CANDIDATE_EVENT=workflow_dispatch run_tool --confirm-direct-main 2>&1)"
event_status=$?
set -e
[[ "${event_status}" -eq 1 ]]
grep -q 'candidate run identity differs from the exact push candidate' <<<"${event_output}"
[[ -f "${state_dir}/cleanup" && ! -f "${state_dir}/main-pushed" ]]

reset_case
set +e
candidate_failure_output="$(MOCK_CANDIDATE_CONCLUSION=failure run_tool --confirm-direct-main 2>&1)"
candidate_failure_status=$?
set -e
[[ "${candidate_failure_status}" -eq 1 ]]
grep -q 'candidate run completed with failure' <<<"${candidate_failure_output}"
[[ -f "${state_dir}/cleanup" && ! -f "${state_dir}/main-pushed" ]]

reset_case
set +e
race_output="$(MOCK_MAIN_ADVANCE_ON_READ=2 run_tool --confirm-direct-main 2>&1)"
race_status=$?
set -e
[[ "${race_status}" -eq 1 ]]
grep -q 'main advanced during candidate CI' <<<"${race_output}"
[[ -f "${state_dir}/cleanup" && ! -f "${state_dir}/main-pushed" ]]

reset_case
set +e
protection_race_output="$(MOCK_PROTECTION_INVALID_ON_CALL=2 run_tool --confirm-direct-main 2>&1)"
protection_race_status=$?
set -e
[[ "${protection_race_status}" -eq 1 ]]
grep -q 'main protection differs from Phase A after candidate CI' <<<"${protection_race_output}"
[[ -f "${state_dir}/cleanup" && ! -f "${state_dir}/main-pushed" ]]

reset_case
set +e
push_rejection_output="$(MOCK_MAIN_PUSH_FAIL=1 run_tool --confirm-direct-main 2>&1)"
push_rejection_status=$?
set -e
[[ "${push_rejection_status}" -eq 1 ]]
grep -q 'protected main rejected the non-forced fast-forward' <<<"${push_rejection_output}"
[[ -f "${state_dir}/cleanup" && ! -f "${state_dir}/main-pushed" ]]
[[ "$(<"${state_dir}/main-push-count")" -eq 1 ]]
if grep -q 'main push transport failed with main unchanged; retrying' \
    <<<"${push_rejection_output}"; then
  printf 'non-network push rejection must not be retried\n' >&2
  exit 1
fi

reset_case
set +e
spoofed_transport_output="$(
  MOCK_MAIN_PUSH_SPOOF_TRANSIENT=1 run_tool --confirm-direct-main 2>&1
)"
spoofed_transport_status=$?
set -e
[[ "${spoofed_transport_status}" -eq 1 ]]
grep -q 'protected main rejected the non-forced fast-forward' \
  <<<"${spoofed_transport_output}"
[[ "$(<"${state_dir}/main-push-count")" -eq 1 ]]

reset_case
transient_push_output="$(
  MOCK_MAIN_PUSH_TRANSIENT_ON_CALL=1 run_tool --confirm-direct-main 2>&1
)"
grep -q "Direct-main integration passed: ${candidate_sha}" \
  <<<"${transient_push_output}"
grep -q 'main push transport failed with main unchanged; retrying (1/3)' \
  <<<"${transient_push_output}"
[[ "$(<"${state_dir}/main-push-count")" -eq 2 ]]

reset_case
set +e
retry_protection_output="$(
  MOCK_MAIN_PUSH_TRANSIENT_ON_CALL=1 MOCK_PROTECTION_INVALID_ON_CALL=3 \
    run_tool --confirm-direct-main 2>&1
)"
retry_protection_status=$?
set -e
[[ "${retry_protection_status}" -eq 1 ]]
grep -q 'main protection differs from Phase A before retrying main push' \
  <<<"${retry_protection_output}"
[[ "$(<"${state_dir}/main-push-count")" -eq 1 ]]
[[ -f "${state_dir}/cleanup" && ! -f "${state_dir}/main-pushed" ]]

reset_case
set +e
pre_retry_race_output="$(
  MOCK_MAIN_PUSH_TRANSIENT_ON_CALL=1 MOCK_MAIN_ADVANCE_ON_READ=4 \
    run_tool --confirm-direct-main 2>&1
)"
pre_retry_race_status=$?
set -e
[[ "${pre_retry_race_status}" -eq 1 ]]
grep -q 'main changed immediately before a push retry; refusing to write' \
  <<<"${pre_retry_race_output}"
[[ "$(<"${state_dir}/main-push-count")" -eq 1 ]]
[[ -f "${state_dir}/cleanup" && ! -f "${state_dir}/main-pushed" ]]

reset_case
accepted_push_output="$(
  MOCK_MAIN_PUSH_APPLIED_ON_FAILURE=1 run_tool --confirm-direct-main 2>&1
)"
grep -q "Direct-main integration passed: ${candidate_sha}" \
  <<<"${accepted_push_output}"
grep -q 'main already equals the candidate after a failed local push result' \
  <<<"${accepted_push_output}"
[[ "$(<"${state_dir}/main-push-count")" -eq 1 ]]

reset_case
set +e
ambiguous_race_output="$(
  MOCK_MAIN_PUSH_TRANSIENT_ON_CALL=1 MOCK_MAIN_ADVANCE_ON_READ=3 \
    run_tool --confirm-direct-main 2>&1
)"
ambiguous_race_status=$?
set -e
[[ "${ambiguous_race_status}" -eq 1 ]]
grep -q 'main changed after an ambiguous push result; refusing to retry' \
  <<<"${ambiguous_race_output}"
[[ "$(<"${state_dir}/main-push-count")" -eq 1 ]]
[[ -f "${state_dir}/cleanup" && ! -f "${state_dir}/main-pushed" ]]

reset_case
set +e
exhausted_push_output="$(
  MOCK_MAIN_PUSH_TRANSIENT_ALWAYS=1 run_tool --confirm-direct-main 2>&1
)"
exhausted_push_status=$?
set -e
[[ "${exhausted_push_status}" -eq 1 ]]
grep -q 'main push transport failed after 3 attempts' <<<"${exhausted_push_output}"
[[ "$(<"${state_dir}/main-push-count")" -eq 3 ]]
[[ -f "${state_dir}/cleanup" && ! -f "${state_dir}/main-pushed" ]]

reset_case
set +e
main_failure_output="$(MOCK_MAIN_CONCLUSION=failure run_tool --confirm-direct-main 2>&1)"
main_failure_status=$?
set -e
[[ "${main_failure_status}" -eq 1 ]]
grep -q 'main run completed with failure' <<<"${main_failure_output}"
[[ -f "${state_dir}/cleanup" && -f "${state_dir}/main-pushed" ]]

reset_case
set +e
final_main_race_output="$(MOCK_FINAL_MAIN_ADVANCE=1 run_tool --confirm-direct-main 2>&1)"
final_main_race_status=$?
set -e
[[ "${final_main_race_status}" -eq 1 ]]
grep -q 'main advanced while exact-main CI was running' <<<"${final_main_race_output}"
[[ -f "${state_dir}/cleanup" && -f "${state_dir}/main-pushed" ]]

reset_case
set +e
ref_collision_output="$(MOCK_REF_EXISTS=1 run_tool --confirm-direct-main 2>&1)"
ref_collision_status=$?
set -e
[[ "${ref_collision_status}" -eq 1 ]]
grep -q 'generated temporary gate ref already exists' <<<"${ref_collision_output}"
if grep -q '^git push ' "${mock_log}"; then
  printf 'a colliding temporary ref must fail before remote mutation\n' >&2
  exit 1
fi

reset_case
set +e
final_protection_output="$(MOCK_PROTECTION_INVALID_ON_CALL=3 run_tool --confirm-direct-main 2>&1)"
final_protection_status=$?
set -e
[[ "${final_protection_status}" -eq 1 ]]
grep -q 'main protection differs from Phase A after exact-main CI' <<<"${final_protection_output}"
[[ -f "${state_dir}/cleanup" && -f "${state_dir}/main-pushed" ]]

printf 'Direct-main integration script tests passed.\n'
printf '中文：受保护 main 直推脚本测试通过。\n'
