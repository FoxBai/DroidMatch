#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker_source="${repo_root}/tools/check-m1-run-logs.sh"
common_source="${repo_root}/tools/m1-run-log-common.sh"
profile_source="${repo_root}/tools/m1-run-log-profile.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-m1-log-check.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

expect_rejected() {
  local repo="$1" log="$2" label="$3" output status
  set +e
  output="$(cd "${repo}" && bash tools/check-m1-run-logs.sh --log "${log}" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -eq 0 ]]; then
    printf 'M1 log checker accepted %s.\n' "${label}" >&2
    exit 1
  fi
}

expect_directory_rejected() {
  local repo="$1" label="$2" output status
  set +e
  output="$(cd "${repo}" && bash tools/check-m1-run-logs.sh 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -eq 0 ]]; then
    printf 'M1 log checker accepted %s.\n' "${label}" >&2
    exit 1
  fi
}

# The legacy path is intentionally immutable: the manifest itself is pinned by
# a checker constant, and every path/digest pair is then verified byte-for-byte.
legacy_repo="${test_root}/legacy-repo"
mkdir -p "${legacy_repo}/tools" "${legacy_repo}/fixtures" "${legacy_repo}/docs"
cp "${checker_source}" "${legacy_repo}/tools/check-m1-run-logs.sh"
cp "${common_source}" "${legacy_repo}/tools/m1-run-log-common.sh"
cp "${profile_source}" "${legacy_repo}/tools/m1-run-log-profile.sh"
cp -R "${repo_root}/fixtures/m1-runs" "${legacy_repo}/fixtures/"
cp "${repo_root}/docs/m1-status.md" "${legacy_repo}/docs/m1-status.md"
cp "${repo_root}/docs/m1-status-zh.md" "${legacy_repo}/docs/m1-status-zh.md"
(cd "${legacy_repo}" && bash tools/check-m1-run-logs.sh >/dev/null)

legacy_relative="$(sed -n '1s/^[0-9a-f]\{64\}  //p' \
  "${repo_root}/fixtures/m1-runs/legacy-v0.sha256")"
[[ -n "${legacy_relative}" ]]

printf '%s\n' 'byte drift' >>"${legacy_repo}/${legacy_relative}"
expect_directory_rejected "${legacy_repo}" 'legacy fixture byte drift'
cp "${repo_root}/${legacy_relative}" "${legacy_repo}/${legacy_relative}"

printf '%s\n' '# manifest drift' \
  >>"${legacy_repo}/fixtures/m1-runs/legacy-v0.sha256"
expect_directory_rejected "${legacy_repo}" 'legacy manifest drift'
cp "${repo_root}/fixtures/m1-runs/legacy-v0.sha256" \
  "${legacy_repo}/fixtures/m1-runs/legacy-v0.sha256"

cp "${legacy_repo}/${legacy_relative}" \
  "${legacy_repo}/fixtures/m1-runs/000-unlisted-legacy.md"
expect_directory_rejected "${legacy_repo}" 'new unprofiled fixture'
rm "${legacy_repo}/fixtures/m1-runs/000-unlisted-legacy.md"

rm "${legacy_repo}/${legacy_relative}"
ln -s "$(basename "${legacy_relative}")" "${legacy_repo}/${legacy_relative}"
expect_directory_rejected "${legacy_repo}" 'legacy fixture symlink'
rm "${legacy_repo}/${legacy_relative}"
cp "${repo_root}/${legacy_relative}" "${legacy_repo}/${legacy_relative}"

rm "${legacy_repo}/${legacy_relative}"
mkdir "${legacy_repo}/${legacy_relative}"
expect_directory_rejected "${legacy_repo}" 'legacy fixture non-regular node'
rm -rf "${legacy_repo}/${legacy_relative}"
cp "${repo_root}/${legacy_relative}" "${legacy_repo}/${legacy_relative}"
(cd "${legacy_repo}" && bash tools/check-m1-run-logs.sh >/dev/null)

mkdir "${legacy_repo}/fixtures/m1-runs/unvalidated"
cp "${legacy_repo}/${legacy_relative}" \
  "${legacy_repo}/fixtures/m1-runs/unvalidated/fake.md"
expect_directory_rejected "${legacy_repo}" 'nested unvalidated fixture path'
rm -rf "${legacy_repo}/fixtures/m1-runs/unvalidated"

