#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="${repo_root}/tools/check-android-layout-evidence.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-layout-evidence-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

valid_log="${test_root}/valid.md"
cat >"${valid_log}" <<'EOF'
# M1 Android Launcher Layout Evidence

status: passed
evidence profile: m1-android-launcher-layout-v1
profile result: passed
date: 2026-07-20 12:34:56Z
device slot: A
device model: SHARP 704SH
android api: 26
instrumentation profile: slot-a-704sh-layout-v2
instrumentation class: app.droidmatch.m1.DroidMatchActivityLayoutInstrumentationTest
instrumentation tests expected: 1
instrumentation tests passed: 1
profile source revision: 1111111111111111111111111111111111111111
profile expected main revision: 1111111111111111111111111111111111111111
profile origin main revision: 1111111111111111111111111111111111111111
profile source dirty: false
build mode: debug-clean-rebuild
product apk sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
test apk sha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
product package preexisting: true
test package absent before run: true
test apk install mode: create-only
product apk replacement mode: install-r-preserve-data
product data preservation: no-uninstall-no-clear
test package cleanup verified: true
product package remained installed: true
repository clean before run: true
repository clean after run: true
physical display: 720x1280
app viewport: 720x1136
density dpi: 320
locale: en-US
font scale: 1.3
layout assertion set: initial-action,uniform-action-rows,media-detail-rows,text-fit,full-scroll,final-control
raw instrumentation output included: false
adb serial included: false
EOF

bash "${checker}" --log "${valid_log}" >/dev/null

expect_rejected() {
  local name="$1" pattern="$2" replacement="$3" mutated
  mutated="${test_root}/${name}.md"
  sed "s|${pattern}|${replacement}|" "${valid_log}" >"${mutated}"
  if bash "${checker}" --log "${mutated}" >/dev/null 2>&1; then
    printf 'Android layout checker accepted mutation: %s\n' "${name}" >&2
    exit 1
  fi
}

expect_rejected wrong-status '^status: passed$' 'status: failed'
expect_rejected wrong-profile 'm1-android-launcher-layout-v1' 'm1-android-launcher-layout-v2'
expect_rejected wrong-date '2026-07-20 12:34:56Z' '2026-07-20'
expect_rejected wrong-slot '^device slot: A$' 'device slot: C'
expect_rejected wrong-model 'SHARP 704SH' 'SHARP 705SH'
expect_rejected wrong-api '^android api: 26$' 'android api: 34'
expect_rejected wrong-instrumentation-profile 'slot-a-704sh-layout-v2' 'slot-a-704sh-layout-v1'
expect_rejected wrong-test-count '^instrumentation tests passed: 1$' 'instrumentation tests passed: 2'
expect_rejected source-mismatch '^profile origin main revision: 1111111111111111111111111111111111111111$' 'profile origin main revision: 2222222222222222222222222222222222222222'
expect_rejected dirty-source '^profile source dirty: false$' 'profile source dirty: true'
expect_rejected reused-build '^build mode: debug-clean-rebuild$' 'build mode: debug-reused'
expect_rejected same-apk '^test apk sha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb$' 'test apk sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
expect_rejected product-not-preexisting '^product package preexisting: true$' 'product package preexisting: false'
expect_rejected test-preexisting '^test package absent before run: true$' 'test package absent before run: false'
expect_rejected replacement-mode '^product apk replacement mode: install-r-preserve-data$' 'product apk replacement mode: reinstall'
expect_rejected product-data '^product data preservation: no-uninstall-no-clear$' 'product data preservation: unknown'
expect_rejected cleanup-unknown '^test package cleanup verified: true$' 'test package cleanup verified: false'
expect_rejected product-missing '^product package remained installed: true$' 'product package remained installed: false'
expect_rejected dirty-after '^repository clean after run: true$' 'repository clean after run: false'
expect_rejected wrong-viewport '^app viewport: 720x1136$' 'app viewport: 720x1280'
expect_rejected wrong-density '^density dpi: 320$' 'density dpi: 420'
expect_rejected wrong-locale '^locale: en-US$' 'locale: zh-CN'
expect_rejected wrong-font '^font scale: 1.3$' 'font scale: 1.0'
expect_rejected missing-media-assertion 'initial-action,uniform-action-rows,media-detail-rows,text-fit,full-scroll,final-control' 'initial-action,uniform-action-rows,text-fit,full-scroll,final-control'
expect_rejected raw-output '^raw instrumentation output included: false$' 'raw instrumentation output included: true'
expect_rejected serial-output '^adb serial included: false$' 'adb serial included: true'

