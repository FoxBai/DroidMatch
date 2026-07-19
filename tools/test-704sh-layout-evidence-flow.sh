#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-704sh-evidence-flow.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

origin="${test_root}/origin.git"
work="${test_root}/work"
stale="${test_root}/stale"
bin="${test_root}/bin"
state="${test_root}/state"
real_python3="$(command -v python3)"
mkdir -p "${bin}" "${state}"
git init --bare --quiet "${origin}"
git --git-dir="${origin}" symbolic-ref HEAD refs/heads/main
git init --quiet -b main "${work}"
git -C "${work}" config user.name 'DroidMatch Evidence Test'
git -C "${work}" config user.email 'evidence-test@invalid.example'

mkdir -p \
  "${work}/tools" \
  "${work}/android" \
  "${work}/fixtures/android-layout" \
  "${work}/docs"
for file in \
  run-704sh-layout-instrumentation.sh \
  check-android-layout-evidence.sh \
  git-main-read.sh \
  product-usb-evidence-publication.sh \
  publish-product-usb-evidence.py \
  run-command-with-timeout.py; do
  cp "${repo_root}/tools/${file}" "${work}/tools/${file}"
done
cp "${repo_root}/fixtures/android-layout/README.md" \
  "${work}/fixtures/android-layout/README.md"
printf '%s\n' '- 0 Android launcher layout evidence logs' \
  >"${work}/docs/m1-status.md"
printf '%s\n' '- 0 个 Android 启动器布局证据日志' \
  >"${work}/docs/m1-status-zh.md"
printf '%s\n' '/android/app/build/' >"${work}/.gitignore"

cat >"${work}/android/gradlew" <<'FAKE_GRADLE'
#!/usr/bin/env bash
set -euo pipefail
[[ " $* " == *' clean '* \
    && " $* " == *' :app:assembleDebug '* \
    && " $* " == *' :app:assembleDebugAndroidTest '* ]] || exit 92
printf '%s\n' "$*" >"${FAKE_GRADLE_LOG:?}"
rm -rf app/build
mkdir -p app/build/outputs/apk/debug app/build/outputs/apk/androidTest/debug
printf '%s\n' 'fresh-product-apk' >app/build/outputs/apk/debug/app-debug.apk
printf '%s\n' 'fresh-layout-test-apk' \
  >app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
FAKE_GRADLE
chmod +x "${work}/android/gradlew" "${work}/tools/"*.sh \
  "${work}/tools/"*.py

cat >"${bin}/adb" <<'FAKE_ADB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_ADB_LOG:?}"
case "$*" in
  *' get-state') printf '%s\n' 'device' ;;
  *' shell pm path app.droidmatch.test')
    [[ -e "${FAKE_TEST_STATE:?}" ]] || exit 1
    printf '%s\n' 'package:/data/app/test.apk'
    ;;
  *' shell pm path app.droidmatch')
    [[ -e "${FAKE_PRODUCT_STATE:?}" ]] || exit 1
    printf '%s\n' 'package:/data/app/product.apk'
    ;;
  *' install -t '*)
    : >"${FAKE_TEST_STATE:?}"
    printf '%s\n' 'Success'
    ;;
  *' install -r '*) printf '%s\n' 'Success' ;;
  *' shell am instrument '*)
    if [[ "${FAKE_MUTATE_PRODUCT_APK:-0}" == 1 ]]; then
      printf '%s\n' 'changed-after-build' >>"${FAKE_PRODUCT_APK:?}"
    fi
    printf '%s\n' 'INSTRUMENTATION_STATUS_CODE: 0' 'OK (1 test)'
    ;;
  *' uninstall app.droidmatch.test')
    rm -f "${FAKE_TEST_STATE:?}"
    printf '%s\n' 'Success'
    ;;
  *' uninstall app.droidmatch'|*' shell pm clear app.droidmatch') exit 90 ;;
  *) exit 91 ;;
esac
FAKE_ADB

cat >"${bin}/python3" <<'FAKE_PYTHON'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_PUBLICATION_UNCERTAIN:-0}" == 1 \
    && $# -eq 5 && "$1" == */publish-product-usb-evidence.py ]]; then
  exit 3
fi
exec "${REAL_PYTHON3:?}" "$@"
FAKE_PYTHON
chmod +x "${bin}/adb" "${bin}/python3"

git -C "${work}" add .
git -C "${work}" commit --quiet -m 'fixture source'
git -C "${work}" remote add origin "${origin}"
git -C "${work}" push --quiet -u origin main
source_sha="$(git -C "${work}" rev-parse HEAD)"

product_state="${state}/product-present"
test_state="${state}/test-present"
command_log="${state}/adb.log"
gradle_log="${state}/gradle.log"
: >"${product_state}"

