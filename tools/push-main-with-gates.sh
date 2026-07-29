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
readonly main_push_attempts=3
readonly main_push_interval_seconds=2
readonly protection_read_attempts=3
readonly protection_read_interval_seconds=2

confirmed=0
r0_attested=0
repo=""
candidate_sha=""
base_sha=""
candidate_ref=""
temporary_ref_created=0
fetch_url=""
push_url=""

usage() {
  cat <<'USAGE'
Usage: tools/push-main-with-gates.sh --confirm-direct-main --attest-r0

Safely fast-forwards an R0-only current clean HEAD directly to protected main
without a pull request. The exact SHA first runs all required hosted gates on a
unique temporary push ref. The script rechecks main and Phase A before a
non-forced push, removes only a proven-owned unchanged temporary ref under an
exact lease, and waits for the exact main-push CI. An ambiguous temporary ref is
not auto-deleted. Every candidate commit must contain the Git trailer
`DroidMatch-Risk: R0`.

仅把已确认属于 R0 的当前干净 HEAD 无 PR 快进直推到受保护 main：先在唯一临时
push ref 上为同一 SHA 跑完必需门禁，再复核 main 与 Phase A，执行非强制 push，
以精确租约清理已证明属于本次且未变化的临时 ref，并等待精确 main-push CI。结果
有歧义的临时 ref 不会自动删除。每个候选 commit 都必须包含 Git trailer
`DroidMatch-Risk: R0`。

Options:
  --confirm-direct-main   Required explicit confirmation for remote mutation.
                          远端写入所需的显式确认。
  --attest-r0             Attest that the candidate satisfies the documented R0
                          boundary and does not require a pull request.
                          确认候选满足文档中的 R0 边界，无需 PR。
  -h, --help              Show this help.
USAGE
}

fail() {
  printf 'direct-main integration refused: %s\n' "$1" >&2
  printf '直推 main 已拒绝：%s\n' "$2" >&2
  exit 1
}

usage_error() {
  printf 'direct-main integration requires --confirm-direct-main and --attest-r0.\n' >&2
  printf '直推 main 必须显式传入 --confirm-direct-main 与 --attest-r0。\n' >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm-direct-main)
      confirmed=1
      shift
      ;;
    --attest-r0)
      r0_attested=1
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
[[ "${r0_attested}" -eq 1 ]] || usage_error

for command_name in git gh date sleep python3; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "required command is unavailable: ${command_name}" \
      "缺少必需命令：${command_name}"
done

require_no_url_rewrite_config() {
  local cleanup_mode="${1:-0}"
  local status
  git config --get-regexp '^url\..*\.(insteadof|pushinsteadof)$' \
    >/dev/null 2>&1 && status=0 || status=$?
  [[ "${status}" -eq 1 ]] && return 0
  if [[ "${cleanup_mode}" -eq 1 ]]; then
    if [[ "${status}" -eq 0 ]]; then
      printf 'WARNING temporary gate ref cleanup refused because Git URL rewrite configuration appeared.\n' >&2
      printf '警告：检测到新增 Git URL 重写配置；拒绝清理临时 gate ref。\n' >&2
    else
      printf 'WARNING temporary gate ref cleanup refused because Git URL rewrite configuration could not be verified.\n' >&2
      printf '警告：无法验证 Git URL 重写配置；拒绝清理临时 gate ref。\n' >&2
    fi
    return 1
  fi
  if [[ "${status}" -eq 0 ]]; then
    fail 'Git URL rewrite configuration is not allowed for direct integration' \
      '直推集成不允许存在 Git URL 重写配置'
  fi
  fail 'Git URL rewrite configuration could not be verified' \
    '无法验证 Git URL 重写配置'
}

