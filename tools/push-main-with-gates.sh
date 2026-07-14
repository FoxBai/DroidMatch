#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

readonly remote_name="origin"
readonly target_branch="main"
readonly workflow_name="Spec and Skeleton Gates"
readonly discovery_attempts=30
readonly discovery_interval_seconds=2
readonly completion_attempts=360
readonly completion_interval_seconds=10
readonly main_refresh_attempts=3
readonly main_refresh_interval_seconds=2
readonly protection_read_attempts=3
readonly protection_read_interval_seconds=2

confirmed=0
repo=""
candidate_sha=""
base_sha=""
candidate_ref=""
temporary_ref_created=0

usage() {
  cat <<'USAGE'
Usage: tools/push-main-with-gates.sh --confirm-direct-main

Safely fast-forwards the current clean HEAD directly to protected main without
a pull request. The exact SHA first runs all required hosted gates on a unique
temporary push ref. The script rechecks main and Phase A before a non-forced
push, removes its temporary ref, and waits for the exact main-push CI.

安全地把当前干净 HEAD 无 PR 快进直推到受保护 main：先在唯一临时 push ref 上为
同一 SHA 跑完必需门禁，再复核 main 与 Phase A，执行非强制 push，清理临时 ref，
并等待精确 main-push CI。

Options:
  --confirm-direct-main   Required explicit confirmation for remote mutation.
                          远端写入所需的显式确认。
  -h, --help              Show this help.
USAGE
}

fail() {
  printf 'direct-main integration refused: %s\n' "$1" >&2
  printf '直推 main 已拒绝：%s\n' "$2" >&2
  exit 1
}

usage_error() {
  printf 'direct-main integration requires --confirm-direct-main.\n' >&2
  printf '直推 main 必须显式传入 --confirm-direct-main。\n' >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm-direct-main)
      confirmed=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error
      ;;
  esac
done

[[ "${confirmed}" -eq 1 ]] || usage_error

for command_name in git gh date sleep; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "required command is unavailable: ${command_name}" \
      "缺少必需命令：${command_name}"
done

cleanup_temporary_ref() {
  if [[ "${temporary_ref_created}" -ne 1 || -z "${candidate_ref}" ]]; then
    return 0
  fi
  if GIT_TERMINAL_PROMPT=0 git push --quiet "${remote_name}" \
      --delete "${candidate_ref}" >/dev/null 2>&1; then
    temporary_ref_created=0
    return 0
  fi
  printf 'WARNING temporary gate ref cleanup failed: %s\n' \
    "${candidate_ref}" >&2
  printf '警告：临时 gate ref 清理失败：%s\n' "${candidate_ref}" >&2
  return 1
}

trap 'cleanup_temporary_ref || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

refresh_main() {
  local attempt
  for ((attempt = 1; attempt <= main_refresh_attempts; attempt += 1)); do
    if GIT_TERMINAL_PROMPT=0 git fetch --quiet "${remote_name}" \
        "refs/heads/${target_branch}:refs/remotes/${remote_name}/${target_branch}"; then
      return 0
    fi

    if [[ "${attempt}" -lt "${main_refresh_attempts}" ]]; then
      printf 'WARNING origin/main refresh failed; retrying (%s/%s).\n' \
        "${attempt}" "${main_refresh_attempts}" >&2
      printf '警告：origin/main 刷新失败；正在重试（%s/%s）。\n' \
        "${attempt}" "${main_refresh_attempts}" >&2
      sleep "${main_refresh_interval_seconds}"
    fi
  done
  return 1
}

read_origin_main() {
  git rev-parse "refs/remotes/${remote_name}/${target_branch}" 2>/dev/null
}

read_phase_a_state() {
  local attempt state
  for ((attempt = 1; attempt <= protection_read_attempts; attempt += 1)); do
    if state="$(gh api "repos/${repo}/branches/${target_branch}/protection" --jq '
      if (
        .required_status_checks.strict == true and
        ((["spec", "mac-skeleton", "android-skeleton"]
          - .required_status_checks.contexts) | length == 0) and
        .required_pull_request_reviews == null and
        .required_conversation_resolution.enabled == true and
        .required_linear_history.enabled == true and
        .enforce_admins.enabled == true and
        .allow_force_pushes.enabled == false and
        .allow_deletions.enabled == false
      ) then "valid" else "invalid" end
    ' 2>/dev/null)" && [[ "${state}" == valid || "${state}" == invalid ]]; then
      printf '%s' "${state}"
      return 0
    fi

    if [[ "${attempt}" -lt "${protection_read_attempts}" ]]; then
      printf 'WARNING main protection read failed; retrying (%s/%s).\n' \
        "${attempt}" "${protection_read_attempts}" >&2
      printf '警告：main 分支保护读取失败；正在重试（%s/%s）。\n' \
        "${attempt}" "${protection_read_attempts}" >&2
      sleep "${protection_read_interval_seconds}"
    fi
  done
  return 1
}