strict_repo="${test_root}/strict-repo"
mkdir -p "${strict_repo}/tools" "${strict_repo}/fixtures/m1-runs"
cp "${checker_source}" "${strict_repo}/tools/check-m1-run-logs.sh"
cp "${common_source}" "${strict_repo}/tools/m1-run-log-common.sh"
cp "${profile_source}" "${strict_repo}/tools/m1-run-log-profile.sh"

cat >"${strict_repo}/fixtures/m1-runs/valid.md" <<'VALID_LOG'
# 2026-07-15 08:00:00Z ADB Device Smoke

evidence profile: m1-device-smoke-v1
device profile result: passed
device profile archive class: device-evidence
device profile source revision: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
device profile source state: clean
device profile build mode: rebuilt
device profile apk sha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
device profile harness configuration: release
device profile device slot: C
device profile android api: 34
device profile checks requested: m1-smoke,list-dir,download,download-resume,upload
device profile checks passed: m1-smoke,list-dir,download,download-resume,upload
device profile checks incomplete: none
device profile failure stage: none
device profile handshake attempts: 1
device profile handshake passed: 1
device profile handshake minimum: 1
device profile list elapsed ms: 40
device profile list maximum ms: 1000
device profile download bytes: 10485760
device profile download measured bytes: 10485760
device profile download elapsed ms: 500
device profile download observed mib per second: 20.00
device profile download minimum bytes: 10485760
device profile download minimum mib per second: 10
device profile upload bytes: 10485760
device profile upload measured bytes: 10485760
device profile upload elapsed ms: 400
device profile upload observed mib per second: 25.00
device profile upload minimum bytes: 10485760
device profile upload minimum mib per second: 10
device profile cleanup: scheduled-on-exit
status: passed
date: 2026-07-15 08:00:00Z
device slot: C
manufacturer/model: test strict-device
android version/api: Android 14 / API 34
build channel: local release Swift harness + debug APK from git aaaaaaa
transport: ADB forward to debug harness Activity endpoint
handshake attempts: 1/1 passed via `m1-smoke` (minimum 1)
dual-stream download: not run
mixed-stream transfer: not run
visible time: device already authorized over USB before script start
first list time: 40 ms for `<dm-path-redacted>` (max 1000 ms)
adb baseline download: not run
100MB download: partial download plus resume passed for `<dm-path-redacted>`; bytes 10485760 >= required 10485760; throughput 20.00 MiB/s over 500 ms (required >= 10 MiB/s)
100MB upload: `upload` command passed to `<dm-path-redacted>`; bytes 10485760 >= required 10485760; throughput 25.00 MiB/s over 400 ms (required >= 10 MiB/s)
resume result: partial stop after at least 1 byte(s), then `download --resume` passed
cancel result: not run
pause result: not run
permission cases: launcher entry resolved to `DroidMatchActivity`; detailed permission-denied cases not run
diagnostics bundle: `m1-smoke` output included below
notes:

- serial redaction tag: `<serial-redacted:deadbeef>`
- upload destination: `<dm-path-redacted>`

## Partial Download Output
VALID_LOG

(cd "${strict_repo}" && \
  bash tools/check-m1-run-logs.sh --log fixtures/m1-runs/valid.md >/dev/null)

make_mutation() {
  local name="$1" expression="$2"
  sed "${expression}" "${strict_repo}/fixtures/m1-runs/valid.md" \
    >"${strict_repo}/fixtures/m1-runs/${name}.md"
}

make_mutation unknown-profile \
  's/evidence profile: m1-device-smoke-v1/evidence profile: unknown/'
expect_rejected "${strict_repo}" fixtures/m1-runs/unknown-profile.md 'unknown profile'

make_mutation missing-status '/^status:/d'
expect_rejected "${strict_repo}" fixtures/m1-runs/missing-status.md 'missing status'

cp "${strict_repo}/fixtures/m1-runs/valid.md" \
  "${strict_repo}/fixtures/m1-runs/duplicate-status.md"
printf '%s\n' 'status: passed' >>"${strict_repo}/fixtures/m1-runs/duplicate-status.md"
expect_rejected "${strict_repo}" fixtures/m1-runs/duplicate-status.md 'duplicate status'