cleanup_temporary_ref() {
  local observed_sha
  if [[ "${temporary_ref_created}" -ne 1 || -z "${candidate_ref}" ]]; then
    return 0
  fi
  require_no_url_rewrite_config 1 || return 1
  if GIT_TERMINAL_PROMPT=0 git -c core.hooksPath=/dev/null push \
      --quiet --no-verify --no-follow-tags --recurse-submodules=no \
      --force-with-lease="refs/heads/${candidate_ref}:${candidate_sha}" \
      "${push_url}" ":refs/heads/${candidate_ref}" >/dev/null 2>&1; then
    temporary_ref_created=0
    return 0
  fi
  if observed_sha="$(read_remote_candidate_sha)"; then
    if [[ -z "${observed_sha}" ]]; then
      temporary_ref_created=0
      return 0
    fi
    if [[ "${observed_sha}" != "${candidate_sha}" ]]; then
      temporary_ref_created=0
      printf 'WARNING temporary gate ref changed ownership; exact-lease cleanup refused: %s\n' \
        "${candidate_ref}" >&2
      printf '警告：临时 gate ref 的所有权已变化；精确租约拒绝清理：%s\n' \
        "${candidate_ref}" >&2
      return 1
    fi
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
    require_no_url_rewrite_config
    if GIT_TERMINAL_PROMPT=0 git -c core.hooksPath=/dev/null fetch \
        --quiet --no-tags --no-prune --recurse-submodules=no "${fetch_url}" \
        "refs/heads/${target_branch}:refs/remotes/${remote_name}/${target_branch}"; then
      return 0
    fi
    if [[ "${attempt}" -lt "${main_refresh_attempts}" ]]; then
      printf 'WARNING %s/%s refresh failed; retrying (%s/%s).\n' \
        "${remote_name}" "${target_branch}" \
        "${attempt}" "${main_refresh_attempts}" >&2
      printf '警告：%s/%s 刷新失败；正在重试（%s/%s）。\n' \
        "${remote_name}" "${target_branch}" \
        "${attempt}" "${main_refresh_attempts}" >&2
      sleep "${main_refresh_interval_seconds}"
    fi
  done
  return 1
}

read_origin_main() {
  git rev-parse "refs/remotes/${remote_name}/${target_branch}" 2>/dev/null
}

read_remote_candidate_sha() {
  local listing sha ref extra
  [[ -n "${candidate_ref}" ]] || return 1
  require_no_url_rewrite_config
  listing="$(GIT_TERMINAL_PROMPT=0 git -c core.hooksPath=/dev/null \
    ls-remote --heads "${push_url}" "refs/heads/${candidate_ref}" \
    2>/dev/null)" || return 1
  if [[ -z "${listing}" ]]; then
    return 0
  fi
  [[ "${listing}" != *$'\n'* ]] || return 1
  IFS=$'\t' read -r sha ref extra <<<"${listing}"
  [[ "${sha}" =~ ^[0-9a-f]{40}$ && -z "${extra:-}" \
      && "${ref}" == "refs/heads/${candidate_ref}" ]] || return 1
  printf '%s' "${sha}"
}

read_single_remote_url() {
  local direction="$1"
  local output
  if [[ "${direction}" == fetch ]]; then
    output="$(git remote get-url --all "${remote_name}" 2>/dev/null)" || return 1
  elif [[ "${direction}" == push ]]; then
    output="$(git remote get-url --push --all "${remote_name}" 2>/dev/null)" \
      || return 1
  else
    return 1
  fi
  [[ -n "${output}" && "${output}" != *$'\n'* ]] || return 1
  printf '%s' "${output}"
}

