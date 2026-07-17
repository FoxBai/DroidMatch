#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
source "${repo_root}/tools/swift-build-compat.sh"

probe_only=0
test_filter=""
test_filter_set=0
swiftc_probe_target=""
swiftc_probe_sdk=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --probe-only)
      if [[ "${probe_only}" -eq 1 ]]; then
        printf 'Duplicate argument: --probe-only\n' >&2
        printf '中文：参数重复：--probe-only\n' >&2
        exit 2
      fi
      probe_only=1
      shift
      ;;
    --filter)
      if [[ "${test_filter_set}" -eq 1 ]]; then
        printf 'Duplicate argument: --filter\n' >&2
        printf '中文：参数重复：--filter\n' >&2
        exit 2
      fi
      if [[ "$#" -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        printf 'Expected a non-empty regular expression after --filter.\n' >&2
        printf '中文：--filter 后必须提供非空正则表达式。\n' >&2
        exit 2
      fi
      test_filter="$2"
      test_filter_set=1
      shift 2
      ;;
    *)
      printf 'Unexpected argument: %s\n' "$1" >&2
      printf '中文：不支持的参数：%s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ "${probe_only}" -eq 1 && "${test_filter_set}" -eq 1 ]]; then
  printf '%s\n' '--probe-only cannot be combined with --filter.' >&2
  printf '中文：--probe-only 不能与 --filter 同时使用。\n' >&2
  exit 2
fi

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

swift_test_shard_size="${DROIDMATCH_SWIFT_TEST_SHARD_SIZE:-20}"
if [[ ! "${swift_test_shard_size}" =~ ^[1-9][0-9]*$ \
    || "${swift_test_shard_size}" -gt 20 ]]; then
  fail "DROIDMATCH_SWIFT_TEST_SHARD_SIZE must be an integer from 1 through 20."
fi

if ! droidmatch_prepare_swift_build_environment "${repo_root}"; then
  fail "Could not prepare the Swift build environment."
fi
swift_module_cache="${droidmatch_swift_module_cache}"
swiftc_probe_target="${droidmatch_swift_probe_target}"
swiftc_probe_sdk="${droidmatch_swift_probe_sdk}"

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
  local tmp_dir probe log_file status=0
  tmp_dir="$(mktemp -d)"
  probe="${tmp_dir}/TestingProbe.swift"
  log_file="${tmp_dir}/swift-testing.log"
  make_probe "${probe}"
  if [[ -n "${swiftc_probe_target}" ]]; then
    swiftc -target "${swiftc_probe_target}" -sdk "${swiftc_probe_sdk}" \
      -module-cache-path "${swift_module_cache}" \
      "${probe}" -typecheck >"${log_file}" 2>&1 || status=$?
  else
    swiftc -module-cache-path "${swift_module_cache}" \
      "${probe}" -typecheck >"${log_file}" 2>&1 || status=$?
  fi
  if [[ "${status}" -eq 0 ]]; then
    rm -rf "${tmp_dir}"
    return 0
  fi
  rm -rf "${tmp_dir}"
  return 1
}