make_mutation result-mismatch \
  's/device profile result: passed/device profile result: failed/'
expect_rejected "${strict_repo}" fixtures/m1-runs/result-mismatch.md 'result mismatch'

make_mutation check-mismatch \
  's/device profile checks passed: .*/device profile checks passed: none/'
expect_rejected "${strict_repo}" fixtures/m1-runs/check-mismatch.md 'check-set mismatch'

make_mutation slot-api-mismatch \
  's/device profile android api: 34/device profile android api: 29/'
expect_rejected "${strict_repo}" fixtures/m1-runs/slot-api-mismatch.md 'slot/API mismatch'

make_mutation short-source \
  's/device profile source revision: .*/device profile source revision: aaaaaaa/'
expect_rejected "${strict_repo}" fixtures/m1-runs/short-source.md 'short source revision'

make_mutation below-threshold \
  's/device profile download observed mib per second: 20.00/device profile download observed mib per second: 9.99/'
expect_rejected "${strict_repo}" fixtures/m1-runs/below-threshold.md 'sub-threshold metric'

make_mutation nonsense-summary \
  's/^100MB download: .*/100MB download: nonsense/'
expect_rejected "${strict_repo}" fixtures/m1-runs/nonsense-summary.md 'nonsense summary'

make_mutation failed-command-summary \
  's/partial download plus resume passed/`download` command failed/'
expect_rejected "${strict_repo}" fixtures/m1-runs/failed-command-summary.md \
  'passing evidence with a failed command summary'

make_mutation summary-metric-mismatch \
  's/throughput 20.00 MiB\/s over 500 ms/throughput 99.00 MiB\/s over 1 ms/'
expect_rejected "${strict_repo}" fixtures/m1-runs/summary-metric-mismatch.md \
  'summary metrics detached from the profile'

make_mutation formula-mismatch \
  's/device profile download measured bytes: 10485760/device profile download measured bytes: 5242880/'
expect_rejected "${strict_repo}" fixtures/m1-runs/formula-mismatch.md \
  'bytes elapsed and observed-rate mismatch'

sed \
  -e 's/,download-resume//g' \
  -e 's/device profile download measured bytes: 10485760/device profile download measured bytes: 5242880/' \
  -e 's/device profile download elapsed ms: 500/device profile download elapsed ms: 250/' \
  -e 's/partial download plus resume passed/`download` command passed/' \
  -e 's/throughput 20.00 MiB\/s over 500 ms/throughput 20.00 MiB\/s over 250 ms/' \
  -e 's/^resume result: .*/resume result: not run/' \
  -e '/^## Partial Download Output$/d' \
  "${strict_repo}/fixtures/m1-runs/valid.md" \
  >"${strict_repo}/fixtures/m1-runs/fresh-download-offset-mismatch.md"
expect_rejected "${strict_repo}" fixtures/m1-runs/fresh-download-offset-mismatch.md \
  'fresh download whose measured bytes differ from its final offset'

sed \
  -e 's/device profile upload measured bytes: 10485760/device profile upload measured bytes: 5242880/' \
  -e 's/device profile upload elapsed ms: 400/device profile upload elapsed ms: 200/' \
  -e 's/throughput 25.00 MiB\/s over 400 ms/throughput 25.00 MiB\/s over 200 ms/' \
  "${strict_repo}/fixtures/m1-runs/valid.md" \
  >"${strict_repo}/fixtures/m1-runs/fresh-upload-offset-mismatch.md"
expect_rejected "${strict_repo}" fixtures/m1-runs/fresh-upload-offset-mismatch.md \
  'fresh upload whose measured bytes differ from its final offset'

sed \
  -e 's/,upload$/,upload,upload-retry,upload-retry-fault/' \
  -e 's/device profile upload measured bytes: 10485760/device profile upload measured bytes: 5242880/' \
  -e 's/device profile upload elapsed ms: 400/device profile upload elapsed ms: 200/' \
  -e 's/throughput 25.00 MiB\/s over 400 ms/throughput 25.00 MiB\/s over 200 ms/' \
  -e '/^- upload destination:/a\
- upload transport-loss retry: enabled via `upload --retry-on-transport-loss`\
- upload transport-loss fault check: local frame proxy required `recovered=true`' \
  "${strict_repo}/fixtures/m1-runs/valid.md" \
  >"${strict_repo}/fixtures/m1-runs/valid-upload-fault.md"
