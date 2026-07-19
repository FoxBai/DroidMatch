#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$repo_root/tools/run-704sh-layout-instrumentation.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-704sh-runner-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

fake_adb="$test_root/adb"
product_apk="$test_root/product.apk"
test_apk="$test_root/test.apk"
command_log="$test_root/commands.log"
product_state="$test_root/product-present"
test_state="$test_root/test-present"
test_serial="test-device"
touch "$product_apk" "$test_apk"

cat > "$fake_adb" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE_ADB_LOG"
case "$*" in
  *" get-state")
    printf '%s\n' "${FAKE_ADB_DEVICE_STATE:-device}"
    ;;
  *" shell pm path app.droidmatch.test")
    [[ "${FAKE_PM_QUERY_RESULT:-pass}" == pass ]] || exit 2
    [[ -e "$FAKE_TEST_STATE" ]] && printf '%s\n' 'package:/data/app/test.apk'
    [[ -e "$FAKE_TEST_STATE" ]]
    ;;
  *" shell pm path app.droidmatch")
    [[ "${FAKE_PM_QUERY_RESULT:-pass}" == pass ]] || exit 2
    [[ -e "$FAKE_PRODUCT_STATE" ]] && printf '%s\n' 'package:/data/app/product.apk'
    [[ -e "$FAKE_PRODUCT_STATE" ]]
    ;;
  *" install -t "*)
    case "${FAKE_TEST_INSTALL_RESULT:-pass}" in
      pass)
        : > "$FAKE_TEST_STATE"
        printf '%s\n' 'Success'
        ;;
      reject)
        exit 1
        ;;
      partial)
        : > "$FAKE_TEST_STATE"
        exit 1
        ;;
      hang)
        : > "$FAKE_TEST_STATE"
        sleep 2
        ;;
      hang-empty)
        sleep 2
        ;;
      *)
        exit 90
        ;;
    esac
    ;;
  *" install -r "*)
    case "${FAKE_PRODUCT_INSTALL_RESULT:-pass}" in
      pass)
        : > "$FAKE_PRODUCT_STATE"
        printf '%s\n' 'Success'
        ;;
      reject)
        exit 1
        ;;
      hang)
        sleep 2
        ;;
      *)
        exit 92
        ;;
    esac
    ;;
  *" shell am instrument "*)
    case "${FAKE_INSTRUMENTATION_RESULT:-pass}" in
      pass)
        printf '%s\n' 'INSTRUMENTATION_STATUS_CODE: 0' 'OK (1 test)'
        ;;
      fail)
        printf '%s\n' 'FAILURES!!!' 'Tests run: 1,  Failures: 1'
        exit 1
        ;;
      hang)
        sleep 2
        ;;
      wrong-count)
        printf '%s\n' 'INSTRUMENTATION_STATUS_CODE: 0' 'OK (2 tests)'
        ;;
      skipped)
        printf '%s\n' 'INSTRUMENTATION_STATUS_CODE: -3' 'OK (1 test)'
        ;;
      statusless)
        printf '%s\n' 'OK (1 test)'
        ;;
      drop-product)
        rm -f "$FAKE_PRODUCT_STATE"
        printf '%s\n' 'INSTRUMENTATION_STATUS_CODE: 0' 'OK (1 test)'
        ;;
      *)
        exit 91
        ;;
    esac
    ;;
  *" uninstall app.droidmatch.test")
    if [[ "${FAKE_CLEANUP_RESULT:-pass}" == pass ]]; then
      rm -f "$FAKE_TEST_STATE"
      printf '%s\n' 'Success'
    else
      exit 1
    fi
    ;;
  *" uninstall app.droidmatch"|*" shell pm clear app.droidmatch")
    printf '%s\n' 'unsafe product mutation requested' >&2
    exit 92
    ;;
esac
EOF
chmod +x "$fake_adb"

reset_case() {
  : > "$command_log"
  : > "$product_state"
  rm -f "$test_state"
  unset FAKE_TEST_INSTALL_RESULT FAKE_PRODUCT_INSTALL_RESULT
  unset FAKE_INSTRUMENTATION_RESULT FAKE_CLEANUP_RESULT FAKE_PM_QUERY_RESULT
}

