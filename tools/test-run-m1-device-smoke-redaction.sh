#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="${repo_root}/tools/run-m1-device-smoke.sh"

# Performance evidence must not benchmark Swift's default -Onone build. Keep
# this as an exact contract so a future command cleanup cannot silently move
# physical throughput gates back to the debug harness.
grep -Fq \
  'swift run --package-path mac --configuration release droidmatch-harness "$@"' \
  "${runner}"
grep -Fq \
  'build channel: local release Swift harness + debug APK from git %s' \
  "${runner}"

serial_helper_source="$(
  awk '
    /^serial_tag_for\(\)/ { copying = 1 }
    /^select_serial\(\)/ { copying = 0 }
    copying { print }
  ' "${runner}"
)"
eval "${serial_helper_source}"

expected_serial_tag="$(printf '%s' 'TEST-SERIAL' | shasum -a 256 | awk '{print substr($1, 1, 8)}')"
[[ "$(serial_tag_for 'TEST-SERIAL')" == "${expected_serial_tag}" ]]
[[ "$(serial_label_for 'TEST-SERIAL')" == "<serial-redacted:${expected_serial_tag}>" ]]

# The ordinary runner still executes commands with the private serial, but its
# user-facing selection, forward, failure, and success output must not echo it.
grep -Fq 'Ready device tags:' "${runner}"
grep -Fq 'printf '\''Using adb device %s\n'\'' "<serial-redacted:${serial_tag}>"' "${runner}"
grep -Fq 'printf '\''%s\n'\'' "${forward_output}" | redacted_output' "${runner}"
grep -Fq 'printf '\''%s failed:\n%s\n'\'' "${stage}" "${output}" | redacted_output >&2' "${runner}"
grep -Fq '"<serial-redacted:${serial_tag}>" "${allocated_local_port}" "${remote_port}"' "${runner}"
! grep -Fq 'Using adb device serial=%s' "${runner}"

# Explicit app-sandbox cleanup owns both the visible final and the provider's
# hidden atomic partial; otherwise a failed run can contaminate later evidence.
grep -Fq 'partial_relative=".${base_name}.droidmatch-upload-part"' "${runner}"
grep -Fq '"files/droidmatch-sandbox/${partial_relative}"' "${runner}"

# The strict throughput wrapper relies on production markers, not fake-only
# output. Reservation must cover source, final, and hidden partial before seed.
grep -Fq -- '--require-disposable-app-sandbox-paths' "${runner}"
grep -Fq 'disposable app-sandbox paths reserved' "${runner}"
grep -Fq '"files/droidmatch-sandbox/${prepare_app_sandbox_file}"' "${runner}"
grep -Fq '"files/droidmatch-sandbox/.${upload_name}.droidmatch-upload-part"' "${runner}"
grep -Fq 'adb baseline download passed bytes=%s expected_bytes=%s elapsed_ms=%s throughput_mib_per_sec=%s' "${runner}"
grep -Fq 'staged_log="$(mktemp "$(dirname "${result_log}")/.m1-device-smoke.XXXXXX")"' \
  "${runner}"
grep -Fq 'publish_staged_m1_log "${staged_log}" "${result_log}"' "${runner}"
grep -Fq '&& ( -e "${result_log}" || -L "${result_log}" )' "${runner}"
! grep -Fq '} > "${result_log}"' "${runner}"
reservation_call_line="$(grep -n '^reserve_disposable_app_sandbox_paths$' "${runner}" | cut -d: -f1)"
prepare_call_line="$(grep -n '^prepare_app_sandbox_file_on_device$' "${runner}" | cut -d: -f1)"
[[ "${reservation_call_line}" =~ ^[0-9]+$ && "${prepare_call_line}" =~ ^[0-9]+$ ]]
(( reservation_call_line < prepare_call_line ))

# Exercise the production functions without sourcing the device runner, whose
# top-level code intentionally performs an attended physical-device workflow.
function_source="$(
  awk '
    /^redacted_output\(\)/ { copying = 1 }
    /^capture_or_exit\(\)/ { copying = 0 }
    copying { print }
  ' "${runner}"
)"
eval "${function_source}"

