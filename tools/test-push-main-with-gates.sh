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
readonly second_candidate_sha="dddddddddddddddddddddddddddddddddddddddd"
cat >"${mock_bin}/mock-command" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
command_name="$(basename "$0")"
saw_empty_hooks=0 saw_disabled_fsmonitor=0
if [[ "${command_name}" == git ]]; then
  while [[ "${1:-}" == -c && $# -ge 2 ]]; do
    [[ "$2" != core.hooksPath=/dev/null ]] || saw_empty_hooks=1
    [[ "$2" != core.fsmonitor=false ]] || saw_disabled_fsmonitor=1
    shift 2
  done
fi
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
    if [[ "${1:-}" == -c ]]; then
      printf '%s\n' '0123456789abcdef0123456789abcdef'
    else
      [[ "${1:-}" == tools/check-maintainer-contract.py ]] || exit 93
      [[ "${MOCK_PREFLIGHT_FAIL:-0}" != 1 ]] || exit 94
    fi
    ;;
  git)
    if [[ "${1:-}" == --no-replace-objects ]]; then
      shift
    fi
    case "${1:-}" in
      status)
        [[ "${saw_empty_hooks}" -eq 1 && "${saw_disabled_fsmonitor}" -eq 1 ]] || exit 97
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
          --git-path)
            grafts_path="${MOCK_STATE_DIR:?}/grafts"
            if [[ "${MOCK_GRAFTS_PRESENT:-0}" == 1 ]]; then
              : >"${grafts_path}"
            fi
            printf '%s\n' "${grafts_path}"
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
        [[ "${saw_empty_hooks}" -eq 1 ]] || exit 97
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
        [[ "${GIT_GRAFT_FILE:-}" == /dev/null ]] || exit 95
        [[ "${MOCK_DIVERGED:-0}" != 1 ]] || exit 73
        ;;
      for-each-ref)
        if [[ "${MOCK_REPLACE_REF:-0}" == 1 ]]; then
          printf '%s\n' 'refs/replace/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        fi
        ;;
      config)
        if [[ "${3:-}" == '^url\..*\.(insteadof|pushinsteadof)$' ]]; then
          url_config_count="$(increment_counter url-config-count)"
          [[ "${MOCK_URL_REWRITE_CONFIG_ERROR:-0}" != 1 ]] || exit 2
          if [[ "${MOCK_URL_REWRITE_CONFIG:-0}" == 1 \
              || ( "${MOCK_URL_REWRITE_AFTER_CANDIDATE_CI:-0}" == 1 \
                && -f "${MOCK_STATE_DIR:?}/candidate-ci-observed" ) ]]; then
            printf '%s\n' 'url.alias.insteadof https://github.com/'
            exit 0
          fi
          exit 1
        elif [[ "${MOCK_TRAILER_CONFIG_ERROR:-0}" == 1 ]]; then
          exit 2
        elif [[ "${MOCK_TRAILER_CONFIG:-0}" == 1 ]]; then
          printf '%s\n' 'trailer.alias.key DroidMatch-Risk'
          exit 0
        fi
        exit 1
        ;;
      remote)
        [[ "${2:-}" == get-url ]] || exit 96
        if [[ "$*" == *' --push '* ]]; then
          printf '%s\n' "${MOCK_PUSH_URLS-https://github.com/FoxBai/DroidMatch.git}"
        else
          printf '%s\n' "${MOCK_FETCH_URLS-https://github.com/FoxBai/DroidMatch.git}"
        fi
        ;;
      rev-list)
        [[ "${GIT_GRAFT_FILE:-}" == /dev/null ]] || exit 95
        printf '%s\n' "${MOCK_CANDIDATE_SHA:?}"
        if [[ -n "${MOCK_SECOND_CANDIDATE_SHA:-}" ]]; then
          printf '%s\n' "${MOCK_SECOND_CANDIDATE_SHA}"
        fi
        ;;
      show)
        [[ "${GIT_GRAFT_FILE:-}" == /dev/null ]] || exit 95
        if [[ -n "${MOCK_SECOND_CANDIDATE_SHA:-}" \
            && "${*: -1}" == "${MOCK_SECOND_CANDIDATE_SHA}" ]]; then
          printf 'DroidMatch-Risk: %s\n' "${MOCK_SECOND_RISK_TRAILER-R0}"
        elif [[ "${MOCK_RISK_TRAILER_MISSING:-0}" == 1 ]]; then
          :
        else
          printf 'DroidMatch-Risk: %s\n' "${MOCK_RISK_TRAILER-R0}"
        fi
        ;;
      check-ref-format)
        ;;
      ls-remote)
        [[ "${saw_empty_hooks}" -eq 1 ]] || exit 97
        [[ "${MOCK_REF_QUERY_FAIL:-0}" != 1 ]] || exit 79
        if [[ -f "${MOCK_STATE_DIR:?}/candidate-tip" ]]; then
          printf '%s\t%s\n' "$(<"${MOCK_STATE_DIR}/candidate-tip")" "${@: -1}"
        fi
        ;;
      push)
        [[ "${saw_empty_hooks}" -eq 1 ]] || exit 97
        refspec="${@: -1}"
        if [[ "${refspec}" == ':refs/heads/codex/main-gate/'* ]]; then
          if [[ "${MOCK_CLEANUP_REF_ADVANCED:-0}" == 1 ]]; then
            printf '%s\n' "${MOCK_ADVANCED_SHA:?}" >"${MOCK_STATE_DIR}/candidate-tip"
          fi
          [[ "${MOCK_CLEANUP_FAIL:-0}" != 1 ]] || exit 74
          [[ -f "${MOCK_STATE_DIR}/candidate-tip" ]] || exit 74
          lease_argument=""
          for argument in "$@"; do
            if [[ "${argument}" == --force-with-lease=* ]]; then
              lease_argument="${argument}"
            fi
          done
          expected_sha="${lease_argument##*:}"
          [[ "$(<"${MOCK_STATE_DIR}/candidate-tip")" == "${expected_sha}" ]] || exit 74
          rm "${MOCK_STATE_DIR}/candidate-tip"
          : >"${MOCK_STATE_DIR}/cleanup"
          [[ "${MOCK_CLEANUP_APPLIED_ON_FAILURE:-0}" != 1 ]] || exit 74
          exit 0
        fi
        if [[ "${refspec}" == *':refs/heads/codex/main-gate/'* ]]; then
          candidate_ref="${refspec#*:refs/heads/}"
          printf '%s\n' "${candidate_ref}" >"${MOCK_STATE_DIR}/candidate-ref"
          if [[ "${MOCK_REF_EXISTS:-0}" == 1 ]]; then
            printf '%s\n' "${MOCK_CANDIDATE_SHA:?}" >"${MOCK_STATE_DIR}/candidate-tip"
            printf '%s\t%s\t%s\n' '=' "${refspec}" '[up to date]'
            exit 0
          elif [[ "${MOCK_REF_EXISTS_OTHER:-0}" == 1 ]]; then
            printf '%s\n' "${MOCK_BASE_SHA:?}" >"${MOCK_STATE_DIR}/candidate-tip"
            exit 75
          elif [[ "${MOCK_CANDIDATE_PUSH_APPLIED_ON_FAILURE:-0}" == 1 ]]; then
            printf '%s\n' "${MOCK_CANDIDATE_SHA:?}" >"${MOCK_STATE_DIR}/candidate-tip"
            exit 75
          fi
          [[ "${MOCK_CANDIDATE_PUSH_FAIL:-0}" != 1 ]] || exit 75
          printf '%s\n' "${MOCK_CANDIDATE_SHA:?}" >"${MOCK_STATE_DIR}/candidate-tip"
          printf '%s\t%s\t%s\n' '*' "${refspec}" '[new branch]'
          if [[ "${MOCK_EXTRA_PUSH_RECORD:-0}" == 1 ]]; then
            printf '%s\t%s\t%s\n' ' ' "${MOCK_BASE_SHA}:refs/heads/unexpected" 'fast-forward'
          fi
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
              : >"${MOCK_STATE_DIR}/candidate-ci-observed"
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
    tool_arguments=("$@")
    if [[ "${MOCK_OMIT_R0_ATTESTATION:-0}" != 1 ]]; then
      tool_arguments+=(--attest-r0)
    fi
    "${tool}" "${tool_arguments[@]}"
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
MOCK_OMIT_R0_ATTESTATION=1 expect_failure 2 --confirm-direct-main
grep -q -- '--attest-r0' <<<"${case_output}"
if grep -q '^git push ' "${mock_log}"; then
  printf 'missing R0 attestation must not mutate the remote\n' >&2
  exit 1