require_phase_a() {
  local stage_en="$1"
  local stage_zh="$2"
  local state
  state="$(read_phase_a_state)" \
    || fail "main protection is unreadable after ${protection_read_attempts} attempts ${stage_en}" \
      "${stage_zh}，main 分支保护连续 ${protection_read_attempts} 次不可读"
  [[ "${state}" == valid ]] \
    || fail "main protection differs from Phase A ${stage_en}" \
      "${stage_zh}，main 分支保护偏离 Phase A"
}

find_push_run() {
  local branch="$1"
  local sha="$2"
  local attempt run_id
  for ((attempt = 1; attempt <= discovery_attempts; attempt += 1)); do
    run_id="$(gh run list \
      --repo "${repo}" \
      --workflow "${workflow_name}" \
      --branch "${branch}" \
      --commit "${sha}" \
      --event push \
      --limit 1 \
      --json databaseId \
      --jq '.[0].databaseId // empty' 2>/dev/null || true)"
    if [[ "${run_id}" =~ ^[0-9]+$ ]]; then
      printf '%s' "${run_id}"
      return 0
    fi
    sleep "${discovery_interval_seconds}"
  done
  return 1
}

wait_for_successful_push_run() {
  local run_id="$1"
  local expected_branch="$2"
  local expected_sha="$3"
  local label="$4"
  local attempt state="" previous_status="" status conclusion event branch sha

  for ((attempt = 1; attempt <= completion_attempts; attempt += 1)); do
    state="$(gh run view "${run_id}" \
      --repo "${repo}" \
      --json status,conclusion,event,headBranch,headSha \
      --jq '[.status, (.conclusion // ""), .event, .headBranch, .headSha] | join("|")' \
      2>/dev/null || true)"
    if [[ -z "${state}" ]]; then
      sleep "${completion_interval_seconds}"
      continue
    fi

    IFS='|' read -r status conclusion event branch sha <<<"${state}"
    if [[ "${event}" != push || "${branch}" != "${expected_branch}" \
        || "${sha}" != "${expected_sha}" ]]; then
      fail "${label} run identity differs from the exact push candidate" \
        "${label} 的 run 身份与精确 push 候选不一致"
    fi

    if [[ "${status}" != "${previous_status}" ]]; then
      printf '%s run %s: %s\n' "${label}" "${run_id}" "${status}"
      previous_status="${status}"
    fi
    if [[ "${status}" == completed ]]; then
      if [[ "${conclusion}" == success ]]; then
        return 0
      fi
      fail "${label} run completed with ${conclusion:-no conclusion}" \
        "${label} run 已结束但结果为 ${conclusion:-无结果}"
    fi
    sleep "${completion_interval_seconds}"
  done

  fail "${label} run did not complete within the bounded wait" \
    "${label} run 未在有界等待时间内完成"
}

worktree_status="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null)" \
  || fail 'worktree state could not be verified' '无法验证工作区状态'
[[ -z "${worktree_status}" ]] \
  || fail 'worktree has uncommitted changes' '工作区存在未提交修改'

candidate_sha="$(git rev-parse HEAD 2>/dev/null)" \
  || fail 'HEAD is unavailable' '无法读取 HEAD'
[[ "${candidate_sha}" =~ ^[0-9a-f]{40}$ ]] \
  || fail 'HEAD is not a full lowercase Git commit SHA' 'HEAD 不是完整的小写 Git commit SHA'

gh auth status >/dev/null 2>&1 \
  || fail 'authenticated GitHub CLI is unavailable' 'GitHub CLI 未登录或不可用'
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
  || fail 'repository identity could not be resolved' '无法读取仓库身份'