cat >>"${strict_repo}/fixtures/m1-runs/valid-upload-fault.md" <<'UPLOAD_RECOVERY'

## Upload Output

```text
upload passed recovered=true
```
UPLOAD_RECOVERY
(cd "${strict_repo}" && bash tools/check-m1-run-logs.sh \
  --log fixtures/m1-runs/valid-upload-fault.md >/dev/null)

sed 's/^## Upload Output$/## Resume Download Output/' \
  "${strict_repo}/fixtures/m1-runs/valid-upload-fault.md" \
  >"${strict_repo}/fixtures/m1-runs/upload-recovery-borrowed-from-download.md"
expect_rejected "${strict_repo}" \
  fixtures/m1-runs/upload-recovery-borrowed-from-download.md \
  'upload recovery claim backed only by download output'

sed \
  -e 's/^## Upload Output$/## Resume Download Output/' \
  -e '/^upload passed recovered=true$/i\
## Upload Output' \
  "${strict_repo}/fixtures/m1-runs/valid-upload-fault.md" \
  >"${strict_repo}/fixtures/m1-runs/nested-upload-heading.md"
expect_rejected "${strict_repo}" fixtures/m1-runs/nested-upload-heading.md \
  'upload recovery claim backed by a heading nested inside download output'

for fence_case in backtick-info long-backtick tilde-info; do
  case "${fence_case}" in
    backtick-info) outer_fence='```outer' ;;
    long-backtick) outer_fence='````outer' ;;
    tilde-info) outer_fence='~~~outer' ;;
  esac
  awk -v outer_fence="${outer_fence}" '
    $0 == "## Upload Output" { print "## Resume Download Output"; next }
    $0 == "```text" && !wrapped {
      print outer_fence
      print "## Upload Output"
      print "```text"
      wrapped = 1
      next
    }
    { print }
  ' "${strict_repo}/fixtures/m1-runs/valid-upload-fault.md" \
    >"${strict_repo}/fixtures/m1-runs/nested-${fence_case}.md"
  expect_rejected "${strict_repo}" \
    "fixtures/m1-runs/nested-${fence_case}.md" \
    "upload recovery heading nested in a ${fence_case} fence"
done

sed \
  -e 's/,upload$/,upload,upload-resume,upload-retry,upload-retry-fault,upload-ack-loss/' \
  -e '/^- upload destination:/a\
- upload partial bytes: `1`\
- upload transport-loss retry: enabled via `upload --retry-on-transport-loss`\
- upload transport-loss fault check: local frame proxy required `recovered=true`\
- upload ACK-loss retry check: local frame proxy required `recovered=true`' \
  "${strict_repo}/fixtures/m1-runs/valid.md" \
  >"${strict_repo}/fixtures/m1-runs/two-upload-fault-modes.md"
cat >>"${strict_repo}/fixtures/m1-runs/two-upload-fault-modes.md" <<'TWO_FAULTS'

## Resume Upload Output

```text
upload passed recovered=true
```
TWO_FAULTS
expect_rejected "${strict_repo}" fixtures/m1-runs/two-upload-fault-modes.md \
  'one upload execution claiming two mutually exclusive fault modes'

sed \
  -e 's/,download-resume//' \
  -e 's/device profile download bytes: .*/device profile download bytes: not-run/' \
  -e 's/device profile download measured bytes: .*/device profile download measured bytes: not-run/' \
  -e 's/device profile download elapsed ms: .*/device profile download elapsed ms: not-run/' \
  -e 's/device profile download observed mib per second: .*/device profile download observed mib per second: not-run/' \
  -e 's/device profile download minimum bytes: .*/device profile download minimum bytes: 0/' \
  -e 's/device profile download minimum mib per second: .*/device profile download minimum mib per second: 0/' \
  -e 's@^100MB download: .*@100MB download: `download` command passed for `<dm-path-redacted>`; 100MB size not asserted@' \
  -e 's/^resume result: .*/resume result: not run/' \
  -e '/^## Partial Download Output$/d' \
  "${strict_repo}/fixtures/m1-runs/valid.md" \
  >"${strict_repo}/fixtures/m1-runs/plain-download-without-metrics.md"