fi
reset_case
pass_output="$(run_tool --confirm-direct-main)"
grep -q "Direct-main integration passed: ${candidate_sha}" <<<"${pass_output}"
grep -q 'Candidate run: https://github.com/FoxBai/DroidMatch/actions/runs/101' \
  <<<"${pass_output}"
grep -q 'Main run: https://github.com/FoxBai/DroidMatch/actions/runs/202' \
  <<<"${pass_output}"
candidate_push_line="$(grep -n '^git push --porcelain .*refs/heads/codex/main-gate/' "${mock_log}" | cut -d: -f1)"
preflight_line="$(grep -n '^python3 tools/check-maintainer-contract.py$' "${mock_log}" | cut -d: -f1)"
main_push_line="$(grep -n "^git push --no-verify --no-follow-tags --recurse-submodules=no https://github.com/FoxBai/DroidMatch.git ${candidate_sha}:refs/heads/main" "${mock_log}" | cut -d: -f1)"
cleanup_line="$(grep -n '^git push --quiet .* :refs/heads/codex/main-gate/' "${mock_log}" | cut -d: -f1)"
[[ -n "${preflight_line}" && -n "${candidate_push_line}" \
    && -n "${main_push_line}" && -n "${cleanup_line}" ]]
[[ "${preflight_line}" -lt "${candidate_push_line}" \
    && "${candidate_push_line}" -lt "${main_push_line}" \
    && "${main_push_line}" -lt "${cleanup_line}" ]]
