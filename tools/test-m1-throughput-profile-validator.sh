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

expect_accepted() {
  local path="$1" label="$2"
  if ! (cd "${test_repo}" && bash tools/check-m1-run-logs.sh \
      --log "${path}" >/dev/null 2>&1); then
    printf 'profile validator rejected %s.\n' "${label}" >&2
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

# Throughput v2 remains pass-only. Failed runs use a separate profile so a
# diagnostic can never weaken or be mistaken for the evidence gate.
mutation="$(mutated_path failed-v2)"
sed 's/^profile result: passed$/profile result: failed/' \
  "${valid_log}" >"${mutation}"
expect_rejected fixtures/m1-runs/failed-v2.md 'a failed result under the pass-only v2 profile'
rm "${mutation}"

mutation="$(mutated_path v2-with-diagnostic-field)"
cp "${valid_log}" "${mutation}"
printf '%s\n' 'diagnostic result: failed' >>"${mutation}"
expect_rejected fixtures/m1-runs/v2-with-diagnostic-field.md \
  'a fail-only diagnostic field injected into passing v2 evidence'
rm "${mutation}"

diagnostic_log="$(mutated_path valid-diagnostic)"
diagnostic_source_revision="$(sed -n 's/^profile source revision: //p' "${valid_log}")"
[[ "${diagnostic_source_revision}" =~ ^[0-9a-f]{40}$ ]]
sed '/^evidence profile: m1-adb-throughput-v2$/,$d' \
  "${valid_log}" >"${diagnostic_log}"
cat >>"${diagnostic_log}" <<EOF_DIAGNOSTIC
evidence profile: m1-adb-throughput-diagnostic-v1
diagnostic result: failed
diagnostic archive class: failed-diagnostic
diagnostic failure stage: pass-log
diagnostic source revision: ${diagnostic_source_revision}
diagnostic expected main revision: ${diagnostic_source_revision}
diagnostic origin main revision before run: ${diagnostic_source_revision}
diagnostic post-run provenance: matched
diagnostic producer exit status: 0
diagnostic producer result: passed
diagnostic managed payload sha256: 20492a4d0d84f8beb1767f6616229f85d44c2827b64bdbfb260ee12fa1109e0e
diagnostic download payload sha256: 20492a4d0d84f8beb1767f6616229f85d44c2827b64bdbfb260ee12fa1109e0e
diagnostic upload payload sha256: 20492a4d0d84f8beb1767f6616229f85d44c2827b64bdbfb260ee12fa1109e0e
diagnostic cleanup remote artifacts: absent
diagnostic cleanup local artifacts: absent
diagnostic cleanup adb forward: absent
diagnostic cleanup result: complete
EOF_DIAGNOSTIC
expect_accepted fixtures/m1-runs/valid-diagnostic.md \
  'a failed pass-log diagnostic with a validated passing producer'

expect_diagnostic_mutation_rejected() {
  local name="$1" label="$2" path
  shift 2
  path="$(mutated_path "${name}")"
  sed "$@" "${diagnostic_log}" >"${path}"
  expect_rejected "fixtures/m1-runs/${name}.md" "${label}"
  rm "${path}"
}

expect_diagnostic_mutation_rejected result-not-failed \
  'a diagnostic whose result is not failed' \
  -e 's/^diagnostic result: failed$/diagnostic result: passed/'
expect_diagnostic_mutation_rejected archive-not-failed \
  'a diagnostic not classified as failed-diagnostic' \
  -e 's/^diagnostic archive class: failed-diagnostic$/diagnostic archive class: device-evidence/'
expect_diagnostic_mutation_rejected missing-diagnostic-field \
  'a diagnostic missing a required field' \
  -e '/^diagnostic post-run provenance:/d'
expect_diagnostic_mutation_rejected missing-producer \
  'a diagnostic without its producer profile identity' \
  -e '/^evidence producer profile:/d'
expect_diagnostic_mutation_rejected source-detached \
  'a diagnostic source detached from its producer' \
  -e 's/^diagnostic source revision: .*/diagnostic source revision: 0000000000000000000000000000000000000000/'
expect_diagnostic_mutation_rejected invalid-producer-exit \
  'a producer exit status outside 0 through 255' \
  -e 's/^diagnostic producer exit status: 0$/diagnostic producer exit status: 256/'
expect_diagnostic_mutation_rejected passed-producer-nonzero-exit \
  'a passing producer with nonzero exit status' \
  -e 's/^diagnostic producer exit status: 0$/diagnostic producer exit status: 1/'
expect_diagnostic_mutation_rejected producer-result-detached \
  'a diagnostic producer result detached from the embedded producer' \
  -e 's/^diagnostic producer result: passed$/diagnostic producer result: failed/'
expect_diagnostic_mutation_rejected producer-minimum-drift \
  'a diagnostic whose producer does not retain the fixed throughput minimum' \
  -e 's/^device profile upload minimum mib per second: 20$/device profile upload minimum mib per second: 19/'
expect_diagnostic_mutation_rejected pass-log-digest-mismatch \
  'a pass-log failure without three matching payload digests' \
  -e 's/^diagnostic upload payload sha256: ./diagnostic upload payload sha256: f/'
expect_diagnostic_mutation_rejected complete-cleanup-with-present-artifact \
  'complete cleanup while a remote artifact is present' \
  -e 's/^diagnostic cleanup remote artifacts: absent$/diagnostic cleanup remote artifacts: present/'
expect_diagnostic_mutation_rejected incomplete-cleanup-with-all-absent \
  'incomplete cleanup while every artifact is absent' \
  -e 's/^diagnostic cleanup result: complete$/diagnostic cleanup result: incomplete/'

mutation="$(mutated_path duplicate-diagnostic-field)"
cp "${diagnostic_log}" "${mutation}"
printf '%s\n' 'diagnostic result: failed' >>"${mutation}"
expect_rejected fixtures/m1-runs/duplicate-diagnostic-field.md 'a duplicate diagnostic field'
rm "${mutation}"

mutation="$(mutated_path unknown-diagnostic-field)"
cp "${diagnostic_log}" "${mutation}"
printf '%s\n' 'diagnostic invented field: value' >>"${mutation}"
expect_rejected fixtures/m1-runs/unknown-diagnostic-field.md 'an unknown diagnostic field'
rm "${mutation}"

mutation="$(mutated_path generic-profile-field-in-diagnostic)"
cp "${diagnostic_log}" "${mutation}"
printf '%s\n' 'profile result: passed' >>"${mutation}"
expect_rejected fixtures/m1-runs/generic-profile-field-in-diagnostic.md \
  'a pass-profile field injected into a diagnostic'
rm "${mutation}"

# Content-integrity stages may retain the mismatching digest, while the upload
# stage also proves that the already-verified download matched the managed data.
download_content_log="$(mutated_path valid-download-content-diagnostic)"
sed \
  -e 's/^diagnostic failure stage: pass-log$/diagnostic failure stage: download-content-integrity/' \
  -e 's/^diagnostic download payload sha256: ./diagnostic download payload sha256: c/' \
  -e 's/^diagnostic upload payload sha256: .*/diagnostic upload payload sha256: not-recorded/' \
  "${diagnostic_log}" >"${download_content_log}"
expect_accepted fixtures/m1-runs/valid-download-content-diagnostic.md \
  'a download-content diagnostic retaining the mismatching digest'

expect_diagnostic_mutation_rejected download-content-with-matching-hash \
  'a download-content stage whose digest matches the managed payload' \
  -e 's/^diagnostic failure stage: pass-log$/diagnostic failure stage: download-content-integrity/'
expect_diagnostic_mutation_rejected upload-content-with-matching-hash \
  'an upload-content stage whose digest matches the managed payload' \
  -e 's/^diagnostic failure stage: pass-log$/diagnostic failure stage: upload-content-integrity/'

# A cleanup gate may fail and then be recovered by the EXIT finalizer. Its stage
# remains cleanup, but the final aggregate is complete because all absences were
# subsequently verified.
cleanup_recovered_log="$(mutated_path valid-cleanup-recovered-diagnostic)"
sed 's/^diagnostic failure stage: pass-log$/diagnostic failure stage: cleanup/' \
  "${diagnostic_log}" >"${cleanup_recovered_log}"
expect_accepted fixtures/m1-runs/valid-cleanup-recovered-diagnostic.md \
  'a cleanup failure recovered and verified by the finalizer'

failed_producer_log="$(mutated_path valid-producer-exit-diagnostic)"
sed \
  -e 's/^device profile result: passed$/device profile result: failed/' \
  -e 's/^device profile archive class: device-evidence$/device profile archive class: failed-diagnostic/' \
  -e 's/^device profile checks passed: .*/device profile checks passed: none/' \
  -e 's/^device profile checks incomplete: none$/device profile checks incomplete: m1-smoke,adb-baseline,list-dir,download,upload/' \
  -e 's/^device profile failure stage: none$/device profile failure stage: upload/' \
  -e 's/^status: passed$/status: failed/' \
  -e 's/^diagnostic failure stage: pass-log$/diagnostic failure stage: producer-exit/' \
  -e 's/^diagnostic post-run provenance: matched$/diagnostic post-run provenance: unavailable/' \
  -e 's/^diagnostic producer exit status: 0$/diagnostic producer exit status: 1/' \
  -e 's/^diagnostic producer result: passed$/diagnostic producer result: failed/' \
  -e 's/^diagnostic download payload sha256: .*/diagnostic download payload sha256: not-recorded/' \
  -e 's/^diagnostic upload payload sha256: .*/diagnostic upload payload sha256: not-recorded/' \
  "${diagnostic_log}" >"${failed_producer_log}"
printf '%s\n' 'failure stage: upload' >>"${failed_producer_log}"
expect_accepted fixtures/m1-runs/valid-producer-exit-diagnostic.md \
  'a producer-exit diagnostic with a validated failed producer'

mutation="$(mutated_path failed-producer-wrong-stage)"
sed 's/^diagnostic failure stage: producer-exit$/diagnostic failure stage: wrapper-contract/' \
  "${failed_producer_log}" >"${mutation}"
expect_rejected fixtures/m1-runs/failed-producer-wrong-stage.md \
  'a failed producer assigned to a non-producer failure stage'
rm "${mutation}"

mutation="$(mutated_path failed-producer-recorded-hash)"
sed 's/^diagnostic download payload sha256: not-recorded$/diagnostic download payload sha256: 20492a4d0d84f8beb1767f6616229f85d44c2827b64bdbfb260ee12fa1109e0e/' \
  "${failed_producer_log}" >"${mutation}"
expect_rejected fixtures/m1-runs/failed-producer-recorded-hash.md \
  'a producer-exit diagnostic claiming a recorded transfer digest'
rm "${mutation}"

rm \
  "${diagnostic_log}" \
  "${download_content_log}" \
  "${cleanup_recovered_log}" \
  "${failed_producer_log}"
