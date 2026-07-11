#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

probe_only=0
if [[ "${1:-}" == "--probe-only" ]]; then
  probe_only=1
  shift
fi

if [[ "$#" -gt 0 ]]; then
  printf 'Unexpected argument: %s\n' "$1" >&2
  printf '中文：不支持的参数：%s\n' "$1" >&2
  exit 2
fi

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

make_probe() {
  local probe_file="$1"
  cat >"${probe_file}" <<'SWIFT'
import Testing

@Test func droidMatchSwiftTestingProbe() {
    #expect(1 == 1)
}
SWIFT
}

plain_swift_testing_available() {
  local tmp_dir probe log_file
  tmp_dir="$(mktemp -d)"
  probe="${tmp_dir}/TestingProbe.swift"
  log_file="${tmp_dir}/swift-testing.log"
  make_probe "${probe}"
  if swiftc "${probe}" -typecheck >"${log_file}" 2>&1; then
    rm -rf "${tmp_dir}"
    return 0
  fi
  rm -rf "${tmp_dir}"
  return 1
}

default_swift_target_available() {
  swiftc -typecheck - >/dev/null 2>&1 <<'SWIFT'
func droidMatchDefaultTargetProbe() {}
#if compiler(>=6.2)
func droidMatchDefaultRawSpanProbe(_ value: RawSpan) {}
#endif
SWIFT
}

arm64e_swift_target_available() {
  local sdk_path
  sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  [[ -n "${sdk_path}" ]] || return 1
  swiftc \
    -target arm64e-apple-macosx13.0 \
    -sdk "${sdk_path}" \
    -typecheck - >/dev/null 2>&1 <<'SWIFT'
func droidMatchArm64eTargetProbe() {}
#if compiler(>=6.2)
func droidMatchArm64eRawSpanProbe(_ value: RawSpan) {}
#endif
SWIFT
}

developer_dir="$(xcode-select -p 2>/dev/null || true)"
testing_search_roots=()
testing_search_root_count=0
testing_framework_dir=""
testing_macros=""
testing_interop_dir=""

add_search_root() {
  local candidate="$1"
  local existing
  [[ -n "${candidate}" && -d "${candidate}" ]] || return 0
  if [[ "${testing_search_root_count}" -gt 0 ]]; then
    for existing in "${testing_search_roots[@]}"; do
      [[ "${existing}" == "${candidate}" ]] && return 0
    done
  fi
  testing_search_roots[${testing_search_root_count}]="${candidate}"
  testing_search_root_count=$((testing_search_root_count + 1))
}

find_first_in_search_roots() {
  local name="$1"
  local file_type="$2"
  local root result
  if [[ "${testing_search_root_count}" -gt 0 ]]; then
    for root in "${testing_search_roots[@]}"; do
      result="$(find "${root}" -name "${name}" -type "${file_type}" -print -quit 2>/dev/null || true)"
      if [[ -n "${result}" ]]; then
        printf '%s' "${result}"
        return 0
      fi
    done
  fi
  return 1
}

print_swift_testing_diagnostics() {
  local root
  printf 'Swift Testing diagnostic: selected developer dir: %s\n' "${developer_dir:-<none>}" >&2
  if [[ "${testing_search_root_count}" -eq 0 ]]; then
    printf 'Swift Testing diagnostic: no Xcode or Command Line Tools search roots found.\n' >&2
    return
  fi
  for root in "${testing_search_roots[@]}"; do
    printf 'Swift Testing diagnostic: search root: %s\n' "${root}" >&2
    find "${root}" \
      \( -name Testing.framework -o -name libTestingMacros.dylib -o -name lib_TestingInterop.dylib \) \
      -print 2>/dev/null | sed -n '1,20p' >&2
  done
}

# English: Xcode and Command Line Tools place Swift Testing support in
# different subdirectories across runner images. 中文：不同 Xcode/CLT runner
# 镜像会把 Swift Testing 放在不同子目录，所以同时搜索当前 Xcode 和 CLT。
add_search_root "${developer_dir}"
add_search_root "/Library/Developer/CommandLineTools"
add_search_root "/Applications/Xcode.app/Contents/Developer"

testing_framework_path="$(find_first_in_search_roots Testing.framework d || true)"
if [[ -n "${testing_framework_path}" ]]; then
  testing_framework_dir="$(dirname "${testing_framework_path}")"
fi

testing_macros="$(find_first_in_search_roots libTestingMacros.dylib f || true)"

testing_interop_path="$(find_first_in_search_roots lib_TestingInterop.dylib f || true)"
if [[ -n "${testing_interop_path}" ]]; then
  testing_interop_dir="$(dirname "${testing_interop_path}")"
fi

swift_test_args=(test --package-path mac)
if [[ -n "${DROIDMATCH_SWIFT_SCRATCH_PATH:-}" ]]; then
  swift_test_args+=(--scratch-path "${DROIDMATCH_SWIFT_SCRATCH_PATH}")
fi

# English: Some Command Line Tools updates briefly/currently expose the macOS
# standard library for arm64e but not the driver's default arm64 target. Use a
# target override only after proving the default is broken and arm64e works.
# 中文：部分 CLT 更新只暴露 arm64e 标准库、默认 arm64 目标反而不可用；仅在
# 探针确认“默认失败且 arm64e 成功”后回退，正常 Xcode/CI 路径不受影响。
if ! default_swift_target_available \
    && [[ "$(uname -m)" == "arm64" ]] \
    && arm64e_swift_target_available; then
  swift_test_args+=(--triple arm64e-apple-macosx13.0)
  printf 'Swift target fallback: default arm64 standard library is unavailable; using arm64e.\n'
  printf '中文：Swift 目标回退：默认 arm64 标准库不可用，改用 arm64e。\n'
fi

if plain_swift_testing_available; then
  if [[ "${probe_only}" -eq 1 ]]; then
    printf 'Swift prerequisite ok: Swift Testing is available through the selected toolchain.\n'
    printf '中文：Swift 依赖检查通过：当前 toolchain 可直接使用 Swift Testing。\n'
    exit 0
  fi
  exec swift "${swift_test_args[@]}"
fi

if [[ -n "${testing_framework_dir}" && -n "${testing_macros}" && -n "${testing_interop_dir}" ]]; then
  # English: Command Line Tools can ship Swift Testing outside SwiftPM's default
  # search paths. 中文：仅安装 Command Line Tools 时，Swift Testing 可能在 SwiftPM
  # 默认搜索路径之外，因此这里显式传入 framework、macro plugin 和运行时 rpath。
  swift_test_args+=(
    -Xswiftc -F
    -Xswiftc "${testing_framework_dir}"
    -Xswiftc -load-plugin-executable
    -Xswiftc "${testing_macros}#TestingMacros"
    -Xlinker -rpath
    -Xlinker "${testing_framework_dir}"
    -Xlinker -rpath
    -Xlinker "${testing_interop_dir}"
  )

  if [[ "${probe_only}" -eq 1 ]]; then
    printf 'Swift prerequisite ok: using explicit Swift Testing paths from %s.\n' "${testing_framework_dir}"
    printf '中文：Swift 依赖检查通过：使用来自 %s 的显式 Swift Testing 路径。\n' "${testing_framework_dir}"
    exit 0
  fi
  exec swift "${swift_test_args[@]}"
fi

print_swift_testing_diagnostics
fail "Swift Testing not found. English: install/select full Xcode 16+ or Command Line Tools with Testing.framework and TestingMacros. 中文：未找到 Swift Testing；请安装/切换完整 Xcode 16+，或安装包含 Testing.framework 和 TestingMacros 的 Command Line Tools。"