explicit_swift_testing_available() {
  local tmp_dir probe log_file status=0
  tmp_dir="$(mktemp -d)"
  probe="${tmp_dir}/TestingProbe.swift"
  log_file="${tmp_dir}/swift-testing-explicit.log"
  make_probe "${probe}"
  if [[ -n "${swiftc_probe_target}" ]]; then
    swiftc \
      -target "${swiftc_probe_target}" \
      -sdk "${swiftc_probe_sdk}" \
      -module-cache-path "${swift_module_cache}" \
      -F "${testing_framework_dir}" \
      -load-plugin-library "${testing_macros}" \
      "${probe}" \
      -typecheck >"${log_file}" 2>&1 || status=$?
  else
    swiftc \
      -module-cache-path "${swift_module_cache}" \
      -F "${testing_framework_dir}" \
      -load-plugin-library "${testing_macros}" \
      "${probe}" \
      -typecheck >"${log_file}" 2>&1 || status=$?
  fi
  if [[ "${status}" -eq 0 ]]; then
    rm -rf "${tmp_dir}"
    return 0
  fi
  rm -rf "${tmp_dir}"
  return 1
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

swift_build_args=(build --package-path mac "${droidmatch_swift_compat_args[@]}")
swift_test_args=(test --package-path mac "${droidmatch_swift_compat_args[@]}")
if [[ -n "${DROIDMATCH_SWIFT_SCRATCH_PATH:-}" ]]; then
  swift_build_args+=(--scratch-path "${DROIDMATCH_SWIFT_SCRATCH_PATH}")
  swift_test_args+=(--scratch-path "${DROIDMATCH_SWIFT_SCRATCH_PATH}")
fi
if [[ "${test_filter_set}" -eq 1 ]]; then
  swift_test_args+=(--filter "${test_filter}")
fi

run_swift_test_command() {
  # English: Swift Testing 1902 can stall when its experimental global width
  # is forced low. The repository bounds full-suite concurrency with exact
  # process shards instead, so inherited experiments must not change the gate.
  # 中文：Swift Testing 1902 在强制很小的全局并发宽度时可能停滞；仓库通过
  # 精确进程分片限制全量并发，因此不能让外部实验变量改变门禁语义。
  env -u SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH \
    swift "$@"
}

prepare_swift_test_bundle() {
  printf 'Building the complete Swift test bundle once...\n'
  printf '中文：正在一次性构建完整 Swift 测试包……\n'
  run_swift_test_command "${swift_build_args[@]}" --build-tests

  # Inventory and every shard share this exact executable. This prevents a
  # relink between discovery and execution and makes a policy-stalled dlopen
  # diagnosable instead of silently creating a different test artifact.
  # 中文：清单与所有分片共用这份可执行文件，避免发现与执行之间重新链接。
  swift_test_args+=(--skip-build)
}

run_prepared_swift_test_command() {
  local status=0
  set +e
  python3 "${repo_root}/tools/run-command-with-timeout.py" 60 \
    env -u SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH swift "$@"
  status=$?
  set -e
  if [[ "${status}" -eq 124 ]]; then
    printf '%s\n' \
      'Swift test execution timed out. On macOS, verify Developer Tools access for the app or terminal running this gate.' >&2
    printf '%s\n' \
      '中文：Swift 测试执行超时；在 macOS 上请检查运行此门禁的 App 或终端是否获准使用开发者工具。' >&2
  fi
  return "${status}"
}

run_swift_test_shard() {
  local regex="$1"
  local expected_count="$2"
  local shard_index="$3"
  local shard_total="$4"
  local log_file="$5"
  local run_status actual_count

  printf 'Swift test shard %s/%s: expected=%s\n' \
    "$((shard_index + 1))" "${shard_total}" "${expected_count}"
  printf '中文：Swift 测试分片 %s/%s：预期 %s 项。\n' \
    "$((shard_index + 1))" "${shard_total}" "${expected_count}"

  run_status=0
  set +e
  run_prepared_swift_test_command \
    "${swift_test_args[@]}" \
    --filter "(?:${regex})" 2>&1 | tee "${log_file}"
  run_status="${PIPESTATUS[0]}"
  set -e

  if [[ "${run_status}" -ne 0 ]]; then
    fail "Swift test shard $((shard_index + 1))/${shard_total} failed."
  fi
  actual_count="$(
    sed -nE 's/.*Test run with ([0-9]+) tests?.*/\1/p' "${log_file}" \
      | tail -n 1
  )"
  if [[ -z "${actual_count}" || "${actual_count}" != "${expected_count}" ]]; then
    fail "Swift test shard $((shard_index + 1))/${shard_total} ran ${actual_count:-an unknown number of} tests; expected ${expected_count}."
  fi
}