run_case() {
  set +e
  case_output="$(
    FAKE_ADB_LOG="$command_log" \
    FAKE_PRODUCT_STATE="$product_state" \
    FAKE_TEST_STATE="$test_state" \
    ADB_BIN="$fake_adb" \
    DROIDMATCH_PRODUCT_APK="$product_apk" \
    DROIDMATCH_TEST_APK="$test_apk" \
      "$runner" --serial "$test_serial" --skip-build "$@" 2>&1
  )"
  case_status=$?
  set -e
  ! grep -Fq "$test_serial" <<<"$case_output"
  ! grep -Eq 'uninstall app\.droidmatch$' "$command_log"
  ! grep -Fq 'shell pm clear app.droidmatch' "$command_log"
}

set +e
missing_adb_output="$(
  TMPDIR="$test_root" ADB_BIN="$test_root/missing-adb" \
    "$runner" --serial "$test_serial" --skip-build 2>&1
)"
missing_adb_status=$?
set -e
[[ $missing_adb_status -eq 2 ]]
grep -Fq 'ADB executable is unavailable' <<<"$missing_adb_output"
! find "$test_root" -maxdepth 1 -name 'droidmatch-704sh-layout.*' -print -quit | grep -q .

reset_case
run_case --interactive-timeout-seconds 0
[[ $case_status -eq 2 ]]
grep -Fq 'interactive timeout must be greater than 0' <<<"$case_output"
[[ ! -s "$command_log" ]]

reset_case
run_case --interactive-timeout-seconds 601
[[ $case_status -eq 2 ]]
grep -Fq 'no greater than 600 seconds' <<<"$case_output"
[[ ! -s "$command_log" ]]

full_sha="1111111111111111111111111111111111111111"
reset_case
run_case --expected-main-sha "$full_sha"
[[ $case_status -eq 2 ]]
grep -Fq 'requires --expected-main-sha and --result-log' <<<"$case_output"
[[ ! -s "$command_log" ]]

reset_case
run_case --result-log fixtures/android-layout/test.md
[[ $case_status -eq 2 ]]
grep -Fq 'requires --expected-main-sha and --result-log' <<<"$case_output"
[[ ! -s "$command_log" ]]

reset_case
run_case \
  --expected-main-sha "$full_sha" \
  --result-log fixtures/android-layout/test.md
[[ $case_status -eq 2 ]]
grep -Fq 'requires the default timeout and a clean rebuild' <<<"$case_output"
[[ ! -s "$command_log" ]]

runner_help="$("$runner" --help)"
for formal_option in --expected-main-sha --result-log; do
  grep -Fq -- "$formal_option" <<<"$runner_help"
done
grep -Fq 'create_evidence_commit_companion' "$runner"
grep -Fq 'publish_staged_evidence' "$runner"
grep -Fq 'raw instrumentation output included: false' "$runner"
grep -Fq 'adb serial included: false' "$runner"

reset_case
rm -f "$product_state"
run_case
[[ $case_status -eq 2 ]]
grep -Fq 'product package is not installed' <<<"$case_output"
! grep -Fq ' install ' "$command_log"

reset_case
: > "$test_state"
run_case
[[ $case_status -eq 2 ]]
grep -Fq 'test package already exists' <<<"$case_output"
! grep -Fq 'uninstall app.droidmatch.test' "$command_log"
[[ -e "$test_state" ]]

reset_case
export FAKE_PM_QUERY_RESULT=error
run_case
[[ $case_status -eq 2 ]]
grep -Fq 'Could not verify the DroidMatch product package' <<<"$case_output"
! grep -Fq ' install ' "$command_log"

reset_case
export FAKE_TEST_INSTALL_RESULT=reject
run_case
[[ $case_status -eq 3 ]]
grep -Fq "install -t $test_apk" "$command_log"
! grep -Fq "install -r $product_apk" "$command_log"
! grep -Fq 'uninstall app.droidmatch.test' "$command_log"
[[ -e "$product_state" && ! -e "$test_state" ]]

reset_case
export FAKE_PRODUCT_INSTALL_RESULT=hang
run_case --interactive-timeout-seconds 0.05
[[ $case_status -eq 3 ]]
grep -Fq 'Product APK replacement timed out' <<<"$case_output"
grep -Fq 'uninstall app.droidmatch.test' "$command_log"
[[ -e "$product_state" && ! -e "$test_state" ]]

reset_case
export FAKE_TEST_INSTALL_RESULT=partial
run_case
[[ $case_status -eq 4 ]]
grep -Fq 'ownership is ambiguous' <<<"$case_output"
! grep -Fq 'uninstall app.droidmatch.test' "$command_log"
[[ -e "$product_state" && -e "$test_state" ]]

