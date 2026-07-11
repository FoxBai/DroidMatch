#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/run-android-keystore-instrumentation.sh --serial <adb-serial> [--skip-build]

Runs the isolated Android Keystore instrumentation tests without invoking
Gradle's connected-test installer. The product package must already be present.
Only the test package is installed and removed; product data is never uninstalled.
An OEM may require the user to approve the test-APK install on the phone.

中文：运行隔离的 Android Keystore 真机测试，不调用 Gradle connected-test
安装流程。设备上必须已有产品包；脚本只安装和移除测试包，绝不卸载产品数据。
部分 OEM 会要求用户在手机上批准测试 APK 安装，因此真机运行可能需要人在场。
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
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$serial" ]] || { usage >&2; exit 2; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
android_dir="$repo_root/android"
target_package="app.droidmatch"
test_package="app.droidmatch.test"
runner="$test_package/androidx.test.runner.AndroidJUnitRunner"
test_apk="${DROIDMATCH_TEST_APK:-$android_dir/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk}"
adb_bin="${ADB_BIN:-adb}"
result_file="$(mktemp "${TMPDIR:-/tmp}/droidmatch-keystore-instrumentation.XXXXXX")"
test_installed=false

cleanup() {
  rm -f "$result_file"
  if [[ "$test_installed" == true ]]; then
    "$adb_bin" -s "$serial" uninstall "$test_package" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"$adb_bin" -s "$serial" get-state >/dev/null

if [[ "$skip_build" != true ]]; then
  (
    cd "$android_dir"
    ./gradlew --no-daemon :app:assembleDebug :app:assembleDebugAndroidTest
  )
fi

[[ -f "$test_apk" ]] || {
  echo "Instrumentation APK is missing; build it without --skip-build first." >&2
  exit 2
}

if ! "$adb_bin" -s "$serial" shell pm path "$target_package" | grep -q '^package:'; then
  echo "DroidMatch product package is not installed; refusing to alter product state." >&2
  echo "中文：设备上没有 DroidMatch 产品包；为保护产品数据，脚本拒绝继续。" >&2
  exit 2
fi

# Installing the test APK first is deliberate. Gradle connectedDebugAndroidTest
# may uninstall the target package before an OEM rejects this step, destroying
# the product's private test data. This runner never asks Gradle to manage apps.
echo "Check the selected phone now and approve the test-APK install if the OEM asks."
echo "中文：现在请查看所选手机；如 OEM 弹出测试 APK 安装确认，请手动点按允许。"
if ! "$adb_bin" -s "$serial" install -r -t "$test_apk"; then
  echo "Test APK installation was rejected; product package and data were left intact." >&2
  echo "中文：测试 APK 安装被设备拒绝；产品包与产品数据均保持不变。" >&2
  exit 3
fi
test_installed=true

"$adb_bin" -s "$serial" shell am instrument -w -r "$runner" | tee "$result_file"
if grep -q '^FAILURES!!!' "$result_file" \
    || ! grep -Eq '^OK \([1-9][0-9]* tests?\)$' "$result_file"; then
  echo "Android Keystore instrumentation did not report a passing test run." >&2
  exit 1
fi

echo "Android Keystore instrumentation passed; product data was preserved."
echo "中文：Android Keystore 真机测试通过，产品数据保持不变。"