permission_case_function_source="$(
  awk '
    /^write_media_permission_revoke_download_permission_case\(\)/ { copying = 1 }
    /^write_result_log\(\)/ { copying = 0 }
    copying { print }
  ' "${runner}"
)"
eval "${permission_case_function_source}"

download_source_path="dm://media-images/media/offline-test"

final_status="failed"
failure_stage="download media permission revoke hook"
media_permission_revoke_download_outcome=""
failed_permission_case="$(write_media_permission_revoke_download_permission_case)"
[[ "${failed_permission_case}" == *'check attempted'* ]]
[[ "${failed_permission_case}" == *'but did not complete'* ]]
[[ "${failed_permission_case}" == *'run failed at stage `download media permission revoke hook`'* ]]
[[ "${failed_permission_case}" == *'recorded outcome `not recorded`'* ]]
[[ "${failed_permission_case}" != *'check passed'* ]]
[[ "${failed_permission_case}" != *'outcome `unknown`'* ]]

final_status="passed"
failure_stage=""
media_permission_revoke_download_outcome="completed_after_revoke"
completed_permission_case="$(write_media_permission_revoke_download_permission_case)"
[[ "${completed_permission_case}" == *'check passed'* ]]
[[ "${completed_permission_case}" == *'outcome `completed_after_revoke`'* ]]
[[ "${completed_permission_case}" == *'prior grants were restored'* ]]

media_permission_revoke_download_outcome="transport_lost_after_revoke"
transport_lost_permission_case="$(write_media_permission_revoke_download_permission_case)"
[[ "${transport_lost_permission_case}" == *'check passed'* ]]
[[ "${transport_lost_permission_case}" == *'outcome `transport_lost_after_revoke`'* ]]
[[ "${transport_lost_permission_case}" == *'prior grants were restored'* ]]

serial="TEST-SERIAL"
serial_tag="test-tag"
download_destination=""
upload_source_file=""

raw_output=$'file PRIVATE-PHOTO-NAME.jpg size=12\ndirectory PRIVATE-ALBUM-NAME\nelapsed_ms=37'
redacted_output_text="$(printf '%s\n' "${raw_output}" | redacted_list_output)"

[[ "${redacted_output_text}" == *'elapsed_ms=37'* ]]
[[ "${redacted_output_text}" == *'entries redacted: 2'* ]]
if [[ "${redacted_output_text}" == *'PRIVATE-PHOTO-NAME.jpg'* || \
      "${redacted_output_text}" == *'PRIVATE-ALBUM-NAME'* ]]; then
  printf '%s\n' 'list-dir entry names crossed the terminal privacy boundary' >&2
  exit 1
fi

# Both list_output display sites (terminal and archived fixture) must use the
# same entry-aggregating privacy filter. The unfiltered value remains available
# separately to list_elapsed_ms_from_output above the terminal display site.
display_site_count="$(
  grep -F 'printf '\''%s\n'\'' "${list_output}"' "${runner}" \
    | grep -Fc '| redacted_list_output'
)"
[[ "${display_site_count}" -eq 2 ]]
while IFS= read -r display_site; do
  [[ "${display_site}" == *'| redacted_list_output'* ]]
done < <(
  grep -F 'printf '\''%s\n'\'' "${list_output}"' "${runner}" \
    | grep -F '| redacted_list_output'
)

grep -Fq 'list_time_ms="$(printf '\''%s\n'\'' "${list_output}" | list_elapsed_ms_from_output)"' \
  "${runner}"

dirty_function_source="$(
  awk '
    /^git_worktree_has_non_evidence_changes\(\)/ { copying = 1 }
    /^throughput_mib_per_second\(\)/ { copying = 0 }
    copying { print }
  ' "${runner}"
)"
eval "${dirty_function_source}"

publication_function_source="$(
  awk '
    /^publish_staged_m1_log\(\)/ { copying = 1 }
    /^write_result_log\(\)/ { copying = 0 }
    copying { print }
  ' "${runner}"
)"
eval "${publication_function_source}"