duplicate="${test_root}/duplicate.md"
cp "${valid_log}" "${duplicate}"
printf '%s\n' 'status: passed' >>"${duplicate}"
! bash "${checker}" --log "${duplicate}" >/dev/null 2>&1

unknown="${test_root}/unknown.md"
cp "${valid_log}" "${unknown}"
printf '%s\n' 'unexpected detail: value' >>"${unknown}"
! bash "${checker}" --log "${unknown}" >/dev/null 2>&1

private_path="${test_root}/private-path.md"
cp "${valid_log}" "${private_path}"
printf '%s\n' 'unexpected detail: /Users/example/private' >>"${private_path}"
! bash "${checker}" --log "${private_path}" >/dev/null 2>&1

serial_leak="${test_root}/serial-leak.md"
cp "${valid_log}" "${serial_leak}"
printf '%s\n' 'serial=private-device-id' >>"${serial_leak}"
! bash "${checker}" --log "${serial_leak}" >/dev/null 2>&1

missing="${test_root}/missing.md"
sed '/^test apk sha256:/d' "${valid_log}" >"${missing}"
! bash "${checker}" --log "${missing}" >/dev/null 2>&1

symlink_log="${test_root}/symlink.md"
ln -s "${valid_log}" "${symlink_log}"
! bash "${checker}" --log "${symlink_log}" >/dev/null 2>&1

oversized="${test_root}/oversized.md"
cp "${valid_log}" "${oversized}"
dd if=/dev/zero bs=65536 count=2 2>/dev/null | tr '\0' x >>"${oversized}"
! bash "${checker}" --log "${oversized}" >/dev/null 2>&1

fixture_dir="${test_root}/fixtures"
mkdir "${fixture_dir}"
printf '%s\n' '# Android launcher layout evidence' >"${fixture_dir}/README.md"
cp "${valid_log}" "${fixture_dir}/pass.md"
cp "${valid_log}" "${fixture_dir}/pass.md.commit"
bash "${checker}" --directory "${fixture_dir}" >/dev/null

cp "${fixture_dir}/README.md" "${fixture_dir}/README.md.commit"
! bash "${checker}" --directory "${fixture_dir}" >/dev/null 2>&1
rm "${fixture_dir}/README.md.commit"

rm "${fixture_dir}/pass.md.commit"
! bash "${checker}" --directory "${fixture_dir}" >/dev/null 2>&1
rm "${fixture_dir}/pass.md"
cp "${valid_log}" "${fixture_dir}/orphan.md.commit"
! bash "${checker}" --directory "${fixture_dir}" >/dev/null 2>&1
rm "${fixture_dir}/orphan.md.commit"
cp "${valid_log}" "${fixture_dir}/pass.md"
cp "${valid_log}" "${fixture_dir}/pass.md.commit"
printf '%s\n' 'mismatch' >>"${fixture_dir}/pass.md.commit"
! bash "${checker}" --directory "${fixture_dir}" >/dev/null 2>&1
cp "${valid_log}" "${fixture_dir}/pass.md.commit"
printf '%s\n' 'unsupported' >"${fixture_dir}/unexpected.txt"
! bash "${checker}" --directory "${fixture_dir}" >/dev/null 2>&1
rm "${fixture_dir}/unexpected.txt"
ln -s "${fixture_dir}" "${test_root}/fixture-link"
! bash "${checker}" --directory "${test_root}/fixture-link" >/dev/null 2>&1

printf '%s\n' 'Android layout evidence checker tests passed.'
printf '%s\n' '中文：Android 启动器布局证据校验器测试通过。'
