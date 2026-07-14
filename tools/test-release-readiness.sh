#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mock_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-release-readiness.XXXXXX")"
trap 'rm -rf "${mock_root}"' EXIT

mkdir -p "${mock_root}/bin" "${mock_root}/DroidMatch.app"

cat > "${mock_root}/bin/mock-command" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

case "$(basename "$0")" in
  git)
    if [[ "${1:-}" == "rev-parse" ]]; then
      printf '%s\n' '0123456789abcdef0123456789abcdef01234567'
    elif [[ "${1:-}" == "status" ]]; then
      [[ "${MOCK_GIT_STATUS_FAILURE:-0}" != "1" ]] || exit 1
      if [[ "${MOCK_DIRTY:-0}" == "1" ]]; then
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
    if [[ "${MOCK_SIGNATURE:-0}" == "1" ]]; then
      printf '%s\n' 'Authority=Developer ID Application: TEST-SUBJECT-DO-NOT-LEAK' >&2
    else
      exit 1
    fi
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
            printf '%s\n' "${MOCK_MAIN_SHA:-0123456789abcdef0123456789abcdef01234567}"
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
for command in git security xcrun codesign gh; do
  ln -s mock-command "${mock_root}/bin/${command}"
done

run_preflight() {
  PATH="${mock_root}/bin:${PATH}" "${repo_root}/tools/check-release-readiness.sh" "$@"
}

pass_output="$(
  MOCK_IDENTITY=1 \
  MOCK_NOTARYTOOL=1 \
  MOCK_SIGNATURE=1 \
  MOCK_STAPLE=1 \
  MOCK_PROTECTION_STATE=valid \
  MOCK_RUN_STATE='completed:success' \
  run_preflight --github --artifact "${mock_root}/DroidMatch.app"
)"
grep -q 'Automated release preflight passed' <<<"${pass_output}"
if grep -q 'BLOCKED\|TEST-SUBJECT-DO-NOT-LEAK' <<<"${pass_output}"; then
  printf 'release preflight leaked a subject or blocked the passing fixture\n' >&2
  exit 1
fi

set +e
governance_output="$(
  MOCK_IDENTITY=1 \
  MOCK_NOTARYTOOL=1 \
  MOCK_SIGNATURE=1 \
  MOCK_STAPLE=1 \
  MOCK_PROTECTION_STATE=invalid \
  MOCK_RUN_STATE='completed:success' \
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
  MOCK_RUN_STATE='completed:success' \
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
  MOCK_RUN_STATE='completed:success' \
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
  MOCK_RUN_STATE='completed:success' \
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
blocked_output="$(
  MOCK_DIRTY=1 \
  MOCK_RUN_STATE='in_progress:' \
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
grep -q 'hosted gates for exact HEAD could not be read' <<<"${failure_output}"
if grep -q 'private-user-name\|Missing.app' <<<"${failure_output}"; then
  printf 'release preflight leaked an artifact path\n' >&2
  exit 1
fi

printf 'Release readiness preflight tests passed.\n'
printf '中文：发布就绪预检测试通过。\n'