run_formal() {
  local repository="$1" expected_sha="$2" result_name="$3"
  shift 3
  (
    cd "${repository}"
    env \
      PATH="${bin}:/usr/bin:/bin:/usr/sbin:/sbin" \
      REAL_PYTHON3="${real_python3}" \
      FAKE_ADB_LOG="${command_log}" \
      FAKE_GRADLE_LOG="${gradle_log}" \
      FAKE_PRODUCT_STATE="${product_state}" \
      FAKE_TEST_STATE="${test_state}" \
      FAKE_PRODUCT_APK="${repository}/android/app/build/outputs/apk/debug/app-debug.apk" \
      "$@" \
      tools/run-704sh-layout-instrumentation.sh \
        --serial test-device \
        --expected-main-sha "${expected_sha}" \
        --result-log "fixtures/android-layout/${result_name}"
  )
}

: >"${command_log}"
success_output="$(run_formal "${work}" "${source_sha}" pass.md)"
grep -Fq 'Android layout evidence written: fixtures/android-layout/pass.md' \
  <<<"${success_output}"
! grep -Fq 'test-device' <<<"${success_output}"
cmp -s \
  "${work}/fixtures/android-layout/pass.md" \
  "${work}/fixtures/android-layout/pass.md.commit"
bash "${work}/tools/check-android-layout-evidence.sh" \
  --log "${work}/fixtures/android-layout/pass.md" >/dev/null
grep -Fqx 'repository clean after run: true' \
  "${work}/fixtures/android-layout/pass.md"
grep -Fqx 'test package cleanup verified: true' \
  "${work}/fixtures/android-layout/pass.md"
for field in \
  'profile source revision' \
  'profile expected main revision' \
  'profile origin main revision'; do
  grep -Fqx "${field}: ${source_sha}" \
    "${work}/fixtures/android-layout/pass.md"
done
product_apk="${work}/android/app/build/outputs/apk/debug/app-debug.apk"
test_apk="${work}/android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
product_apk_sha256="$(shasum -a 256 "${product_apk}" | awk '{print $1}')"
test_apk_sha256="$(shasum -a 256 "${test_apk}" | awk '{print $1}')"
grep -Fqx "product apk sha256: ${product_apk_sha256}" \
  "${work}/fixtures/android-layout/pass.md"
grep -Fqx "test apk sha256: ${test_apk_sha256}" \
  "${work}/fixtures/android-layout/pass.md"
grep -Fqx -- \
  '--no-daemon clean :app:assembleDebug :app:assembleDebugAndroidTest' \
  "${gradle_log}"
[[ -e "${product_state}" && ! -e "${test_state}" ]]
! grep -Eq 'uninstall app\.droidmatch$|shell pm clear app\.droidmatch' \
  "${command_log}"
rm "${work}/fixtures/android-layout/pass.md" \
  "${work}/fixtures/android-layout/pass.md.commit"

: >"${command_log}"
set +e
uncertain_output="$(
  run_formal "${work}" "${source_sha}" uncertain.md \
    FAKE_PUBLICATION_UNCERTAIN=1 2>&1
)"
uncertain_status=$?
set -e
[[ "${uncertain_status}" -eq 3 ]]
grep -Fq 'publication is uncertain' <<<"${uncertain_output}"
[[ ! -e "${work}/fixtures/android-layout/uncertain.md" \
    && -f "${work}/fixtures/android-layout/uncertain.md.commit" ]]
[[ ! -e "${test_state}" && -e "${product_state}" ]]
rm "${work}/fixtures/android-layout/uncertain.md.commit"

: >"${command_log}"
set +e
mutated_output="$(
  run_formal "${work}" "${source_sha}" mutated.md \
    FAKE_MUTATE_PRODUCT_APK=1 2>&1
)"
mutated_status=$?
set -e
[[ "${mutated_status}" -eq 1 ]]
grep -Fq 'APK provenance changed' <<<"${mutated_output}"
[[ ! -e "${work}/fixtures/android-layout/mutated.md" \
    && ! -e "${work}/fixtures/android-layout/mutated.md.commit" ]]
[[ ! -e "${test_state}" && -e "${product_state}" ]]

printf '%s\n' 'dirty' >"${work}/untracked-dirty"
: >"${command_log}"
set +e
dirty_output="$(run_formal "${work}" "${source_sha}" dirty.md 2>&1)"
dirty_status=$?
set -e
[[ "${dirty_status}" -eq 1 ]]
grep -Fq 'clean HEAD, expected SHA, and fresh origin/main' <<<"${dirty_output}"
[[ ! -s "${command_log}" ]]
rm "${work}/untracked-dirty"

git clone --quiet "${origin}" "${stale}"
git -C "${work}" commit --quiet --allow-empty -m 'advance origin'
git -C "${work}" push --quiet origin main
: >"${command_log}"
set +e
stale_output="$(run_formal "${stale}" "${source_sha}" stale.md 2>&1)"
stale_status=$?
set -e
[[ "${stale_status}" -eq 1 ]]
grep -Fq 'clean HEAD, expected SHA, and fresh origin/main' <<<"${stale_output}"
[[ ! -s "${command_log}" ]]

printf '%s\n' '704SH formal layout evidence flow tests passed.'
printf '%s\n' '中文：704SH 正式布局证据端到端离线测试通过。'
