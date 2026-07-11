#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$repo_root/tools/run-android-keystore-instrumentation.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-keystore-runner-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

fake_adb="$test_root/adb"
fake_apk="$test_root/test.apk"
command_log="$test_root/commands.log"
touch "$fake_apk"

cat > "$fake_adb" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_ADB_LOG"
case "$*" in
  *" get-state") echo device ;;
  *" shell pm path app.droidmatch") echo package:/data/app/product.apk ;;
  *" install -r -t "*)
    [[ "${FAKE_ADB_INSTALL_RESULT:-pass}" == pass ]] || exit 1
    echo Success
    ;;
  *" shell am instrument "*)
    printf 'INSTRUMENTATION_STATUS_CODE: 0\nOK (2 tests)\n'
    ;;
  *" uninstall app.droidmatch.test") echo Success ;;
esac
EOF
chmod +x "$fake_adb"

set +e
rejected_output="$(
  FAKE_ADB_LOG="$command_log" \
  FAKE_ADB_INSTALL_RESULT=reject \
  ADB_BIN="$fake_adb" \
  DROIDMATCH_TEST_APK="$fake_apk" \
    "$runner" --serial test-device --skip-build 2>&1
)"
rejected_status=$?
set -e
[[ $rejected_status -eq 3 ]]
grep -q 'Check the selected phone now' <<<"$rejected_output"
grep -q '请查看所选手机' <<<"$rejected_output"
grep -q 'install -r -t' "$command_log"
! grep -q 'uninstall app.droidmatch' "$command_log"

: > "$command_log"
FAKE_ADB_LOG="$command_log" \
FAKE_ADB_INSTALL_RESULT=pass \
ADB_BIN="$fake_adb" \
DROIDMATCH_TEST_APK="$fake_apk" \
  "$runner" --serial test-device --skip-build >/dev/null
grep -q 'shell am instrument -w -r app.droidmatch.test/androidx.test.runner.AndroidJUnitRunner' \
  "$command_log"
grep -q 'uninstall app.droidmatch.test' "$command_log"
! grep -q 'uninstall app.droidmatch$' "$command_log"

echo "Android Keystore instrumentation runner tests passed."
echo "中文：Android Keystore 真机 runner 测试通过。"
