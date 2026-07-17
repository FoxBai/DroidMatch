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
initial_source_snapshot_valid=false
if worktree_status="$(git status --porcelain 2>/dev/null)"; then
  if [[ -z "${worktree_status}" ]]; then
    initial_source_snapshot_valid=true
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
  else
    if codesign -dv --verbose=4 "${artifact}" 2>&1 \
        | grep -q '^Authority=Developer ID Application:'; then
      pass "artifact has a Developer ID Application signature / 产物已使用 Developer ID 签名"
    else
      block "artifact lacks a Developer ID Application signature / 产物未使用 Developer ID 签名"
    fi

    # `codesign -d` only displays metadata. Verify the complete resource seal
    # separately, without relaying certificate subjects or artifact paths.
    # 中文：`codesign -d` 只读取元数据；必须另行验证完整资源封印，
    # 且不回显证书 subject 或产物路径。
    if codesign --verify --deep --strict "${artifact}" >/dev/null 2>&1; then
      pass "artifact code signature and resource seal are valid / 产物签名与资源封印有效"
    else
      block "artifact code signature or resource seal is invalid / 产物签名或资源封印无效"
    fi

    # Reuse the assembled-product verifier so a signed artifact cannot bypass
    # the reviewed sandbox entitlement, embedded-adb, privacy, and legal-resource
    # boundary. Its detailed output is withheld because it can contain a local
    # artifact path. 中文：复用产品 bundle 验证器，但隐去可能包含
    # 本地路径的详细输出。
    if python3 "${repo_root}/tools/check-mac-app-bundle.py" \
        --sandboxed "${artifact}" >/dev/null 2>&1; then
      pass "artifact matches the sandbox product boundary / 产物符合 sandbox 产品边界"
    else
      block "artifact does not match the sandbox product boundary / 产物不符合 sandbox 产品边界"
    fi

    info_plist="${artifact}/Contents/Info.plist"
    artifact_revision=""
    artifact_dirty=""
    artifact_configuration=""
    artifact_revision="$(plutil -extract DroidMatchSourceRevision raw -o - \
      "${info_plist}" 2>/dev/null)" || true
    artifact_dirty="$(plutil -extract DroidMatchSourceDirty raw -o - \
      "${info_plist}" 2>/dev/null)" || true
    artifact_configuration="$(plutil -extract DroidMatchBuildConfiguration raw -o - \
      "${info_plist}" 2>/dev/null)" || true

    if [[ "${artifact_revision}" == "${head_sha}" ]]; then
      pass "artifact source revision matches HEAD / 产物源码版本与 HEAD 一致"
    else
      block "artifact source revision is missing or differs from HEAD / 产物源码版本缺失或与 HEAD 不同"
    fi
    if [[ "${artifact_dirty}" == "false" ]]; then
      pass "artifact was built from a clean source tree / 产物来自干净源码树"
    else
      block "artifact source-dirty provenance is missing or not false / 产物源码污染标记缺失或不为 false"
    fi
    if [[ "${artifact_configuration}" == "release" ]]; then
      pass "artifact uses the release build configuration / 产物使用 release 构建配置"
    else
      block "artifact build configuration is missing or not release / 产物构建配置缺失或不是 release"
    fi

    if xcrun stapler validate "${artifact}" >/dev/null 2>&1; then
      pass "artifact has a valid notarization staple / 产物含有效公证票据"
    else
      block "artifact lacks a valid notarization staple / 产物缺少有效公证票据"
    fi
  fi
else
  manual "pass --artifact after signing and stapling / 签名并 stapling 后传入 --artifact"
fi

if [[ "${check_github}" -eq 1 ]]; then
  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    block "authenticated GitHub CLI is unavailable / GitHub CLI 未登录或不可用"
  else
    repo=""
    main_sha=""
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
          .required_pull_request_reviews == null and
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

      if repository_settings_state="$(gh api "repos/${repo}" --jq '
        if (
          .default_branch == "main" and
          .delete_branch_on_merge == true and
          .allow_squash_merge == true and
          .allow_merge_commit == false and
          .allow_rebase_merge == false and
          .security_and_analysis.secret_scanning.status == "enabled" and
          .security_and_analysis.secret_scanning_push_protection.status == "enabled"
        ) then "valid" else "invalid" end
      ' 2>/dev/null)" && [[ "${repository_settings_state}" == valid ]]; then
        pass "repository merge and secret-protection settings match baseline / 仓库合并与 Secret Protection 设置符合基线"
      else
        block "repository merge or secret-protection settings are unreadable or differ from baseline / 仓库合并或 Secret Protection 设置不可读或偏离基线"
      fi
    else
      block "repository identity could not be resolved / 无法读取仓库身份"
    fi

    if run_state="$(gh run list \
        --workflow 'Spec and Skeleton Gates' \
        --branch main \
        --commit "${head_sha}" \
        --event push \
        --limit 1 \
        --json status,conclusion,event,headBranch,headSha \
        --jq 'if length == 0 then "missing" else [.[0].status, (.[0].conclusion // ""), .[0].event, .[0].headBranch, .[0].headSha] | @tsv end' \
        2>/dev/null)"; then
      expected_run_state="completed"$'\t'"success"$'\t'"push"$'\t'"main"$'\t'"${head_sha}"
      if [[ "${run_state}" == "${expected_run_state}" ]]; then
        pass "hosted main-push gates passed for exact HEAD / 当前 HEAD 的 main push 托管门禁已通过"
      else
        block "hosted main-push gates for exact HEAD are missing or unsuccessful / 当前 HEAD 的 main push 托管门禁缺失或未通过"
      fi
    else
      block "hosted main-push gates for exact HEAD could not be read / 无法读取当前 HEAD 的 main push 托管门禁"
    fi

    # GitHub state is read through several API calls. Re-read main last so an
    # integration that races this preflight cannot leave a stale HEAD looking
    # release-ready. 中文：最后复核 main，远端并发推进时必须失败关闭。
    if [[ -n "${repo}" && -n "${main_sha}" ]]; then
      if final_main_sha="$(gh api "repos/${repo}/commits/main" --jq .sha 2>/dev/null)" \
          && [[ "${final_main_sha}" == "${main_sha}" ]]; then
        pass "live main remained stable during GitHub checks / GitHub 检查期间远端 main 未变化"
      else
        block "live main changed or became unreadable during GitHub checks / GitHub 检查期间远端 main 变化或不可读"
      fi
    fi
  fi
else
  manual "pass --github to inspect protection and exact-HEAD CI / 使用 --github 检查仓库治理与 CI"
fi

# Artifact, notarization, and hosted checks can be slow. Bind their result to
# the exact clean local snapshot seen at entry by reading both facts again at
# the end. 中文：产物、公证与托管检查可能较慢；结束前重新读取本地 HEAD
# 与工作区状态，确保结果仍绑定到入口时的同一干净快照。
final_head_sha=""
final_worktree_status=""
final_source_snapshot_valid=false
if final_head_sha="$(git rev-parse HEAD 2>/dev/null)" \
    && final_worktree_status="$(git status --porcelain 2>/dev/null)" \
    && [[ "${final_head_sha}" == "${head_sha}" \
      && -z "${final_worktree_status}" ]]; then
  final_source_snapshot_valid=true
fi
if [[ "${initial_source_snapshot_valid}" == true ]]; then
  if [[ "${final_source_snapshot_valid}" == true ]]; then
    pass "local source snapshot remained stable / 本地源码快照在检查期间保持不变"
  else
    block "local HEAD or worktree changed during release checks / 发布检查期间本地 HEAD 或工作区发生变化"
  fi
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