expect_rejected "${strict_repo}" fixtures/m1-runs/plain-download-without-metrics.md \
  'plain download evidence without transfer metrics'

for claim in retry-fault source-deletion media-revoked upload-ack-loss; do
  case "${claim}" in
    retry-fault)
      replacement='m1-smoke,list-dir,download,download-resume,download-retry,download-retry-fault,upload'
      ;;
    source-deletion) replacement='m1-smoke,list-dir,download-source-deletion,upload' ;;
    media-revoked)
      replacement='m1-smoke,list-dir,list-expected-error,media-permission-revoked,download,download-resume,upload'
      ;;
    upload-ack-loss)
      replacement='m1-smoke,list-dir,download,download-resume,upload,upload-resume,upload-retry,upload-ack-loss'
      ;;
  esac
  sed \
    -e "s/^device profile checks requested: .*/device profile checks requested: ${replacement}/" \
    -e "s/^device profile checks passed: .*/device profile checks passed: ${replacement}/" \
    "${strict_repo}/fixtures/m1-runs/valid.md" \
    >"${strict_repo}/fixtures/m1-runs/unbound-${claim}.md"
  expect_rejected "${strict_repo}" "fixtures/m1-runs/unbound-${claim}.md" \
    "unbound ${claim} check claim"
done

cp "${strict_repo}/fixtures/m1-runs/valid.md" \
  "${strict_repo}/fixtures/m1-runs/unknown-field.md"
printf '%s\n' 'device profile invented field: value' \
  >>"${strict_repo}/fixtures/m1-runs/unknown-field.md"
expect_rejected "${strict_repo}" fixtures/m1-runs/unknown-field.md 'unknown device-profile field'

sed \
  -e 's/device profile archive class: device-evidence/device profile archive class: diagnostic-only/' \
  -e 's/device profile source state: clean/device profile source state: dirty/' \
  -e 's/debug APK from git aaaaaaa/debug APK from git aaaaaaa-dirty/' \
  "${strict_repo}/fixtures/m1-runs/valid.md" \
  >"${strict_repo}/fixtures/m1-runs/dirty-diagnostic.md"
(cd "${strict_repo}" && bash tools/check-m1-run-logs.sh \
  --log fixtures/m1-runs/dirty-diagnostic.md >/dev/null)

make_mutation dirty-device-evidence \
  's/device profile source state: clean/device profile source state: dirty/; s/debug APK from git aaaaaaa/debug APK from git aaaaaaa-dirty/'
expect_rejected "${strict_repo}" fixtures/m1-runs/dirty-device-evidence.md \
  'dirty source classified as device evidence'

sed \
  -e 's/device profile archive class: device-evidence/device profile archive class: diagnostic-only/' \
  -e 's/device profile build mode: rebuilt/device profile build mode: reused/' \
  "${strict_repo}/fixtures/m1-runs/valid.md" \
  >"${strict_repo}/fixtures/m1-runs/reused-diagnostic.md"
(cd "${strict_repo}" && bash tools/check-m1-run-logs.sh \
  --log fixtures/m1-runs/reused-diagnostic.md >/dev/null)

make_mutation reused-device-evidence \
  's/device profile build mode: rebuilt/device profile build mode: reused/'
expect_rejected "${strict_repo}" fixtures/m1-runs/reused-device-evidence.md \
  'reused APK classified as device evidence'

make_mutation clean-diagnostic \
  's/device profile archive class: device-evidence/device profile archive class: diagnostic-only/'
expect_rejected "${strict_repo}" fixtures/m1-runs/clean-diagnostic.md \
  'clean rebuilt run classified as diagnostic-only'

sed \
  -e 's/device profile archive class: device-evidence/device profile archive class: diagnostic-only/' \
  -e 's/device profile source revision: .*/device profile source revision: unknown/' \
  -e 's/device profile source state: clean/device profile source state: unknown/' \
  -e 's/build channel: .*/build channel: local release Swift harness + debug APK from git unknown/' \
  "${strict_repo}/fixtures/m1-runs/valid.md" \
  >"${strict_repo}/fixtures/m1-runs/unknown-provenance-diagnostic.md"
(cd "${strict_repo}" && bash tools/check-m1-run-logs.sh \
  --log fixtures/m1-runs/unknown-provenance-diagnostic.md >/dev/null)