github_repository_from_url() {
  local url="$1"
  local owner repository
  if [[ "${url}" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/?$ \
      || "${url}" =~ ^git@github\.com:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ \
      || "${url}" =~ ^ssh://git@github\.com(:22)?/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/?$ \
      || "${url}" =~ ^ssh://git@ssh\.github\.com:443/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/?$ ]]; then
    if [[ "${url}" == ssh://git@github.com/* \
        || "${url}" == ssh://git@github.com:22/* ]]; then
      owner="${BASH_REMATCH[2]}"
      repository="${BASH_REMATCH[3]}"
    else
      owner="${BASH_REMATCH[1]}"
      repository="${BASH_REMATCH[2]}"
    fi
  else
    return 1
  fi
  repository="${repository%.git}"
  [[ -n "${owner}" && -n "${repository}" ]] || return 1
  printf '%s/%s' "${owner}" "${repository}"
}

same_repository_identity() {
  local left="$1"
  local right="$2"
  local restore_nocase=0
  local result=1
  if ! shopt -q nocasematch; then
    shopt -s nocasematch
    restore_nocase=1
  fi
  [[ "${left}" == "${right}" ]] && result=0
  if [[ "${restore_nocase}" -eq 1 ]]; then
    shopt -u nocasematch
  fi
  return "${result}"
}

is_transient_main_push_failure() {
  local output="$1"
  local line
  local pattern='^fatal: unable to access .+: (Could not resolve (host|proxy):|Failed to connect to .+ port [0-9]+|Connection timed out|Connection reset by peer|Operation timed out|Recv failure:.*Connection reset by peer)'
  while IFS= read -r line; do
    [[ "${line}" =~ ${pattern} ]] && return 0
  done <<<"${output}"
  return 1
}

push_main_with_recovery() {
  local attempt push_output observed_sha
  for ((attempt = 1; attempt <= main_push_attempts; attempt += 1)); do
    require_no_url_rewrite_config
    if push_output="$(GIT_TERMINAL_PROMPT=0 git -c core.hooksPath=/dev/null push \
        --no-verify --no-follow-tags --recurse-submodules=no "${push_url}" \
        "${candidate_sha}:refs/heads/${target_branch}" 2>&1)"; then
      [[ -z "${push_output}" ]] || printf '%s\n' "${push_output}" >&2
      return 0
    fi
    [[ -z "${push_output}" ]] || printf '%s\n' "${push_output}" >&2

    # A failed client result can arrive after the server accepted the update.
    # Read the exact remote tip before deciding whether any retry is safe.
    # 中文：客户端失败可能晚于服务端成功；任何重试前先读取精确远端 tip。
    refresh_main \
      || fail 'main push failed and its remote result could not be determined' \
        'main push 失败，且无法确定远端结果'
    observed_sha="$(read_origin_main)" \
      || fail 'main push failed and refreshed origin/main is unreadable' \
        'main push 失败，刷新后的 origin/main 不可读'
    if [[ "${observed_sha}" == "${candidate_sha}" ]]; then
      printf 'WARNING main already equals the candidate after a failed local push result; continuing.\n' >&2
      printf '警告：本地 push 返回失败，但 main 已等于候选；继续验证。\n' >&2
      return 0
    fi
    [[ "${observed_sha}" == "${base_sha}" ]] \
      || fail 'main changed after an ambiguous push result; refusing to retry' \
        'push 结果有歧义后 main 已变化；拒绝重试'

    is_transient_main_push_failure "${push_output}" || return 1
    [[ "${attempt}" -lt "${main_push_attempts}" ]] \
      || fail "main push transport failed after ${main_push_attempts} attempts" \
        "main push 传输连续 ${main_push_attempts} 次失败"
    printf 'WARNING main push transport failed with main unchanged; retrying (%s/%s).\n' \
      "${attempt}" "${main_push_attempts}" >&2
    printf '警告：main push 传输失败且 main 未变化；正在重试（%s/%s）。\n' \
      "${attempt}" "${main_push_attempts}" >&2
    sleep "${main_push_interval_seconds}"
    require_phase_a 'before retrying main push' '重试 main push 前'
    refresh_main \
      || fail 'origin/main could not be refreshed immediately before a push retry' \
        '无法在 push 重试紧前刷新 origin/main'
    observed_sha="$(read_origin_main)" \
      || fail 'origin/main is unreadable immediately before a push retry' \
        'push 重试紧前无法读取 origin/main'
    if [[ "${observed_sha}" == "${candidate_sha}" ]]; then
      printf 'WARNING main became the candidate before the push retry; continuing without another write.\n' >&2
      printf '警告：push 重试前 main 已变为候选；不重复写入并继续验证。\n' >&2
      return 0
    fi
    [[ "${observed_sha}" == "${base_sha}" ]] \
      || fail 'main changed immediately before a push retry; refusing to write' \
        'push 重试紧前 main 已变化；拒绝写入'
  done
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

worktree_status="$(git -c core.fsmonitor=false -c core.hooksPath=/dev/null \
  status --porcelain=v1 --untracked-files=all 2>/dev/null)" \
  || fail 'worktree state could not be verified' '无法验证工作区状态'
[[ -z "${worktree_status}" ]] \
  || fail 'worktree has uncommitted changes' '工作区存在未提交修改'

candidate_sha="$(git rev-parse HEAD 2>/dev/null)" \
  || fail 'HEAD is unavailable' '无法读取 HEAD'
[[ "${candidate_sha}" =~ ^[0-9a-f]{40}$ ]] \
  || fail 'HEAD is not a full lowercase Git commit SHA' 'HEAD 不是完整的小写 Git commit SHA'
replace_refs="$(git for-each-ref --format='%(refname)' refs/replace 2>/dev/null)" \
  || fail 'local Git replace refs are unreadable' '无法读取本地 Git replace refs'
[[ -z "${replace_refs}" ]] \
  || fail 'local Git replace refs are not allowed for direct integration' \
    '直推集成不允许存在本地 Git replace refs'
[[ -z "${GIT_GRAFT_FILE:-}" ]] \
  || fail 'a GIT_GRAFT_FILE override is not allowed for direct integration' \
    '直推集成不允许设置 GIT_GRAFT_FILE'
grafts_path="$(git rev-parse --git-path info/grafts 2>/dev/null)" \
  || fail 'local Git grafts path is unreadable' '无法读取本地 Git grafts 路径'
[[ ! -e "${grafts_path}" && ! -L "${grafts_path}" ]] \
  || fail 'a local Git grafts file is not allowed for direct integration' \
    '直推集成不允许存在本地 Git grafts 文件'
set +e
git config --get-regexp '^trailer\.' >/dev/null 2>&1
trailer_config_status=$?
set -e
case "${trailer_config_status}" in
  0)
    fail 'Git trailer configuration is not allowed for direct integration' \
      '直推集成不允许存在 Git trailer 配置'
    ;;
  1)
    ;;
  *)
    fail 'Git trailer configuration could not be verified' \
      '无法验证 Git trailer 配置'
    ;;
esac
require_no_url_rewrite_config

gh auth status >/dev/null 2>&1 \
  || fail 'authenticated GitHub CLI is unavailable' 'GitHub CLI 未登录或不可用'
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
  || fail 'repository identity could not be resolved' '无法读取仓库身份'
[[ "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || fail 'repository identity has an unexpected shape' '仓库身份格式异常'
fetch_url="$(read_single_remote_url fetch)" \
  || fail 'origin must resolve to exactly one fetch endpoint' \
    'origin 必须精确解析为一个 fetch 端点'
push_url="$(read_single_remote_url push)" \
  || fail 'origin must resolve to exactly one effective push endpoint' \
    'origin 必须精确解析为一个有效 push 端点'
fetch_repository="$(github_repository_from_url "${fetch_url}")" \
  || fail 'origin fetch endpoint is not a supported credential-free GitHub URL' \
    'origin fetch 端点不是受支持且不含凭据的 GitHub URL'
push_repository="$(github_repository_from_url "${push_url}")" \
  || fail 'origin push endpoint is not a supported credential-free GitHub URL' \
    'origin push 端点不是受支持且不含凭据的 GitHub URL'
same_repository_identity "${fetch_repository}" "${repo}" \
  && same_repository_identity "${push_repository}" "${repo}" \
  || fail 'origin fetch/push endpoints do not match the resolved GitHub repository' \
    'origin fetch/push 端点与已解析的 GitHub 仓库不一致'

refresh_main \
  || fail 'origin/main could not be refreshed' '无法刷新 origin/main'
base_sha="$(read_origin_main)" \
  || fail 'origin/main is unavailable after fetch' 'fetch 后仍无法读取 origin/main'

if [[ "${candidate_sha}" == "${base_sha}" ]]; then
  fail 'HEAD is already live main; no candidate integration was performed' \
    'HEAD 已是远端 main；本次没有候选集成可执行'
fi

GIT_GRAFT_FILE=/dev/null git --no-replace-objects merge-base --is-ancestor \
    "${base_sha}" "${candidate_sha}" >/dev/null 2>&1 \
  || fail 'HEAD is not a fast-forward descendant of live main' \
    'HEAD 不是远端 main 的可快进后代'
candidate_commits="$(GIT_GRAFT_FILE=/dev/null git --no-replace-objects rev-list \
  --reverse "${base_sha}..${candidate_sha}" 2>/dev/null)" \
  || fail 'candidate commit range is unreadable' '无法读取候选提交范围'
[[ -n "${candidate_commits}" ]] \
  || fail 'candidate commit range is empty' '候选提交范围为空'
while IFS= read -r commit_sha; do
  risk_trailer="$(GIT_GRAFT_FILE=/dev/null git --no-replace-objects show -s \
    --format='%(trailers:key=DroidMatch-Risk,only)' "${commit_sha}" 2>/dev/null)" \
    || fail "risk trailer is unreadable for ${commit_sha:0:12}" \
      "无法读取 ${commit_sha:0:12} 的风险 trailer"
  [[ "${risk_trailer}" == 'DroidMatch-Risk: R0' ]] \
    || fail "candidate commit ${commit_sha:0:12} does not declare exactly DroidMatch-Risk: R0" \
      "候选提交 ${commit_sha:0:12} 未精确声明 DroidMatch-Risk: R0"
done <<<"${candidate_commits}"
python3 tools/check-maintainer-contract.py \
  || fail 'local maintainer-contract preflight rejected the candidate' \
    '本地维护者契约预检拒绝了候选'
require_phase_a 'before candidate CI' '候选 CI 前'

run_suffix="$(date -u '+%Y%m%dT%H%M%SZ')" \
  || fail 'could not create the temporary gate ref timestamp' \
    '无法生成临时 gate ref 时间戳'
run_token="$(python3 -c 'import secrets; print(secrets.token_hex(16))' 2>/dev/null)" \
  || fail 'could not create the temporary gate ref token' \
    '无法生成临时 gate ref 随机标识'
[[ "${run_token}" =~ ^[0-9a-f]{32}$ ]] \
  || fail 'temporary gate ref token has an unexpected shape' \
    '临时 gate ref 随机标识格式异常'
candidate_ref="codex/main-gate/${candidate_sha:0:12}-${run_suffix}-${run_token}"
git check-ref-format "refs/heads/${candidate_ref}" >/dev/null 2>&1 \
  || fail 'generated temporary gate ref is invalid' '生成的临时 gate ref 无效'

printf 'Staging exact candidate %s on temporary gate ref %s.\n' \
  "${candidate_sha}" "${candidate_ref}"
printf '正在临时 gate ref %s 上验证精确候选 %s。\n' \
  "${candidate_ref}" "${candidate_sha}"
require_no_url_rewrite_config
if candidate_push_output="$(GIT_TERMINAL_PROMPT=0 \
    git -c core.hooksPath=/dev/null push --porcelain --no-verify \
    --no-follow-tags --recurse-submodules=no \
    --force-with-lease="refs/heads/${candidate_ref}:" "${push_url}" \
    "${candidate_sha}:refs/heads/${candidate_ref}")"; then
  [[ -z "${candidate_push_output}" ]] || printf '%s\n' "${candidate_push_output}"
  candidate_update_count=0
  candidate_update_record=""
  while IFS= read -r push_line; do
    case "${push_line}" in
      $' \t'*|$'*\t'*|$'+\t'*|$'-\t'*|$'=\t'*|$'!\t'*)
        candidate_update_count=$((candidate_update_count + 1))
        candidate_update_record="${push_line}"
        ;;
    esac
  done <<<"${candidate_push_output}"
  expected_candidate_record=$'*\t'"${candidate_sha}:refs/heads/${candidate_ref}"$'\t[new branch]'
  if [[ "${candidate_update_count}" -ne 1 \
      || "${candidate_update_record}" != "${expected_candidate_record}" ]]; then
    fail 'temporary candidate push did not prove exclusive ref creation; no cleanup ownership was assumed' \
      '临时候选 push 未证明 ref 由本次独占创建；未取得清理所有权'
  fi
  temporary_ref_created=1
else
  printf 'WARNING temporary candidate push failed; cleanup ownership was not assumed.\n' >&2
  printf '警告：临时候选 push 失败；未取得清理所有权。\n' >&2
  printf 'WARNING attempted temporary gate ref (inspect manually): %s\n' \
    "${candidate_ref}" >&2
  printf '警告：本次尝试的临时 gate ref（请人工复核）：%s\n' \
    "${candidate_ref}" >&2
  if observed_candidate_sha="$(read_remote_candidate_sha)" \
      && [[ "${observed_candidate_sha}" == "${candidate_sha}" ]]; then
    printf 'WARNING the candidate is visible on %s, but its creator is ambiguous; inspect it and use an exact-SHA lease for any manual cleanup.\n' \
      "${candidate_ref}" >&2
    printf '警告：候选已出现在 %s，但创建者不明确；请人工复核，并仅用精确 SHA 租约清理。\n' \
      "${candidate_ref}" >&2
  fi
  fail 'temporary candidate push was rejected or its result was ambiguous' \
    '临时候选 push 被拒绝或结果存在歧义'
fi
printf 'Temporary gate ref created exclusively: %s\n' "${candidate_ref}"
printf '临时 gate ref 已由本次独占创建：%s\n' "${candidate_ref}"

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
push_main_with_recovery \
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