publication_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-log-publish.XXXXXX")"
valid_fixture="${repo_root}/fixtures/m1-runs/2026-07-11T11-43-42Z-keystore-instrumentation-afcb4a28.md"
staged_fixture="${publication_root}/.staged.md"
published_fixture="${publication_root}/result.md"
cp "${valid_fixture}" "${staged_fixture}"
publish_staged_m1_log "${staged_fixture}" "${published_fixture}"
[[ -f "${published_fixture}" && ! -e "${staged_fixture}" ]]

printf '%s\n' 'existing-sentinel' >"${publication_root}/existing.md"
cp "${valid_fixture}" "${publication_root}/.existing-staged.md"
if publish_staged_m1_log \
    "${publication_root}/.existing-staged.md" "${publication_root}/existing.md"; then
  printf '%s\n' 'generic log publisher replaced an existing target' >&2
  exit 1
fi
grep -Fqx 'existing-sentinel' "${publication_root}/existing.md"

mkdir "${publication_root}/symlink-directory"
ln -s "${publication_root}/symlink-directory" "${publication_root}/symlink.md"
cp "${valid_fixture}" "${publication_root}/.symlink-staged.md"
if publish_staged_m1_log \
    "${publication_root}/.symlink-staged.md" "${publication_root}/symlink.md"; then
  printf '%s\n' 'generic log publisher followed a target symlink' >&2
  exit 1
fi
if find "${publication_root}/symlink-directory" -mindepth 1 -print -quit | grep -q .; then
  printf '%s\n' 'generic log publisher wrote through a target symlink' >&2
  exit 1
fi
rm -rf "${publication_root}"

git_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-smoke-git-state.XXXXXX")"
trap 'rm -rf "${git_root}"' EXIT
(
  cd "${git_root}"
  git init -q
  git config user.name 'DroidMatch Offline Test'
  git config user.email 'offline-test@droidmatch.invalid'
  mkdir -p fixtures/m1-runs
  printf '%s\n' baseline > tracked.txt
  printf '%s\n' evidence > fixtures/m1-runs/2026-07-13T00-00-00Z-adb-1234abcd.md
  git add tracked.txt fixtures/m1-runs/2026-07-13T00-00-00Z-adb-1234abcd.md
  git commit -qm baseline
  expected_commit="$(command git rev-parse --short HEAD)"

  ! git_worktree_has_non_evidence_changes
  [[ "$(git_commit_for_evidence)" == "${expected_commit}" ]]

  printf '%s\n' generated > fixtures/m1-runs/2026-07-13T00-00-01Z-adb-deadbeef.md
  ! git_worktree_has_non_evidence_changes
  [[ "$(git_commit_for_evidence)" == "${expected_commit}" ]]

  printf '%s\n' unexpected > ordinary-untracked.txt
  git_worktree_has_non_evidence_changes
  [[ "$(git_commit_for_evidence)" == "${expected_commit}-dirty" ]]
  rm ordinary-untracked.txt

  printf '%s\n' unexpected > fixtures/m1-runs/2026-07-13T00-00-02Z-adb-DEADBEEF.md
  git_worktree_has_non_evidence_changes
  [[ "$(git_commit_for_evidence)" == "${expected_commit}-dirty" ]]
  rm fixtures/m1-runs/2026-07-13T00-00-02Z-adb-DEADBEEF.md

  printf '%s\n' changed >> tracked.txt
  git_worktree_has_non_evidence_changes
  [[ "$(git_commit_for_evidence)" == "${expected_commit}-dirty" ]]
  git restore tracked.txt

  printf '%s\n' changed >> fixtures/m1-runs/2026-07-13T00-00-00Z-adb-1234abcd.md
  git_worktree_has_non_evidence_changes
  [[ "$(git_commit_for_evidence)" == "${expected_commit}-dirty" ]]

  git() {
    [[ "${1:-}" != "status" ]] || return 70
    command git "$@"
  }
  [[ "$(git_commit_for_evidence)" == "unknown" ]]
  unset -f git
)

printf '%s\n' 'M1 device smoke privacy and git-state tests passed.'