if grep -Eq '(^| )--force( |$)|workflow run|pull-request| pr ' "${mock_log}"; then
  printf 'passing direct-main flow used a forbidden bypass or PR path\n' >&2
  exit 1
fi
[[ "$(grep -c '^git push ' "${mock_log}")" -eq 3 ]]
[[ "$(grep -c '^git push .*--no-verify .*--no-follow-tags .*--recurse-submodules=no' "${mock_log}")" -eq 3 ]]
[[ "$(grep -c '^git fetch ' "${mock_log}")" -eq "$(grep -c '^git fetch --quiet --no-tags --no-prune --recurse-submodules=no https://github.com/FoxBai/DroidMatch.git refs/heads/main:refs/remotes/origin/main$' "${mock_log}")" ]]
awk '/^git (fetch|ls-remote|push) / && index(previous, "git config --get-regexp ^url") != 1 { exit 1 } { previous=$0 }' "${mock_log}"
grep -q "^git push --porcelain .*--force-with-lease=refs/heads/codex/main-gate/[^:]*: https://github.com/FoxBai/DroidMatch.git ${candidate_sha}:refs/heads/codex/main-gate/" "${mock_log}"
grep -q "^git push --quiet .*--force-with-lease=refs/heads/codex/main-gate/[^:]*:${candidate_sha} https://github.com/FoxBai/DroidMatch.git :refs/heads/codex/main-gate/" "${mock_log}"
grep -q '^git status --porcelain=v1 --untracked-files=all$' "${mock_log}"
grep -q '^git --no-replace-objects merge-base --is-ancestor ' "${mock_log}"
grep -q '^git --no-replace-objects rev-list --reverse ' "${mock_log}"
grep -q '^git --no-replace-objects show -s ' "${mock_log}"
reset_case
transient_fetch_output="$(
  MOCK_FETCH_ERROR_ON_CALL=3 run_tool --confirm-direct-main 2>&1
)"
grep -q "Direct-main integration passed: ${candidate_sha}" \
  <<<"${transient_fetch_output}"
grep -q 'origin/main refresh failed; retrying (1/3)' \
  <<<"${transient_fetch_output}"
[[ "$(<"${state_dir}/fetch-count")" -eq 5 ]]
[[ "$(grep -c '^git push --porcelain .*refs/heads/codex/main-gate/' "${mock_log}")" -eq 1 ]]
[[ "$(grep -c "^git push --no-verify --no-follow-tags .* ${candidate_sha}:refs/heads/main" "${mock_log}")" -eq 1 ]]
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
[[ "$(grep -c "^git push --no-verify --no-follow-tags .* ${candidate_sha}:refs/heads/main" "${mock_log}")" -eq 1 ]]
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
replace_output="$(MOCK_REPLACE_REF=1 run_tool --confirm-direct-main 2>&1)"
replace_status=$?
set -e
[[ "${replace_status}" -eq 1 ]]
grep -q 'local Git replace refs are not allowed' <<<"${replace_output}"
if grep -q '^git push ' "${mock_log}"; then
  printf 'local Git replace refs must fail before remote mutation\n' >&2
  exit 1
