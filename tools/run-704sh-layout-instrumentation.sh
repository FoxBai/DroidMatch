#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"
# shellcheck source=tools/git-main-read.sh
source "${repo_root}/tools/git-main-read.sh"
# shellcheck source=tools/product-usb-evidence-publication.sh
source "${repo_root}/tools/product-usb-evidence-publication.sh"

usage() {
  cat <<'EOF'
Usage: tools/run-704sh-layout-instrumentation.sh --serial <adb-serial> [--skip-build]
       [--interactive-timeout-seconds <seconds>]

Formal evidence usage:
  tools/run-704sh-layout-instrumentation.sh \
    --serial <adb-serial> \
    --expected-main-sha <40-hex-origin-main-sha> \
    --result-log fixtures/android-layout/<name>.md

Runs the exact slot-a-704sh-layout-v2 instrumentation profile without Gradle's
connected-test installer. The product package must already be installed. The
runner installs the test APK first, replaces the product APK only with `-r`,
and removes only app.droidmatch.test on every owned post-install exit.

Without the two formal-evidence options this remains an attended focused
diagnostic. Formal evidence requires clean current origin/main, the default
300-second timeout, no APK path override, a from-scratch rebuild, and a new
result path under fixtures/android-layout/. It publishes only a fixed,
privacy-bounded summary after the exact one-test pass and verified cleanup.
Every ADB query, install, instrumentation, and cleanup command is bounded. The
interactive install/instrumentation timeout defaults to 300 seconds and may be
set to a positive value no greater than 600 seconds.
After any timed-out create-only install, ownership remains unresolved even when
the package is currently absent: the OEM may still commit it later. Wait and
recheck for rollback or a late commit, or separately establish ownership before
cleanup; rerunning refuses to touch a pre-existing test package.

中文：运行精确的 slot-a-704sh-layout-v2 真机布局诊断，不调用 Gradle
connected-test 安装流程。设备上必须已有产品包；脚本先安装测试 APK，随后仅用
`-r` 覆盖产品 APK，并在明确取得所有权后的退出路径中只移除 app.droidmatch.test。

不提供两项正式证据参数时，这仍是需要人在场的定向诊断。正式证据要求 clean current
origin/main、默认 300 秒超时、无 APK 路径覆盖、从头构建，并使用
fixtures/android-layout/ 下的新结果路径；只有精确一项测试通过且清理已确认后，
才发布固定、脱敏的摘要。
全部 ADB 查询、安装、instrumentation 与清理命令都有界；交互命令默认
300 秒，可设置为大于 0 且不超过 600 秒。
仅新建安装只要超时，所有权就保持未决；即使当下看不到测试包，OEM 仍可能稍后提交。
请等待并复查回滚或延迟提交，或另行确认所有权后再清理；重新运行时，脚本会拒绝
接管预先存在的测试包。
EOF
}

