#!/usr/bin/env bash

# Shared SwiftPM environment preparation for product builds and test gates.
# The caller owns `set -euo pipefail`; this file is sourced rather than run.

droidmatch_default_swift_target_available() {
  swiftc \
    -module-cache-path "${droidmatch_swift_module_cache}" \
    -typecheck - >/dev/null 2>&1 <<'SWIFT'
func droidMatchDefaultTargetProbe() {}
#if compiler(>=6.2)
func droidMatchDefaultRawSpanProbe(_ value: RawSpan) {}
#endif
SWIFT
}

droidmatch_arm64e_swift_target_available() {
  local sdk_path
  sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  [[ -n "${sdk_path}" ]] || return 1
  swiftc \
    -target arm64e-apple-macosx13.0 \
    -sdk "${sdk_path}" \
    -module-cache-path "${droidmatch_swift_module_cache}" \
    -typecheck - >/dev/null 2>&1 <<'SWIFT'
func droidMatchArm64eTargetProbe() {}
#if compiler(>=6.2)
func droidMatchArm64eRawSpanProbe(_ value: RawSpan) {}
#endif
SWIFT
  droidmatch_swift_probe_sdk="${sdk_path}"
}

droidmatch_prepare_swift_build_environment() {
  local repository_root="$1"
  local module_cache_error scratch_path

  if [[ -n "${DROIDMATCH_SWIFT_MODULE_CACHE_PATH:-}" ]]; then
    droidmatch_swift_module_cache="${DROIDMATCH_SWIFT_MODULE_CACHE_PATH}"
    module_cache_error="Could not create the requested Swift module cache."
  else
    # Incremental objects retain PCM paths, so the default cache is stable and
    # package-local instead of a temporary directory or an unwritable home path.
    scratch_path="${DROIDMATCH_SWIFT_SCRATCH_PATH:-mac/.build}"
    droidmatch_swift_module_cache="${scratch_path}/droidmatch-module-cache"
    module_cache_error="Could not create the package-local Swift module cache."
  fi
  if [[ "${droidmatch_swift_module_cache}" != /* ]]; then
    droidmatch_swift_module_cache="${repository_root}/${droidmatch_swift_module_cache}"
  fi
  if ! mkdir -p "${droidmatch_swift_module_cache}"; then
    printf '%s\n' "${module_cache_error}" >&2
    return 1
  fi
  export CLANG_MODULE_CACHE_PATH="${droidmatch_swift_module_cache}"
  export SWIFTPM_MODULECACHE_OVERRIDE="${droidmatch_swift_module_cache}"

  droidmatch_swift_probe_target=""
  droidmatch_swift_probe_sdk=""
  droidmatch_swift_compat_args=(
    -Xswiftc -module-cache-path
    -Xswiftc "${droidmatch_swift_module_cache}"
  )
  if [[ -n "${CODEX_SANDBOX:-}" ]]; then
    # Codex supplies the outer sandbox; SwiftPM's nested sandbox-exec cannot
    # initialize there and adds no security boundary.
    droidmatch_swift_compat_args+=(--disable-sandbox)
  fi

  # Some CLT updates expose a usable standard library only for arm64e. Never
  # override a healthy default target, and never guess without both probes.
  if ! droidmatch_default_swift_target_available \
      && [[ "$(uname -m)" == "arm64" ]] \
      && droidmatch_arm64e_swift_target_available; then
    droidmatch_swift_probe_target="arm64e-apple-macosx13.0"
    droidmatch_swift_compat_args+=(
      --triple "${droidmatch_swift_probe_target}"
    )
    printf 'Swift target fallback: default arm64 standard library is unavailable; using arm64e.\n'
    printf '中文：Swift 目标回退：默认 arm64 标准库不可用，改用 arm64e。\n'
  fi
}