fi
reset_case
set +e
grafts_output="$(MOCK_GRAFTS_PRESENT=1 run_tool --confirm-direct-main 2>&1)"
grafts_status=$?
set -e
[[ "${grafts_status}" -eq 1 ]]
grep -q 'a local Git grafts file is not allowed' <<<"${grafts_output}"
if grep -q '^git push ' "${mock_log}"; then
  printf 'a local Git grafts file must fail before remote mutation\n' >&2
  exit 1
fi
reset_case
set +e
graft_override_output="$(
  GIT_GRAFT_FILE="${state_dir}/alternate-grafts" \
    run_tool --confirm-direct-main 2>&1
)"
graft_override_status=$?
set -e
[[ "${graft_override_status}" -eq 1 ]]
grep -q 'a GIT_GRAFT_FILE override is not allowed' <<<"${graft_override_output}"
if grep -q '^git push ' "${mock_log}"; then
  printf 'a GIT_GRAFT_FILE override must fail before remote mutation\n' >&2
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
MOCK_CANDIDATE_SHA="${base_sha}" expect_failure 1 --confirm-direct-main
grep -q 'HEAD is already live main' <<<"${case_output}"
reset_case
MOCK_DIVERGED=1 expect_failure 1 --confirm-direct-main
grep -q 'HEAD is not a fast-forward descendant' <<<"${case_output}"
reset_case
MOCK_RISK_TRAILER=R1 expect_failure 1 --confirm-direct-main
grep -q 'does not declare exactly DroidMatch-Risk: R0' <<<"${case_output}"
if grep -q '^git push ' "${mock_log}"; then
  printf 'a non-R0 commit trailer must fail before remote mutation\n' >&2
  exit 1
fi
reset_case
MOCK_RISK_TRAILER_MISSING=1 expect_failure 1 --confirm-direct-main
grep -q 'does not declare exactly DroidMatch-Risk: R0' <<<"${case_output}"
! grep -q '^git push ' "${mock_log}"
reset_case
MOCK_TRAILER_CONFIG=1 expect_failure 1 --confirm-direct-main
grep -q 'Git trailer configuration is not allowed' <<<"${case_output}"
! grep -q '^git push ' "${mock_log}"
reset_case
MOCK_URL_REWRITE_CONFIG=1 expect_failure 1 --confirm-direct-main
grep -q 'Git URL rewrite configuration is not allowed' <<<"${case_output}"
! grep -q '^git push ' "${mock_log}"
reset_case
MOCK_URL_REWRITE_CONFIG_ERROR=1 expect_failure 1 --confirm-direct-main
grep -q 'Git URL rewrite configuration could not be verified' <<<"${case_output}"
! grep -q '^git push ' "${mock_log}"
reset_case
MOCK_URL_REWRITE_AFTER_CANDIDATE_CI=1 expect_failure 1 --confirm-direct-main
grep -q 'Git URL rewrite configuration is not allowed' <<<"${case_output}"
[[ "$(grep -c '^git push ' "${mock_log}")" -eq 1 ]]
[[ -f "${state_dir}/candidate-tip" && ! -f "${state_dir}/cleanup" ]]
! grep -q ':refs/heads/main' "${mock_log}"
[[ "$(<"${state_dir}/fetch-count")" -eq 1 ]] && ! grep -q '^git ls-remote ' "${mock_log}"
reset_case
MOCK_PUSH_URLS=$'https://github.com/FoxBai/DroidMatch.git\nhttps://github.com/FoxBai/DroidMatch.git' expect_failure 1 --confirm-direct-main
grep -q 'origin must resolve to exactly one effective push endpoint' <<<"${case_output}"
! grep -q '^git push ' "${mock_log}"
reset_case
MOCK_FETCH_URLS='https://github.com/FoxBai/Other.git' expect_failure 1 --confirm-direct-main
grep -q 'origin fetch/push endpoints do not match' <<<"${case_output}"
! grep -q '^git push ' "${mock_log}"
reset_case
ssh_output="$(MOCK_FETCH_URLS='git@github.com:foxbai/droidmatch.git' MOCK_PUSH_URLS='ssh://git@github.com:22/FoxBai/DroidMatch.git' run_tool --confirm-direct-main)"
grep -q "Direct-main integration passed: ${candidate_sha}" <<<"${ssh_output}"
reset_case
set +e
range_risk_output="$(
  MOCK_SECOND_CANDIDATE_SHA="${second_candidate_sha}" \
  MOCK_SECOND_RISK_TRAILER=R2 \
    run_tool --confirm-direct-main 2>&1
)"
range_risk_status=$?
set -e
[[ "${range_risk_status}" -eq 1 ]]
grep -q "candidate commit ${second_candidate_sha:0:12} does not declare exactly" \
  <<<"${range_risk_output}"
