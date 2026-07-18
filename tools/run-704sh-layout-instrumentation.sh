#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/run-704sh-layout-instrumentation.sh --serial <adb-serial> [--skip-build]

Runs the exact slot-a-704sh-layout-v2 instrumentation profile without Gradle's
connected-test installer. The product package must already be installed. The
runner installs the test APK first, replaces the product APK only with `-r`,
and removes only app.droidmatch.test on every post-install exit.

This is an attended focused diagnostic, not archivable M1 device evidence.

中文：运行精确的 slot-a-704sh-layout-v2 真机布局诊断，不调用 Gradle
connected-test 安装流程。设备上必须已有产品包；脚本先安装测试 APK，随后仅用
`-r` 覆盖产品 APK，并在所有安装后退出路径中只移除 app.droidmatch.test。

这是需要人在场的定向诊断，不属于可归档的 M1 真机证据。
EOF
}

serial=""
skip_build=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      serial="$2"
      shift 2
      ;;
    --skip-build)
      skip_build=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument." >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$serial" ]] || { usage >&2; exit 2; }
if [[ ! "$serial" =~ ^[A-Za-z0-9._:-]{6,128}$ ]]; then
  echo "The selected ADB serial has an unsupported format." >&2
  echo "中文：所选 ADB serial 格式不受支持。" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
android_dir="$repo_root/android"
target_package="app.droidmatch"
test_package="app.droidmatch.test"
profile="slot-a-704sh-layout-v2"
test_class="app.droidmatch.m1.DroidMatchActivityLayoutInstrumentationTest"
runner="$test_package/androidx.test.runner.AndroidJUnitRunner"
product_apk="${DROIDMATCH_PRODUCT_APK:-$android_dir/app/build/outputs/apk/debug/app-debug.apk}"
test_apk="${DROIDMATCH_TEST_APK:-$android_dir/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk}"
adb_bin="${ADB_BIN:-adb}"
result_file=""
test_cleanup_required=false
product_verification_required=false