sed '/^evidence profile:/d; /^device profile /d; /^status:/d' \
  "${strict_repo}/fixtures/m1-runs/valid.md" \
  >"${strict_repo}/fixtures/m1-runs/unprofiled-nonsense.md"
expect_rejected "${strict_repo}" fixtures/m1-runs/unprofiled-nonsense.md \
  'unlisted unprofiled log'

cp "${strict_repo}/fixtures/m1-runs/valid.md" \
  "${strict_repo}/fixtures/m1-runs/private.md"
printf '%s\n' 'private: /Users/person/secret-file' \
  >>"${strict_repo}/fixtures/m1-runs/private.md"
set +e
private_output="$(cd "${strict_repo}" && bash tools/check-m1-run-logs.sh \
  --log fixtures/m1-runs/private.md 2>&1)"
private_status=$?
set -e
[[ "${private_status}" -ne 0 && "${private_output}" != *'secret-file'* ]]

cp "${strict_repo}/fixtures/m1-runs/valid.md" \
  "${strict_repo}/fixtures/m1-runs/raw-serial.md"
printf '%s\n' 'command: adb -s R58M123456 shell getprop' \
  >>"${strict_repo}/fixtures/m1-runs/raw-serial.md"
set +e
serial_output="$(cd "${strict_repo}" && bash tools/check-m1-run-logs.sh \
  --log fixtures/m1-runs/raw-serial.md 2>&1)"
serial_status=$?
set -e
[[ "${serial_status}" -ne 0 && "${serial_output}" != *'R58M123456'* ]]

ln -s valid.md "${strict_repo}/fixtures/m1-runs/symlink.md"
expect_rejected "${strict_repo}" fixtures/m1-runs/symlink.md 'profiled symlink'

sed \
  -e 's/device profile result: passed/device profile result: failed/' \
  -e 's/device profile archive class: device-evidence/device profile archive class: failed-diagnostic/' \
  -e 's/device profile checks passed: .*/device profile checks passed: none/' \
  -e 's/device profile checks incomplete: none/device profile checks incomplete: m1-smoke,list-dir,download,download-resume,upload/' \
  -e 's/device profile failure stage: none/device profile failure stage: upload/' \
  -e 's/^status: passed/status: failed/' \
  -e 's/partial download plus resume passed/partial download plus resume transferred/' \
  -e 's/`upload` command passed/`upload` command transferred/' \
  -e 's/ (required >= 10 MiB\/s)$/ (required >= 10 MiB\/s); final status failed after transfer/' \
  -e 's/^resume result: .*/resume result: resume-check requested but did not complete/' \
  "${strict_repo}/fixtures/m1-runs/valid.md" \
  >"${strict_repo}/fixtures/m1-runs/failed-diagnostic.md"
printf '%s\n' 'failure stage: upload' \
  >>"${strict_repo}/fixtures/m1-runs/failed-diagnostic.md"
(cd "${strict_repo}" && bash tools/check-m1-run-logs.sh \
  --log fixtures/m1-runs/failed-diagnostic.md >/dev/null)

sed \
  -e 's/device profile android api: 34/device profile android api: unknown/' \
  -e 's/manufacturer\/model: test strict-device/manufacturer\/model: unknown unknown/' \
  -e 's/android version\/api: Android 14 \/ API 34/android version\/api: Android unknown \/ API unknown/' \
  "${strict_repo}/fixtures/m1-runs/failed-diagnostic.md" \
  >"${strict_repo}/fixtures/m1-runs/failed-unknown-device-metadata.md"
(cd "${strict_repo}" && bash tools/check-m1-run-logs.sh \
  --log fixtures/m1-runs/failed-unknown-device-metadata.md >/dev/null)

sed \
  -e 's/device profile android api: 34/device profile android api: unknown/' \
  -e 's/android version\/api: Android 14 \/ API 34/android version\/api: Android unknown \/ API unknown/' \
  "${strict_repo}/fixtures/m1-runs/valid.md" \
  >"${strict_repo}/fixtures/m1-runs/passed-unknown-device-metadata.md"
expect_rejected "${strict_repo}" fixtures/m1-runs/passed-unknown-device-metadata.md \
  'passing evidence with unknown device metadata'

printf '%s\n' \
  'M1 run-log checker offline tests passed.' \
  '中文：M1 运行日志门禁离线测试通过。'