run_full_swift_test_suite() {
  local shard_root list_file escaped_file duplicate total_tests shard_total
  local escaped regex shard_count shard_index

  shard_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-swift-shards.XXXXXX")"
  list_file="${shard_root}/tests.list"
  escaped_file="${shard_root}/tests.escaped"
  cleanup_swift_test_shards() {
    rm -rf "${shard_root}"
  }
  trap cleanup_swift_test_shards EXIT INT TERM

  printf 'Discovering the complete Swift test inventory...\n'
  printf '中文：正在发现完整 Swift 测试清单……\n'
  if ! run_prepared_swift_test_command "${swift_test_args[@]}" list >"${list_file}"; then
    fail "Could not discover the Swift test inventory."
  fi
  total_tests="$(awk 'END { print NR + 0 }' "${list_file}")"
  if [[ "${total_tests}" -eq 0 ]]; then
    fail "Swift test discovery returned an empty inventory."
  fi
  if grep -q '^[[:space:]]*$' "${list_file}"; then
    fail "Swift test discovery returned a blank test specifier."
  fi
  duplicate="$(
    LC_ALL=C sort "${list_file}" | uniq -d | sed -n '1p'
  )"
  if [[ -n "${duplicate}" ]]; then
    fail "Swift test discovery returned a duplicate specifier: ${duplicate}"
  fi

  # Escape every extended-regex metacharacter before joining exact SwiftPM
  # specifiers with alternation. Swift Testing 1902 matches a hidden wrapper
  # around the visible specifier, so the alternatives intentionally remain
  # unanchored while still containing the unique target and full function
  # signature. 中文：先转义每个 ERE 元字符；Testing 1902 的匹配串含隐藏包装，
  # 因此不加首尾锚点，但每项仍包含唯一 target 与完整函数签名。
  sed 's/[][(){}.^$|?*+\\]/\\&/g' "${list_file}" >"${escaped_file}"

  shard_total=$((
    (total_tests + swift_test_shard_size - 1) / swift_test_shard_size
  ))
  printf 'Running %s Swift tests in %s exact shards of at most %s tests.\n' \
    "${total_tests}" "${shard_total}" "${swift_test_shard_size}"
  printf '中文：将 %s 项 Swift 测试按最多 %s 项拆为 %s 个精确分片。\n' \
    "${total_tests}" "${swift_test_shard_size}" "${shard_total}"

  regex=""
  shard_count=0
  shard_index=0
  while IFS= read -r escaped || [[ -n "${escaped}" ]]; do
    if [[ "${shard_count}" -eq 0 ]]; then
      regex="${escaped}"
    else
      regex="${regex}|${escaped}"
    fi
    shard_count=$((shard_count + 1))
    if [[ "${shard_count}" -eq "${swift_test_shard_size}" ]]; then
      run_swift_test_shard \
        "${regex}" \
        "${shard_count}" \
        "${shard_index}" \
        "${shard_total}" \
        "${shard_root}/shard-${shard_index}.log"
      shard_index=$((shard_index + 1))
      shard_count=0
      regex=""
    fi
  done <"${escaped_file}"
  if [[ "${shard_count}" -gt 0 ]]; then
    run_swift_test_shard \
      "${regex}" \
      "${shard_count}" \
      "${shard_index}" \
      "${shard_total}" \
      "${shard_root}/shard-${shard_index}.log"
    shard_index=$((shard_index + 1))
  fi
  if [[ "${shard_index}" -ne "${shard_total}" ]]; then
    fail "Swift test sharding produced ${shard_index} shards; expected ${shard_total}."
  fi

  trap - EXIT INT TERM
  cleanup_swift_test_shards
  printf 'Swift test inventory passed: %s/%s tests across %s shards.\n' \
    "${total_tests}" "${total_tests}" "${shard_total}"
  printf '中文：Swift 测试清单通过：%s/%s 项，分为 %s 个分片。\n' \
    "${total_tests}" "${total_tests}" "${shard_total}"
}

run_selected_swift_tests() {
  if [[ "${test_filter_set}" -eq 1 ]]; then
    run_prepared_swift_test_command "${swift_test_args[@]}"
    return
  fi
  run_full_swift_test_suite
}

if plain_swift_testing_available; then
  if [[ "${probe_only}" -eq 1 ]]; then
    printf 'Swift prerequisite ok: Swift Testing is available through the selected toolchain.\n'
    printf '中文：Swift 依赖检查通过：当前 toolchain 可直接使用 Swift Testing。\n'
    exit 0
  fi
  prepare_swift_test_bundle
  run_selected_swift_tests
  exit 0
fi

if [[ -n "${testing_framework_dir}" \
    && -n "${testing_macros}" \
    && -n "${testing_interop_dir}" ]] \
    && explicit_swift_testing_available; then
  # English: Command Line Tools can ship Swift Testing outside SwiftPM's default
  # search paths. 中文：仅安装 Command Line Tools 时，Swift Testing 可能在 SwiftPM
  # 默认搜索路径之外，因此这里显式传入 framework、macro plugin 和运行时 rpath。
  explicit_swift_testing_args=(
    -Xswiftc -F
    -Xswiftc "${testing_framework_dir}"
    -Xswiftc -load-plugin-library
    -Xswiftc "${testing_macros}"
    -Xlinker -rpath
    -Xlinker "${testing_framework_dir}"
    -Xlinker -rpath
    -Xlinker "${testing_interop_dir}"
  )
  swift_build_args+=("${explicit_swift_testing_args[@]}")
  swift_test_args+=("${explicit_swift_testing_args[@]}")

  if [[ "${probe_only}" -eq 1 ]]; then
    printf 'Swift prerequisite ok: using explicit Swift Testing paths from %s.\n' "${testing_framework_dir}"
    printf '中文：Swift 依赖检查通过：使用来自 %s 的显式 Swift Testing 路径。\n' "${testing_framework_dir}"
    exit 0
  fi
  prepare_swift_test_bundle
  run_selected_swift_tests
  exit 0
fi

print_swift_testing_diagnostics
fail "Swift Testing not found. English: install/select full Xcode 16+ or Command Line Tools with Testing.framework and TestingMacros. 中文：未找到 Swift Testing；请安装/切换完整 Xcode 16+，或安装包含 Testing.framework 和 TestingMacros 的 Command Line Tools。"
