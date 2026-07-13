#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

check_github=0
artifact=""
blockers=0

usage() {
  cat <<'USAGE'
Usage: tools/check-release-readiness.sh [--github] [--artifact <DroidMatch.app>]

Runs a read-only release preflight. It never reads or prints credential values.
执行只读发布预检；不会读取或输出凭据值。

  --github          Check main protection and hosted CI for the exact HEAD.
  --artifact PATH   Check Developer ID signature and notarization staple.
  --help            Show this help.
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --github)
      check_github=1
      ;;
    --artifact)
      shift
      [[ "$#" -gt 0 ]] || { usage >&2; exit 2; }
      artifact="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

pass() {
  printf 'PASS    %s\n' "$1"
}

block() {
  blockers=$((blockers + 1))
  printf 'BLOCKED %s\n' "$1"
}

manual() {
  printf 'MANUAL  %s\n' "$1"
}

head_sha="$(git rev-parse HEAD)"
if worktree_status="$(git status --porcelain 2>/dev/null)"; then
  if [[ -z "${worktree_status}" ]]; then
    pass "worktree is clean at ${head_sha} / 工作区干净"
  else
    block "worktree has uncommitted changes / 工作区存在未提交修改"
  fi
else
  block "worktree state could not be verified / 无法验证工作区状态"
fi

# Count matching identities without exposing certificate subjects or hashes.
if security find-identity -v -p codesigning 2>/dev/null \
    | grep -q 'Developer ID Application'; then
  pass "Developer ID Application identity is available / Developer ID 证书可用"
else
  block "Developer ID Application identity is unavailable / 缺少 Developer ID 证书"
fi

if xcrun --find notarytool >/dev/null 2>&1; then
  pass "notarytool is installed / notarytool 已安装"
else
  block "notarytool is unavailable / 缺少 notarytool"
fi

if [[ -n "${artifact}" ]]; then
  if [[ ! -d "${artifact}" ]]; then
    block "artifact path is not an App bundle / 产物路径不是 App bundle"
  elif codesign -dv --verbose=4 "${artifact}" 2>&1 \
      | grep -q '^Authority=Developer ID Application:'; then
    pass "artifact has a Developer ID Application signature / 产物已使用 Developer ID 签名"
  else
    block "artifact lacks a Developer ID Application signature / 产物未使用 Developer ID 签名"
  fi

  if [[ -d "${artifact}" ]] && xcrun stapler validate "${artifact}" >/dev/null 2>&1; then
    pass "artifact has a valid notarization staple / 产物含有效公证票据"
  else
    block "artifact lacks a valid notarization staple / 产物缺少有效公证票据"
  fi
else
  manual "pass --artifact after signing and stapling / 签名并 stapling 后传入 --artifact"
fi

if [[ "${check_github}" -eq 1 ]]; then
  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    block "authenticated GitHub CLI is unavailable / GitHub CLI 未登录或不可用"
  else
    if repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"; then
      if main_sha="$(gh api "repos/${repo}/commits/main" --jq .sha 2>/dev/null)" \
          && [[ "${main_sha}" == "${head_sha}" ]]; then
        pass "HEAD is the live main tip / HEAD 是远端 main 的最新提交"
      else
        block "HEAD is unreadable or differs from the live main tip / HEAD 不可读或不是远端 main 最新提交"
      fi

      if protection_state="$(gh api "repos/${repo}/branches/main/protection" --jq '
        if (
          .required_status_checks.strict == true and
          ((["spec", "mac-skeleton", "android-skeleton"]
            - .required_status_checks.contexts) | length == 0) and
          .required_pull_request_reviews.required_approving_review_count == 0 and
          .required_conversation_resolution.enabled == true and
          .required_linear_history.enabled == true and
          .enforce_admins.enabled == true and
          .allow_force_pushes.enabled == false and
          .allow_deletions.enabled == false
        ) then "valid" else "invalid" end
      ' 2>/dev/null)" && [[ "${protection_state}" == valid ]]; then
        pass "main protection matches Phase A controls / main 分支保护符合 Phase A"
      else
        block "main protection is unreadable or differs from Phase A / main 分支保护不可读或偏离 Phase A"
      fi
    else
      block "repository identity could not be resolved / 无法读取仓库身份"
    fi

    if run_state="$(gh run list \
        --workflow 'Spec and Skeleton Gates' \
        --commit "${head_sha}" \
        --limit 1 \
        --json status,conclusion \
        --jq 'if length == 0 then "missing" else .[0].status + ":" + (.[0].conclusion // "") end' \
        2>/dev/null)"; then
      if [[ "${run_state}" == "completed:success" ]]; then
        pass "hosted gates passed for exact HEAD / 当前 HEAD 的托管门禁已通过"
      else
        block "hosted gates for exact HEAD are ${run_state} / 当前 HEAD 托管门禁未通过"
      fi
    else
      block "hosted gates for exact HEAD could not be read / 无法读取当前 HEAD 托管门禁"
    fi
  fi
else
  manual "pass --github to inspect protection and exact-HEAD CI / 使用 --github 检查仓库治理与 CI"
fi

manual "verify redacted physical-device matrix and sandbox product evidence / 核验真机矩阵与 sandbox 产品证据"
manual "review bilingual release notes and published checksum / 复核双语发布说明与 checksum"

if [[ "${blockers}" -gt 0 ]]; then
  printf '\nRelease preflight blocked: %d automated check(s) failed.\n' "${blockers}" >&2
  printf '发布预检未通过：%d 项自动检查失败。\n' "${blockers}" >&2
  exit 1
fi

printf '\nAutomated release preflight passed; MANUAL items remain operator-owned.\n'
printf '自动发布预检通过；MANUAL 项仍需维护者人工确认。\n'
