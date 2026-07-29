#!/usr/bin/env bash

# Shared SwiftPM environment preparation for product builds and test gates.
# The caller owns `set -euo pipefail`; this file is sourced rather than run.

droidmatch_swift_lock_snapshot() {
  python3 -c '
import hashlib
import os
import stat
import sys

path = sys.argv[1]
before = os.lstat(path)
if (not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.geteuid()
        or before.st_nlink != 1
        or before.st_size <= 0
        or before.st_size > 1024 * 1024):
    raise RuntimeError("Package.resolved is not a safe owned single-link file")
flags = os.O_RDONLY
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
descriptor = os.open(path, flags)
try:
    opened = os.fstat(descriptor)
    stable_before = (
        before.st_dev, before.st_ino, before.st_mode, before.st_uid,
        before.st_nlink, before.st_size, before.st_mtime_ns,
    )
    stable_opened = (
        opened.st_dev, opened.st_ino, opened.st_mode, opened.st_uid,
        opened.st_nlink, opened.st_size, opened.st_mtime_ns,
    )
    if stable_opened != stable_before:
        raise RuntimeError("Package.resolved changed while opening")
    digest_state = hashlib.sha256()
    with os.fdopen(os.dup(descriptor), "rb") as source:
        while True:
            chunk = source.read(64 * 1024)
            if not chunk:
                break
            digest_state.update(chunk)
    digest = digest_state.hexdigest()
    after = os.fstat(descriptor)
    stable_after = (
        after.st_dev, after.st_ino, after.st_mode, after.st_uid,
        after.st_nlink, after.st_size, after.st_mtime_ns,
    )
    if stable_after != stable_opened:
        raise RuntimeError("Package.resolved changed while reading")
finally:
    os.close(descriptor)
print(":".join(map(str, stable_opened)) + ":" + digest)
' "$1"
}

droidmatch_verify_swift_lock_unchanged() {
  local current_snapshot
  current_snapshot="$(droidmatch_swift_lock_snapshot \
    "${droidmatch_swift_package_resolved}")" || {
    printf 'Package.resolved became missing or unsafe during SwiftPM execution.\n' >&2
    printf '中文：SwiftPM 执行期间 Package.resolved 缺失或变得不安全。\n' >&2
    return 1
  }
  if [[ "${current_snapshot}" != "${droidmatch_swift_lock_initial_snapshot}" ]]; then
    printf 'Package.resolved changed during an immutable SwiftPM operation.\n' >&2
    printf '中文：不可变 SwiftPM 操作期间 Package.resolved 发生变化。\n' >&2
    return 1
  fi
}

droidmatch_run_with_immutable_swift_lock() {
  local status
  droidmatch_verify_swift_lock_unchanged || return 1
  if "$@"; then
    status=0
  else
    status=$?
  fi
  droidmatch_verify_swift_lock_unchanged || return 1
  return "${status}"
}

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

  droidmatch_swift_package_resolved="${repository_root}/mac/Package.resolved"
  droidmatch_swift_lock_initial_snapshot="$(
    droidmatch_swift_lock_snapshot "${droidmatch_swift_package_resolved}"
  )" || {
    printf 'Could not validate mac/Package.resolved for immutable SwiftPM use.\n' >&2
    printf '中文：无法验证 mac/Package.resolved，不能执行不可变 SwiftPM 操作。\n' >&2
    return 1
  }

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
    --disable-automatic-resolution
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