if [[ "$adb_bin" == */* ]]; then
  [[ -x "$adb_bin" ]] || {
    echo "ADB executable is unavailable." >&2
    exit 2
  }
elif ! command -v "$adb_bin" >/dev/null 2>&1; then
  echo "ADB executable is unavailable." >&2
  exit 2
fi

package_state() {
  local package_name="$1"
  local output
  local command_status
  if output="$("$adb_bin" -s "$serial" shell pm path "$package_name" 2>/dev/null)"; then
    command_status=0
  else
    command_status=$?
  fi
  if [[ "$output" == package:* || "$output" == *$'\npackage:'* ]]; then
    return 0
  fi
  if [[ -z "$output" && ( $command_status -eq 0 || $command_status -eq 1 ) ]]; then
    return 1
  fi
  return 2
}

cleanup_test_package() {
  [[ "$test_cleanup_required" == true ]] || return 0
  "$adb_bin" -s "$serial" uninstall "$test_package" >/dev/null 2>&1 || true
  if package_state "$test_package"; then
    return 1
  else
    local state=$?
    [[ $state -eq 1 ]] || return 1
  fi
  test_cleanup_required=false
}

on_exit() {
  local status=$?
  trap - EXIT
  if ! cleanup_test_package; then
    echo "Could not verify removal of the layout test package." >&2
    echo "中文：无法确认布局测试包已经移除。" >&2
    status=4
  fi
  if [[ "$product_verification_required" == true ]]; then
    if package_state "$target_package"; then
      :
    else
      echo "Could not verify that the DroidMatch product package remains installed." >&2
      echo "中文：无法确认 DroidMatch 产品包仍保持安装。" >&2
      status=4
    fi
  fi
  [[ -z "$result_file" ]] || rm -f "$result_file"
  exit "$status"
}
trap on_exit EXIT
result_file="$(mktemp "${TMPDIR:-/tmp}/droidmatch-704sh-layout.XXXXXX")"

state="$("$adb_bin" -s "$serial" get-state 2>/dev/null || true)"
if [[ "$state" != device ]]; then
  echo "The selected Android device is not ready." >&2
  echo "中文：所选 Android 设备尚未就绪。" >&2
  exit 2
fi

if package_state "$target_package"; then
  product_verification_required=true
else
  package_status=$?
  if [[ $package_status -eq 1 ]]; then
    echo "DroidMatch product package is not installed; refusing to alter product state." >&2
    echo "中文：设备上没有 DroidMatch 产品包；为保护产品状态，脚本拒绝继续。" >&2
  else
    echo "Could not verify the DroidMatch product package; refusing to continue." >&2
    echo "中文：无法确认 DroidMatch 产品包状态；脚本拒绝继续。" >&2
  fi
  exit 2
fi

if [[ "$skip_build" != true ]]; then
  (
    cd "$android_dir"
    ./gradlew --no-daemon :app:assembleDebug :app:assembleDebugAndroidTest
  )
fi

[[ -f "$product_apk" ]] || {
  echo "Product debug APK is missing; build it without --skip-build first." >&2
  echo "中文：缺少产品 debug APK；请先在不使用 --skip-build 的情况下构建。" >&2
  exit 2
}
[[ -f "$test_apk" ]] || {
  echo "Layout instrumentation APK is missing; build it without --skip-build first." >&2
  echo "中文：缺少布局 instrumentation APK；请先完成构建。" >&2
  exit 2
}

# Recheck package ownership only after the potentially long build. The test APK
# uses create-only install (no -r), so a concurrent caller wins safely and this
# runner never acquires or removes that caller's package.
if ! package_state "$target_package"; then
  echo "The DroidMatch product package changed during preparation; refusing to continue." >&2
  echo "中文：准备期间 DroidMatch 产品包状态发生变化；脚本拒绝继续。" >&2
  exit 4
fi

if package_state "$test_package"; then
  echo "A layout test package already exists; refusing to remove caller-owned state." >&2
  echo "中文：设备上已有布局测试包；脚本拒绝移除调用方已有状态。" >&2
  exit 2
else
  package_status=$?
  if [[ $package_status -ne 1 ]]; then
    echo "Could not verify that the layout test package is absent." >&2
    echo "中文：无法确认布局测试包不存在。" >&2
    exit 2
  fi
fi

# The OEM may reject the test APK. Attempt it before touching the product APK.
# Cleanup ownership begins only after a create-only installation succeeds.
echo "Check the selected phone and approve the test-APK install if the OEM asks."
echo "中文：请查看所选手机；如 OEM 弹出测试 APK 安装确认，请手动允许。"
if ! "$adb_bin" -s "$serial" install -t "$test_apk" >"$result_file" 2>&1; then
  if package_state "$test_package"; then
    echo "Test APK ownership is ambiguous after a failed install; leaving it untouched." >&2
    echo "中文：测试 APK 安装失败后所有权不明确；脚本保留该包且不作删除。" >&2
    exit 4
  else
    package_status=$?
    if [[ $package_status -eq 1 ]]; then
      echo "Test APK installation was rejected; the product package was not replaced." >&2
      echo "中文：测试 APK 安装被拒绝；产品包未被覆盖。" >&2
      exit 3
    fi
    echo "Test APK installation failed and its resulting state could not be verified." >&2
    echo "中文：测试 APK 安装失败，且无法确认安装后的包状态。" >&2
    exit 4
  fi
fi
test_cleanup_required=true

if ! "$adb_bin" -s "$serial" install -r "$product_apk" >"$result_file" 2>&1; then
  echo "Product APK replacement failed; product uninstall and data clearing were not attempted." >&2
  echo "中文：产品 APK 保留数据覆盖失败；脚本未尝试卸载产品或清空数据。" >&2
  exit 3
fi

if ! "$adb_bin" -s "$serial" shell am instrument -w -r \
    -e layout_profile "$profile" \
    -e class "$test_class" \
    "$runner" >"$result_file" 2>&1; then
  echo "The 704SH layout instrumentation command failed." >&2
  echo "中文：704SH 布局 instrumentation 命令执行失败。" >&2
  exit 1
fi

if grep -Fq 'FAILURES!!!' "$result_file" \
    || grep -Fq 'INSTRUMENTATION_FAILED' "$result_file" \
    || grep -Eq '^INSTRUMENTATION_STATUS_CODE: -[0-9]+$' "$result_file" \
    || ! grep -Fqx 'INSTRUMENTATION_STATUS_CODE: 0' "$result_file" \
    || ! grep -Fqx 'OK (1 test)' "$result_file"; then
  echo "The exact 704SH v2 layout profile did not report one passing test." >&2
  echo "中文：精确 704SH v2 布局 profile 未报告唯一一项通过。" >&2
  exit 1
fi

if ! cleanup_test_package; then
  echo "The layout test passed, but test-package cleanup could not be verified." >&2
  echo "中文：布局测试已通过，但无法确认测试包清理完成。" >&2
  exit 4
fi

if package_state "$target_package"; then
  product_verification_required=false
else
  echo "The layout test passed, but the product package could not be verified afterward." >&2
  echo "中文：布局测试已通过，但随后无法确认产品包仍然存在。" >&2
  exit 4
fi

echo "704SH layout v2 diagnostic passed; test package removed and product data preserved."
echo "中文：704SH 布局 v2 诊断通过；测试包已移除，产品数据保持不变。"
