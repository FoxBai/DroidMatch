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

developer_dir="$(xcode-select -p 2>/dev/null || true)"
testing_framework_dir=""
testing_macros=""
testing_interop_dir=""

if [[ -n "${developer_dir}" ]]; then
  for candidate in \
      "${developer_dir}/Library/Developer/Frameworks" \
      "${developer_dir}/Library/Frameworks"; do
    if [[ -d "${candidate}/Testing.framework" ]]; then
      testing_framework_dir="${candidate}"
      break
    fi
  done

  if [[ -x "${developer_dir}/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib" ]]; then
    testing_macros="${developer_dir}/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
  fi

  for candidate in \
      "${developer_dir}/Library/Developer/usr/lib" \
      "${developer_dir}/usr/lib"; do
    if [[ -f "${candidate}/lib_TestingInterop.dylib" ]]; then
      testing_interop_dir="${candidate}"
      break
    fi
  done
fi

swift_test_args=(test --package-path mac)

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
    printf 'Swift prerequisite ok: using explicit Swift Testing paths from %s.\n' "${developer_dir}"
    printf '中文：Swift 依赖检查通过：使用来自 %s 的显式 Swift Testing 路径。\n' "${developer_dir}"
    exit 0
  fi
  exec swift "${swift_test_args[@]}"
fi

fail "Swift Testing not found. English: install/select full Xcode 16+ or Command Line Tools with Testing.framework and TestingMacros. 中文：未找到 Swift Testing；请安装/切换完整 Xcode 16+，或安装包含 Testing.framework 和 TestingMacros 的 Command Line Tools。"
