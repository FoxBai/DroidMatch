#!/usr/bin/env bash

set -euo pipefail

[[ $# -eq 4 ]] || {
  printf '%s\n' 'usage: test-m1-throughput-profile-validator.sh <repo> <valid-log> <fake-bin> <real-grep>' >&2
  exit 2
}
test_repo="$1"
valid_log="$2"
fake_bin="$3"
real_grep="$4"

expect_rejected() {
  local path="$1" label="$2"
  if (cd "${test_repo}" && bash tools/check-m1-run-logs.sh \
      --log "${path}" >/dev/null 2>&1); then
    printf 'profile validator accepted %s.\n' "${label}" >&2
    exit 1
  fi
}

mutated_path() {
  printf '%s/fixtures/m1-runs/%s.md\n' "${test_repo}" "$1"
}

legacy_v1_log="$(mutated_path legacy-v1)"
sed \
  -e 's/evidence profile: m1-adb-throughput-v2/evidence profile: m1-adb-throughput-v1/' \
  -e '/^profile managed payload sha256:/d' \
  -e '/^profile download payload sha256:/d' \
  -e '/^profile upload payload sha256:/d' \
  "${valid_log}" >"${legacy_v1_log}"
expect_rejected fixtures/m1-runs/legacy-v1.md 'a newly introduced throughput v1 log'
rm "${legacy_v1_log}"

privacy_log="$(mutated_path privacy-invalid)"
cp "${valid_log}" "${privacy_log}"
printf '%s\n' 'PASSWORD=UPPERCASE-PRIVATE-VALUE' >>"${privacy_log}"
set +e
privacy_output="$(cd "${test_repo}" && bash tools/check-m1-run-logs.sh \
  --log fixtures/m1-runs/privacy-invalid.md 2>&1)"
privacy_status=$?
set -e
[[ "${privacy_status}" -ne 0 && "${privacy_output}" != *'UPPERCASE-PRIVATE-VALUE'* ]]
rm "${privacy_log}"

control_log="$(mutated_path control-invalid)"
cp "${valid_log}" "${control_log}"
printf 'control probe:\tinvalid\n' >>"${control_log}"
expect_rejected fixtures/m1-runs/control-invalid.md 'a control character'
rm "${control_log}"

set +e
grep_failure_output="$(
  cd "${test_repo}"
  PATH="${fake_bin}:${PATH}" REAL_GREP="${real_grep}" FAKE_GREP_CONTROL_FAILURE=1 \
    bash tools/check-m1-run-logs.sh --log "${valid_log}" 2>&1
)"
grep_failure_status=$?
set -e
[[ "${grep_failure_status}" -ne 0 ]]
grep -Fq 'could not be privacy-scanned' <<<"${grep_failure_output}"

set +e
grep_count_failure_output="$(
  cd "${test_repo}"
  PATH="${fake_bin}:${PATH}" REAL_GREP="${real_grep}" FAKE_GREP_COUNT_FAILURE=1 \
    bash tools/check-m1-run-logs.sh --log "${valid_log}" 2>&1
)"
grep_count_failure_status=$?
set -e
[[ "${grep_count_failure_status}" -ne 0 ]]
grep -Fq 'could not be scanned' <<<"${grep_count_failure_output}"

mutation="$(mutated_path invalid-rate)"
sed 's/profile upload observed mib per second: 25.00/profile upload observed mib per second: 19.99/' \
  "${valid_log}" >"${mutation}"
expect_rejected fixtures/m1-runs/invalid-rate.md 'sub-threshold upload evidence'
rm "${mutation}"

mutation="$(mutated_path content-mismatch)"
sed 's/profile upload payload sha256: ./profile upload payload sha256: f/' \
  "${valid_log}" >"${mutation}"
expect_rejected fixtures/m1-runs/content-mismatch.md 'mismatched upload content'
rm "${mutation}"

mutation="$(mutated_path substituted-payload)"
sed 's/20492a4d0d84f8beb1767f6616229f85d44c2827b64bdbfb260ee12fa1109e0e/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/g' \
  "${valid_log}" >"${mutation}"
expect_rejected fixtures/m1-runs/substituted-payload.md 'a substituted managed payload'
rm "${mutation}"

mutation="$(mutated_path overflow-elapsed)"
sed 's/profile upload elapsed ms: 4000/profile upload elapsed ms: 9223372036854775808/' \
  "${valid_log}" >"${mutation}"
expect_rejected fixtures/m1-runs/overflow-elapsed.md 'an overflowing elapsed value'
rm "${mutation}"

mutation="$(mutated_path inconsistent-formula)"
sed \
  -e 's/^profile download elapsed ms: 4000/profile download elapsed ms: 3000/' \
  -e '/^100MB download:/ s/over 4000 ms/over 3000 ms/' \
  "${valid_log}" >"${mutation}"
expect_rejected fixtures/m1-runs/inconsistent-formula.md 'metrics inconsistent with bytes and elapsed time'
rm "${mutation}"

source_revision="$(sed -n 's/^device profile source revision: //p' "${valid_log}")"
replacement_revision="${source_revision:0:7}fffffffffffffffffffffffffffffffff"
[[ "${replacement_revision}" != "${source_revision}" ]] \
  || replacement_revision="${source_revision:0:7}000000000000000000000000000000000"
mutation="$(mutated_path producer-source-drift)"
sed "s/^device profile source revision: .*/device profile source revision: ${replacement_revision}/" \
  "${valid_log}" >"${mutation}"
expect_rejected fixtures/m1-runs/producer-source-drift.md 'a producer source revision detached from v2'
rm "${mutation}"

for direction in download upload; do
  mutation="$(mutated_path contradictory-${direction}-summary)"
  sed "/^100MB ${direction}:/ s/throughput 25.00 MiB\/s over 4000 ms/throughput 0.01 MiB\/s over 999999 ms/" \
    "${valid_log}" >"${mutation}"
  expect_rejected "fixtures/m1-runs/contradictory-${direction}-summary.md" \
    "contradictory ${direction} summary metrics"
  rm "${mutation}"
done

mutation="$(mutated_path contradictory-list-summary)"
sed 's@^first list time: 42 ms@first list time: 43 ms@' \
  "${valid_log}" >"${mutation}"
expect_rejected fixtures/m1-runs/contradictory-list-summary.md 'a contradictory warm-list summary'
rm "${mutation}"

mutation="$(mutated_path unknown-profile-field)"
cp "${valid_log}" "${mutation}"
printf '%s\n' 'profile unexpected field: value' >>"${mutation}"
expect_rejected fixtures/m1-runs/unknown-profile-field.md 'an unknown profile field'
rm "${mutation}"