[[ "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || fail 'repository identity has an unexpected shape' '仓库身份格式异常'

refresh_main \
  || fail 'origin/main could not be refreshed' '无法刷新 origin/main'
base_sha="$(read_origin_main)" \
  || fail 'origin/main is unavailable after fetch' 'fetch 后仍无法读取 origin/main'

if [[ "${candidate_sha}" == "${base_sha}" ]]; then
  fail 'HEAD is already live main; no candidate integration was performed' \
    'HEAD 已是远端 main；本次没有候选集成可执行'
fi

git merge-base --is-ancestor "${base_sha}" "${candidate_sha}" >/dev/null 2>&1 \
  || fail 'HEAD is not a fast-forward descendant of live main' \
    'HEAD 不是远端 main 的可快进后代'
require_phase_a 'before candidate CI' '候选 CI 前'

run_suffix="$(date -u '+%Y%m%dT%H%M%SZ')" \
  || fail 'could not create the temporary gate ref timestamp' \
    '无法生成临时 gate ref 时间戳'
candidate_ref="codex/main-gate/${candidate_sha:0:12}-${run_suffix}-$$-${RANDOM}"
git check-ref-format "refs/heads/${candidate_ref}" >/dev/null 2>&1 \
  || fail 'generated temporary gate ref is invalid' '生成的临时 gate ref 无效'
existing_candidate_ref="$(git ls-remote --heads "${remote_name}" \
  "refs/heads/${candidate_ref}" 2>/dev/null)" \
  || fail 'temporary gate ref availability could not be verified' \
    '无法验证临时 gate ref 是否可用'
[[ -z "${existing_candidate_ref}" ]] \
  || fail 'generated temporary gate ref already exists' \
    '生成的临时 gate ref 已存在'

printf 'Staging exact candidate %s on %s.\n' \
  "${candidate_sha}" "${candidate_ref}"
printf '正在临时 ref %s 上验证精确候选 %s。\n' \
  "${candidate_ref}" "${candidate_sha}"
GIT_TERMINAL_PROMPT=0 git push "${remote_name}" \
  "${candidate_sha}:refs/heads/${candidate_ref}" \
  || fail 'temporary candidate push was rejected' '临时候选 push 被拒绝'
temporary_ref_created=1

candidate_run_id="$(find_push_run "${candidate_ref}" "${candidate_sha}")" \
  || fail 'candidate push run was not discovered' '未找到候选 push run'
wait_for_successful_push_run \
  "${candidate_run_id}" "${candidate_ref}" "${candidate_sha}" 'candidate'

# Re-fetch both the target and its protection after the potentially long hosted
# run. A green candidate is stale the moment another integration advances main.
# 中文：托管门禁结束后同时复核 main 与保护，避免旧绿色结果继续写入新基线。
refresh_main \
  || fail 'origin/main could not be refreshed after candidate CI' \
    '候选 CI 后无法刷新 origin/main'
post_gate_main_sha="$(read_origin_main)" \
  || fail 'origin/main became unreadable after candidate CI' \
    '候选 CI 后 origin/main 变得不可读'
[[ "${post_gate_main_sha}" == "${base_sha}" ]] \
  || fail 'main advanced during candidate CI; rebuild and rerun' \
    '候选 CI 期间 main 已前移，必须重建并重跑'
require_phase_a 'after candidate CI' '候选 CI 后'

printf 'Candidate gates passed; fast-forwarding protected main without force.\n'
printf '候选门禁已通过；正在以非强制方式快进受保护 main。\n'
GIT_TERMINAL_PROMPT=0 git push "${remote_name}" \
  "${candidate_sha}:refs/heads/${target_branch}" \
  || fail 'protected main rejected the non-forced fast-forward' \
    '受保护 main 拒绝了非强制快进'

refresh_main \
  || fail 'origin/main could not be refreshed after push' 'push 后无法刷新 origin/main'
pushed_main_sha="$(read_origin_main)" \
  || fail 'origin/main is unreadable after push' 'push 后无法读取 origin/main'
[[ "${pushed_main_sha}" == "${candidate_sha}" ]] \
  || fail 'remote main does not equal the pushed candidate' \
    '远端 main 与已 push 候选不一致'

cleanup_temporary_ref \
  || fail 'main was pushed but temporary gate ref cleanup failed' \
    'main 已 push，但临时 gate ref 清理失败'

main_run_id="$(find_push_run "${target_branch}" "${candidate_sha}")" \
  || fail 'exact main-push run was not discovered after integration' \
    '集成后未找到精确 main-push run'
wait_for_successful_push_run \
  "${main_run_id}" "${target_branch}" "${candidate_sha}" 'main'

refresh_main \
  || fail 'origin/main could not be refreshed after main CI' \
    'main CI 后无法刷新 origin/main'
final_main_sha="$(read_origin_main)" \
  || fail 'origin/main is unreadable after main CI' 'main CI 后无法读取 origin/main'
[[ "${final_main_sha}" == "${candidate_sha}" ]] \
  || fail 'main advanced while exact-main CI was running' \
    '精确 main CI 运行期间 main 已前移'
require_phase_a 'after exact-main CI' '精确 main CI 后'

printf 'Direct-main integration passed: %s\n' "${candidate_sha}"
printf '直推 main 集成通过：%s\n' "${candidate_sha}"
printf 'Candidate run: https://github.com/%s/actions/runs/%s\n' \
  "${repo}" "${candidate_run_id}"
printf 'Main run: https://github.com/%s/actions/runs/%s\n' \
  "${repo}" "${main_run_id}"
