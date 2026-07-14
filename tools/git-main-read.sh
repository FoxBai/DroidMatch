#!/usr/bin/env bash

# Shared read-only origin branch refresh. Callers own the decision made from the
# refreshed ref; this helper never pushes, merges, resets, or changes a worktree.
# 中文：共享的只读远端分支刷新；调用方负责使用刷新结果，本函数绝不 push、merge、
# reset，也不修改工作区。
refresh_origin_branch_with_retry() {
  local refresh_remote="${1:-}"
  local refresh_branch="${2:-}"
  local refresh_attempts="${3:-}"
  local refresh_interval_seconds="${4:-}"
  local refresh_attempt

  [[ -n "${refresh_remote}" && -n "${refresh_branch}" \
      && "${refresh_attempts}" =~ ^[1-9][0-9]*$ \
      && "${refresh_interval_seconds}" =~ ^[0-9]+$ ]] || {
    printf 'invalid read-only remote refresh configuration.\n' >&2
    printf '只读远端刷新配置无效。\n' >&2
    return 2
  }

  for ((refresh_attempt = 1; refresh_attempt <= refresh_attempts; refresh_attempt += 1)); do
    if GIT_TERMINAL_PROMPT=0 git fetch --quiet "${refresh_remote}" \
        "refs/heads/${refresh_branch}:refs/remotes/${refresh_remote}/${refresh_branch}"; then
      return 0
    fi

    if [[ "${refresh_attempt}" -lt "${refresh_attempts}" ]]; then
      printf 'WARNING %s/%s refresh failed; retrying (%s/%s).\n' \
        "${refresh_remote}" "${refresh_branch}" \
        "${refresh_attempt}" "${refresh_attempts}" >&2
      printf '警告：%s/%s 刷新失败；正在重试（%s/%s）。\n' \
        "${refresh_remote}" "${refresh_branch}" \
        "${refresh_attempt}" "${refresh_attempts}" >&2
      sleep "${refresh_interval_seconds}"
    fi
  done
  return 1
}
