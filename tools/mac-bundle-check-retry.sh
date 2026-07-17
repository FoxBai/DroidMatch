#!/usr/bin/env bash

# A freshly assembled or mounted ad-hoc bundle can briefly receive a macOS execution-policy
# rejection for its embedded adb even after the same signed binary passed before
# imaging. Retry only that exact verifier result; every other bundle failure is
# final so this helper cannot weaken the production verifier.
droidmatch_check_app_with_retry() {
  local checker="$1"
  local app_path="$2"
  local sandboxed="$3"
  local exact_transient_error="Mac App bundle check failed: embedded adb is not runnable"
  local max_attempts=3
  local attempt=1
  local output=""
  local status=1
  local -a verify_args=("${app_path}")

  case "${sandboxed}" in
    true)
      verify_args=(--sandboxed "${app_path}")
      ;;
    false)
      ;;
    *)
      printf 'App bundle retry mode must be true or false.\n' >&2
      return 2
      ;;
  esac

  while ((attempt <= max_attempts)); do
    if output="$(python3 "${checker}" "${verify_args[@]}" 2>&1)"; then
      if [[ -n "${output}" ]]; then
        printf '%s\n' "${output}"
      fi
      return 0
    else
      status=$?
    fi

    if [[ "${output}" != "${exact_transient_error}" \
      || "${attempt}" -eq "${max_attempts}" ]]; then
      if [[ -n "${output}" ]]; then
        printf '%s\n' "${output}" >&2
      fi
      return "${status}"
    fi

    printf 'App adb execution is temporarily unavailable; retrying the complete bundle check (%s/%s).\n' \
      "${attempt}" "${max_attempts}" >&2
    printf '中文：App 的 adb 执行策略暂未就绪；正在重试完整 bundle 检查（%s/%s）。\n' \
      "${attempt}" "${max_attempts}" >&2
    # macOS 26 can need several seconds to converge execution policy for a new
    # App inode. Keep the delay fixed and the exact-error retry count bounded.
    sleep 5
    attempt=$((attempt + 1))
  done
}