reset_case
export FAKE_TEST_INSTALL_RESULT=hang
run_case --interactive-timeout-seconds 0.05
[[ $case_status -eq 4 ]]
grep -Fq 'ownership is unresolved and the package is currently visible' <<<"$case_output"
! grep -Fq "install -r $product_apk" "$command_log"
! grep -Fq 'uninstall app.droidmatch.test' "$command_log"
[[ -e "$product_state" && -e "$test_state" ]]

reset_case
export FAKE_TEST_INSTALL_RESULT=hang-empty
run_case --interactive-timeout-seconds 0.05
[[ $case_status -eq 4 ]]
grep -Fq 'package was absent, but the OEM may commit it later' <<<"$case_output"
grep -Fq 'Wait and recheck for OEM rollback or a late commit' <<<"$case_output"
! grep -Fq "install -r $product_apk" "$command_log"
! grep -Fq 'uninstall app.droidmatch.test' "$command_log"
[[ -e "$product_state" && ! -e "$test_state" ]]

reset_case
export FAKE_PRODUCT_INSTALL_RESULT=reject
run_case
[[ $case_status -eq 3 ]]
grep -Fq "install -t $test_apk" "$command_log"
grep -Fq "install -r $product_apk" "$command_log"
grep -Fq 'uninstall app.droidmatch.test' "$command_log"
[[ -e "$product_state" && ! -e "$test_state" ]]

reset_case
export FAKE_INSTRUMENTATION_RESULT=hang
run_case --interactive-timeout-seconds 0.05
[[ $case_status -eq 1 ]]
grep -Fq 'layout instrumentation command timed out' <<<"$case_output"
grep -Fq 'uninstall app.droidmatch.test' "$command_log"
[[ -e "$product_state" && ! -e "$test_state" ]]

reset_case
export FAKE_INSTRUMENTATION_RESULT=fail
run_case
[[ $case_status -eq 1 ]]
grep -Fq 'uninstall app.droidmatch.test' "$command_log"
[[ -e "$product_state" && ! -e "$test_state" ]]

reset_case
export FAKE_INSTRUMENTATION_RESULT=wrong-count
run_case
[[ $case_status -eq 1 ]]
grep -Fq 'did not report one passing test' <<<"$case_output"
[[ -e "$product_state" && ! -e "$test_state" ]]

reset_case
export FAKE_INSTRUMENTATION_RESULT=skipped
run_case
[[ $case_status -eq 1 ]]
grep -Fq 'did not report one passing test' <<<"$case_output"
[[ -e "$product_state" && ! -e "$test_state" ]]

reset_case
export FAKE_INSTRUMENTATION_RESULT=statusless
run_case
[[ $case_status -eq 1 ]]
grep -Fq 'did not report one passing test' <<<"$case_output"
[[ -e "$product_state" && ! -e "$test_state" ]]

reset_case
export FAKE_INSTRUMENTATION_RESULT=drop-product
run_case
[[ $case_status -eq 4 ]]
grep -Fq 'product package remains installed' <<<"$case_output"
[[ ! -e "$product_state" && ! -e "$test_state" ]]

reset_case
run_case
[[ $case_status -eq 0 ]]
grep -Fq '704SH layout v2 diagnostic passed' <<<"$case_output"
test_install_line="$(grep -nF "install -t $test_apk" "$command_log" | cut -d: -f1)"
product_install_line="$(grep -nF "install -r $product_apk" "$command_log" | cut -d: -f1)"
[[ "$test_install_line" -lt "$product_install_line" ]]
! grep -Fq 'install -r -t' "$command_log"
grep -Fq \
  'shell am instrument -w -r -e layout_profile slot-a-704sh-layout-v2 -e class app.droidmatch.m1.DroidMatchActivityLayoutInstrumentationTest app.droidmatch.test/androidx.test.runner.AndroidJUnitRunner' \
  "$command_log"
grep -Fq 'uninstall app.droidmatch.test' "$command_log"
[[ -e "$product_state" && ! -e "$test_state" ]]

reset_case
export FAKE_CLEANUP_RESULT=reject
run_case
[[ $case_status -eq 4 ]]
grep -Fq 'cleanup could not be verified' <<<"$case_output"
[[ -e "$product_state" && -e "$test_state" ]]

echo "704SH layout instrumentation runner tests passed."
echo "中文：704SH 布局真机 runner 测试通过。"