serial=""
skip_build=false
interactive_timeout_seconds=300
expected_main_sha=""
result_log=""
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
    --interactive-timeout-seconds)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      interactive_timeout_seconds="$2"
      shift 2
      ;;
    --expected-main-sha)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      expected_main_sha="$2"
      shift 2
      ;;
    --result-log)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      result_log="$2"
      shift 2
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
timeout_shape_valid=true
if [[ ! "$interactive_timeout_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  timeout_shape_valid=false
fi
timeout_in_range=no
if [[ "$timeout_shape_valid" == true ]]; then
  timeout_in_range="$(awk -v value="$interactive_timeout_seconds" \
    'BEGIN { print (value > 0 && value <= 600) ? "yes" : "no" }')"
fi
if [[ "$timeout_shape_valid" != true || "$timeout_in_range" != yes ]]; then
  echo "The interactive timeout must be greater than 0 and no greater than 600 seconds." >&2
  echo "中文：交互超时必须大于 0 且不超过 600 秒。" >&2
  exit 2
fi

android_dir="$repo_root/android"
bounded_runner="$repo_root/tools/run-command-with-timeout.py"
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
query_timeout_seconds=15
cleanup_timeout_seconds=30
evidence_profile="m1-android-launcher-layout-v1"
evidence_checker="$repo_root/tools/check-android-layout-evidence.sh"
main_refresh_attempts=3
main_refresh_interval_seconds=2
formal_evidence=false
source_revision=""
origin_main_revision=""
product_apk_sha256=""
test_apk_sha256=""

if [[ -n "${result_log}" || -n "${expected_main_sha}" ]]; then
  formal_evidence=true
  [[ "${expected_main_sha}" =~ ^[0-9a-f]{40}$ && -n "${result_log}" ]] || {
    echo "Formal evidence requires --expected-main-sha and --result-log." >&2
    echo "中文：正式证据必须同时提供 --expected-main-sha 与 --result-log。" >&2
    exit 2
  }
  [[ "${skip_build}" == false && "${interactive_timeout_seconds}" == 300 \
      && -z "${DROIDMATCH_PRODUCT_APK:-}" && -z "${DROIDMATCH_TEST_APK:-}" \
      && -z "${ADB_BIN:-}" ]] || {
    echo "Formal evidence requires the default timeout and a clean rebuild without APK or ADB overrides." >&2
    echo "中文：正式证据要求默认超时，并在没有 APK 或 ADB 覆盖的情况下从头构建。" >&2
    exit 2
  }
  [[ "${result_log}" =~ ^fixtures/android-layout/[A-Za-z0-9][A-Za-z0-9._-]*[.]md$ \
      && "$(basename "${result_log}")" != README.md \
      && ! -e "${result_log}" && ! -L "${result_log}" \
      && ! -e "${result_log}.commit" && ! -L "${result_log}.commit" ]] || {
    echo "Formal result log must be a new simple Markdown path under fixtures/android-layout/." >&2
    echo "中文：正式结果必须是 fixtures/android-layout/ 下全新的简单 Markdown 路径。" >&2
    exit 2
  }
  bash "${evidence_checker}" >/dev/null 2>&1 || {
    echo "Formal evidence requires a clean Android layout fixture directory." >&2
    echo "中文：正式证据要求 Android 布局 fixture 目录处于可验证状态。" >&2
    exit 1
  }
  refresh_origin_branch_with_retry \
    origin main "${main_refresh_attempts}" "${main_refresh_interval_seconds}" || {
    echo "Could not refresh origin/main before the attended run." >&2
    echo "中文：人工运行前无法刷新 origin/main。" >&2
    exit 1
  }
  source_revision="$(git rev-parse HEAD 2>/dev/null || true)"
  origin_main_revision="$(git rev-parse refs/remotes/origin/main 2>/dev/null || true)"
  pre_run_git_status="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null)" || {
    echo "Could not verify repository cleanliness before the attended run." >&2
    exit 1
  }
  [[ "${source_revision}" == "${expected_main_sha}" \
      && "${origin_main_revision}" == "${expected_main_sha}" \
      && -z "${pre_run_git_status}" ]] || {
    echo "Formal evidence requires clean HEAD, expected SHA, and fresh origin/main to match." >&2
    echo "中文：正式证据要求 clean HEAD、预期 SHA 与最新 origin/main 完全一致。" >&2
    exit 1
  }
fi

if [[ "$adb_bin" == */* ]]; then
  [[ -x "$adb_bin" ]] || {
    echo "ADB executable is unavailable." >&2
    exit 2
  }
elif ! command -v "$adb_bin" >/dev/null 2>&1; then
  echo "ADB executable is unavailable." >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1 || [[ ! -f "$bounded_runner" ]]; then
  echo "The bounded command runner is unavailable." >&2
  echo "中文：有界命令 runner 不可用。" >&2
  exit 2
fi

run_adb_with_timeout() {
  local timeout_seconds="$1"
  shift
  python3 "$bounded_runner" "$timeout_seconds" "$adb_bin" -s "$serial" "$@"
}

package_state() {
  local package_name="$1"
  local output
  local command_status
  if output="$(run_adb_with_timeout "$query_timeout_seconds" \
      shell pm path "$package_name" 2>/dev/null)"; then
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
  run_adb_with_timeout "$cleanup_timeout_seconds" \
    uninstall "$test_package" >/dev/null 2>&1 || true
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

state="$(run_adb_with_timeout "$query_timeout_seconds" get-state 2>/dev/null || true)"
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
    if [[ "${formal_evidence}" == true ]]; then
      ./gradlew --no-daemon clean :app:assembleDebug :app:assembleDebugAndroidTest
    else
      ./gradlew --no-daemon :app:assembleDebug :app:assembleDebugAndroidTest
    fi
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
if [[ "${formal_evidence}" == true ]]; then
  command -v shasum >/dev/null 2>&1 || {
    echo "The SHA-256 tool required for formal evidence is unavailable." >&2
    echo "中文：正式证据所需的 SHA-256 工具不可用。" >&2
    exit 2
  }
  product_apk_sha256="$(shasum -a 256 "${product_apk}" | awk '{print $1}')"
  test_apk_sha256="$(shasum -a 256 "${test_apk}" | awk '{print $1}')"
  [[ "${product_apk_sha256}" =~ ^[0-9a-f]{64}$ \
      && "${test_apk_sha256}" =~ ^[0-9a-f]{64}$ \
      && "${product_apk_sha256}" != "${test_apk_sha256}" ]] || {
    echo "Could not establish distinct APK fingerprints for formal evidence." >&2
    echo "中文：无法为正式证据建立两份不同的 APK 指纹。" >&2
    exit 1
  }
fi

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
test_install_status=0
run_adb_with_timeout "$interactive_timeout_seconds" \
  install -t "$test_apk" >"$result_file" 2>&1 || test_install_status=$?
if [[ $test_install_status -ne 0 ]]; then
  if [[ $test_install_status -eq 124 ]]; then
    if package_state "$test_package"; then
      echo "Test APK installation timed out; ownership is unresolved and the package is currently visible, so it remains untouched." >&2
      echo "中文：测试 APK 安装超时；所有权未决且包当前可见，因此脚本保留该包且不作删除。" >&2
    else
      package_status=$?
      if [[ $package_status -eq 1 ]]; then
        echo "Test APK installation timed out while the package was absent, but the OEM may commit it later; ownership remains unresolved." >&2
        echo "中文：测试 APK 安装超时时包尚不存在，但 OEM 仍可能稍后提交；所有权保持未决。" >&2
      else
        echo "Test APK installation timed out and its package state could not be verified; ownership remains unresolved." >&2
        echo "中文：测试 APK 安装超时且无法确认包状态；所有权保持未决。" >&2
      fi
    fi
    echo "Wait and recheck for OEM rollback or a late commit before rerunning or cleaning up." >&2
    echo "中文：重新运行或清理前，请等待并复查 OEM 回滚或延迟提交。" >&2
    exit 4
  fi
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

product_install_status=0
run_adb_with_timeout "$interactive_timeout_seconds" \
  install -r "$product_apk" >"$result_file" 2>&1 || product_install_status=$?
if [[ $product_install_status -ne 0 ]]; then
  if [[ $product_install_status -eq 124 ]]; then
    echo "Product APK replacement timed out; product uninstall and data clearing were not attempted." >&2
    echo "中文：产品 APK 保留数据覆盖超时；脚本未尝试卸载产品或清空数据。" >&2
  else
    echo "Product APK replacement failed; product uninstall and data clearing were not attempted." >&2
    echo "中文：产品 APK 保留数据覆盖失败；脚本未尝试卸载产品或清空数据。" >&2
  fi
  exit 3
fi

instrumentation_status=0
run_adb_with_timeout "$interactive_timeout_seconds" shell am instrument -w -r \
    -e layout_profile "$profile" \
    -e class "$test_class" \
    "$runner" >"$result_file" 2>&1 || instrumentation_status=$?
if [[ $instrumentation_status -ne 0 ]]; then
  if [[ $instrumentation_status -eq 124 ]]; then
    echo "The 704SH layout instrumentation command timed out." >&2
    echo "中文：704SH 布局 instrumentation 命令超时。" >&2
  else
    echo "The 704SH layout instrumentation command failed." >&2
    echo "中文：704SH 布局 instrumentation 命令执行失败。" >&2
  fi
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

if [[ "${formal_evidence}" == true ]]; then
  post_product_apk_sha256="$(shasum -a 256 "${product_apk}" | awk '{print $1}')"
  post_test_apk_sha256="$(shasum -a 256 "${test_apk}" | awk '{print $1}')"
  [[ "${post_product_apk_sha256}" == "${product_apk_sha256}" \
      && "${post_test_apk_sha256}" == "${test_apk_sha256}" ]] || {
    echo "APK provenance changed during the attended run; evidence refused." >&2
    echo "中文：人工运行期间 APK 来源发生变化；拒绝发布证据。" >&2
    exit 1
  }
  refresh_origin_branch_with_retry \
    origin main "${main_refresh_attempts}" "${main_refresh_interval_seconds}" || {
    echo "Could not refresh origin/main after the attended run." >&2
    echo "中文：人工运行后无法刷新 origin/main。" >&2
    exit 1
  }
  post_source_revision="$(git rev-parse HEAD 2>/dev/null || true)"
  post_origin_main_revision="$(git rev-parse refs/remotes/origin/main 2>/dev/null || true)"
  post_run_git_status="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null)" || {
    echo "Could not verify repository cleanliness after the attended run." >&2
    exit 1
  }
  [[ "${post_source_revision}" == "${source_revision}" \
      && "${post_origin_main_revision}" == "${origin_main_revision}" \
      && "${post_source_revision}" == "${expected_main_sha}" \
      && -z "${post_run_git_status}" ]] || {
    echo "Repository provenance changed during the attended run; evidence refused." >&2
    echo "中文：人工运行期间仓库来源发生变化；拒绝发布证据。" >&2
    exit 1
  }
  bash "${evidence_checker}" >/dev/null 2>&1 || {
    echo "The Android layout fixture directory changed during the attended run." >&2
    echo "中文：人工运行期间 Android 布局 fixture 目录发生变化。" >&2
    exit 1
  }

  staged_log="${result_log}.commit"
  if ! companion_digest="$(
    {
      printf '# M1 Android Launcher Layout Evidence\n\n'
      printf 'status: passed\n'
      printf 'evidence profile: %s\n' "${evidence_profile}"
      printf 'profile result: passed\n'
      printf 'date: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')"
      printf 'device slot: A\n'
      printf 'device model: SHARP 704SH\n'
      printf 'android api: 26\n'
      printf 'instrumentation profile: %s\n' "${profile}"
      printf 'instrumentation class: %s\n' "${test_class}"
      printf 'instrumentation tests expected: 1\n'
      printf 'instrumentation tests passed: 1\n'
      printf 'profile source revision: %s\n' "${source_revision}"
      printf 'profile expected main revision: %s\n' "${expected_main_sha}"
      printf 'profile origin main revision: %s\n' "${origin_main_revision}"
      printf 'profile source dirty: false\n'
      printf 'build mode: debug-clean-rebuild\n'
      printf 'product apk sha256: %s\n' "${product_apk_sha256}"
      printf 'test apk sha256: %s\n' "${test_apk_sha256}"
      printf 'product package preexisting: true\n'
      printf 'test package absent before run: true\n'
      printf 'test apk install mode: create-only\n'
      printf 'product apk replacement mode: install-r-preserve-data\n'
      printf 'product data preservation: no-uninstall-no-clear\n'
      printf 'test package cleanup verified: true\n'
      printf 'product package remained installed: true\n'
      printf 'repository clean before run: true\n'
      printf 'repository clean after run: true\n'
      printf 'physical display: 720x1280\n'
      printf 'app viewport: 720x1136\n'
      printf 'density dpi: 320\n'
      printf 'locale: en-US\n'
      printf 'font scale: 1.3\n'
      printf 'layout assertion set: initial-action,uniform-action-rows,media-detail-rows,text-fit,full-scroll,final-control\n'
      printf 'raw instrumentation output included: false\n'
      printf 'adb serial included: false\n'
    } | create_evidence_commit_companion "${result_log}" "${evidence_checker}"
  )"; then
    echo "Could not safely create the Android layout commit companion; inspect the fixture directory before retrying." >&2
    echo "中文：无法安全创建 Android 布局 commit 伴随文件；重试前必须检查 fixture 目录。" >&2
    exit 1
  fi
  [[ "${companion_digest}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "The Android layout commit companion returned an invalid digest." >&2
    exit 1
  }
  set +e
  publish_staged_evidence \
    "${staged_log}" "${result_log}" "${evidence_checker}" "${companion_digest}"
  publication_status=$?
  set -e
  if [[ "${publication_status}" -eq "${EVIDENCE_PUBLICATION_UNCERTAIN_STATUS}" ]]; then
    echo "Android layout evidence publication is uncertain; do not delete or rerun automatically, and inspect the fixture pair." >&2
    echo "中文：Android 布局证据发布状态不确定；不得自动删除或重试，必须检查文件对。" >&2
    exit "${publication_status}"
  elif [[ "${publication_status}" -ne 0 ]]; then
    echo "Could not complete no-clobber Android layout publication; inspect the retained companion before retrying." >&2
    echo "中文：无法完成 Android 布局 no-clobber 发布；重试前必须检查保留的伴随文件。" >&2
    exit "${publication_status}"
  fi
fi

echo "704SH layout v2 diagnostic passed; test package removed and product data preserved."
echo "中文：704SH 布局 v2 诊断通过；测试包已移除，产品数据保持不变。"
if [[ "${formal_evidence}" == true ]]; then
  printf 'Android layout evidence written: %s\n' "${result_log}"
  printf 'Android 布局证据已写入：%s\n' "${result_log}"
fi