if grep -q '^git push ' "${mock_log}"; then
  printf 'every commit in the candidate range must declare R0\n' >&2
  exit 1
fi
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
grep -q 'did not prove exclusive ref creation' <<<"${ref_collision_output}"
[[ ! -f "${state_dir}/cleanup" && ! -f "${state_dir}/main-pushed" ]]
[[ "$(<"${state_dir}/candidate-tip")" == "${candidate_sha}" ]]
reset_case
MOCK_EXTRA_PUSH_RECORD=1 expect_failure 1 --confirm-direct-main
grep -q 'did not prove exclusive ref creation' <<<"${case_output}"
[[ ! -f "${state_dir}/cleanup" && ! -f "${state_dir}/main-pushed" ]]
reset_case
set +e
ambiguous_candidate_output="$(
  MOCK_CANDIDATE_PUSH_APPLIED_ON_FAILURE=1 run_tool --confirm-direct-main 2>&1
)"
ambiguous_candidate_status=$?
set -e
[[ "${ambiguous_candidate_status}" -eq 1 ]]
grep -q 'creator is ambiguous' <<<"${ambiguous_candidate_output}" && grep -q 'attempted temporary gate ref' <<<"${ambiguous_candidate_output}" && grep -q '^git ls-remote --heads https://github.com/FoxBai/DroidMatch.git refs/heads/codex/main-gate/' "${mock_log}"
awk '/^git (fetch|ls-remote|push) / && index(previous, "git config --get-regexp ^url") != 1 { exit 1 } { previous=$0 }' "${mock_log}"
[[ ! -f "${state_dir}/cleanup" && ! -f "${state_dir}/main-pushed" ]]
[[ "$(<"${state_dir}/candidate-tip")" == "${candidate_sha}" ]]
reset_case
set +e
cleanup_race_output="$(MOCK_CLEANUP_REF_ADVANCED=1 run_tool --confirm-direct-main 2>&1)"
cleanup_race_status=$?
set -e
[[ "${cleanup_race_status}" -eq 1 ]]
grep -q 'changed ownership; exact-lease cleanup refused' <<<"${cleanup_race_output}"
[[ -f "${state_dir}/main-pushed" && ! -f "${state_dir}/cleanup" ]]
[[ "$(<"${state_dir}/candidate-tip")" == "${advanced_sha}" ]]
reset_case
cleanup_applied_output="$(
  MOCK_CLEANUP_APPLIED_ON_FAILURE=1 run_tool --confirm-direct-main 2>&1
)"
grep -q "Direct-main integration passed: ${candidate_sha}" <<<"${cleanup_applied_output}"
[[ -f "${state_dir}/cleanup" && ! -f "${state_dir}/candidate-tip" ]]
reset_case
MOCK_CANDIDATE_PUSH_FAIL=1 expect_failure 1 --confirm-direct-main
grep -q 'temporary candidate push was rejected or its result was ambiguous' <<<"${case_output}"
[[ ! -f "${state_dir}/cleanup" && ! -f "${state_dir}/main-pushed" ]]
reset_case
MOCK_CLEANUP_FAIL=1 expect_failure 1 --confirm-direct-main
grep -q 'main was pushed but temporary gate ref cleanup failed' <<<"${case_output}"
[[ -f "${state_dir}/main-pushed" && ! -f "${state_dir}/cleanup" ]]
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
