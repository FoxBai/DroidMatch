#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-dmg-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT
current_process_identity="$(/usr/bin/python3 \
  "${repo_root}/tools/process_instance_identity.py" capture "$$")"

mock_bin="${test_root}/bin"
state_dir="${test_root}/state"
app_path="${test_root}/DroidMatch.app"
mkdir -p "${mock_bin}" "${state_dir}" "${app_path}"

cat >"${mock_bin}/hdiutil" <<'MOCK_HDIUTIL'
#!/usr/bin/env bash
set -euo pipefail

command_name="${1:-}"
shift || true
case "${command_name}" in
  create)
    source_folder=""
    previous=""
    for argument in "$@"; do
      if [[ "${previous}" == "-srcfolder" ]]; then
        source_folder="${argument}"
      fi
      previous="${argument}"
    done
    output_path="${!#}"
    printf '%s\n' "${source_folder}" >"${MOCK_STATE_DIR}/source-folder"
    printf 'mock-dmg\n' >"${output_path}"
    if [[ "${MOCK_BUILD_MODE:-success}" == "kill_during_building" ]]; then
      kill -9 "${PPID}"
    fi
    ;;
  verify)
    count=0
    if [[ -f "${MOCK_STATE_DIR}/verify-count" ]]; then
      read -r count <"${MOCK_STATE_DIR}/verify-count"
    fi
    count=$((count + 1))
    printf '%s\n' "${count}" >"${MOCK_STATE_DIR}/verify-count"
    case "${MOCK_VERIFY_MODE}" in
      transient_then_success)
        if [[ "${count}" -le 2 ]]; then
          printf 'hdiutil: verify failed - Resource temporarily unavailable\n' >&2
          exit 1
        fi
        ;;
      transient_forever)
        printf 'hdiutil: verify failed - Resource temporarily unavailable\n' >&2
        exit 1
        ;;
      permanent)
        printf 'hdiutil: verify failed - invalid disk image\n' >&2
        exit 1
        ;;
      permanent_expect_previous)
        [[ -n "${MOCK_CANONICAL_OUTPUT:-}" \
          && -f "${MOCK_CANONICAL_OUTPUT}" \
          && "$(<"${MOCK_CANONICAL_OUTPUT}")" == "previous-verified-dmg" ]]
        printf 'hdiutil: verify failed - invalid disk image\n' >&2
        exit 1
        ;;
      *)
        exit 64
        ;;
    esac
    ;;
  attach)
    if [[ "${MOCK_ATTACH_MODE:-success}" == "fail" ]]; then
      printf 'hdiutil: attach failed - mock mount rejection\n' >&2
      exit 1
    fi
    mount_path=""
    previous=""
    for argument in "$@"; do
      if [[ "${previous}" == "-mountpoint" ]]; then
        mount_path="${argument}"
      fi
      previous="${argument}"
    done
    source_folder="$(<"${MOCK_STATE_DIR}/source-folder")"
    /bin/cp -R "${source_folder}/." "${mount_path}/"
    ;;
  detach)
    ;;
  *)
    exit 64
    ;;
esac
MOCK_HDIUTIL

cat >"${mock_bin}/plutil" <<'MOCK_PLUTIL'
#!/usr/bin/env bash
printf '0.1.0\n'
MOCK_PLUTIL

cat >"${mock_bin}/ditto" <<'MOCK_DITTO'
#!/usr/bin/env bash
set -euo pipefail
/bin/cp -R "$1" "$2"
MOCK_DITTO

cat >"${mock_bin}/python3" <<'MOCK_PYTHON'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-c" ]]; then
  if [[ "${MOCK_PUBLICATION_MODE:-success}" == "insert_first_output" \
    && "${6:-}" == "publish-output" ]]; then
    printf 'concurrent-first-output\n' >"${4}"
  fi
  if [[ "${MOCK_PUBLICATION_MODE:-success}" == "replace_previous_output" \
    && "${6:-}" == "publish-output" ]]; then
    /bin/rm -f "${4}"
    printf 'concurrent-replacement\n' >"${4}"
  fi
  if [[ ("${MOCK_PUBLICATION_MODE:-success}" == "fail_checksum" \
      || "${MOCK_PUBLICATION_MODE:-success}" == "fail_checksum_and_restore") \
    && "${6:-}" == "publish-checksum" ]]; then
    exit 1
  fi
  if [[ "${MOCK_PUBLICATION_MODE:-success}" == "fail_checksum_and_restore" \
    && "${6:-}" == "rollback" ]]; then
    exit 1
  fi
  if [[ "${MOCK_PUBLICATION_MODE:-success}" == "kill_after_dmg_replace" \
    && "${6:-}" == "publish-output" ]]; then
    /usr/bin/python3 "$@"
    kill -9 "${PPID}"
    exit 0
  fi
  if [[ "${MOCK_PUBLICATION_MODE:-success}" == "kill_after_checksum_replace" \
    && "${6:-}" == "publish-checksum" ]]; then
    /usr/bin/python3 "$@"
    kill -9 "${PPID}"
    exit 0
  fi
  exec /usr/bin/python3 "$@"
fi
printf '%s\n' "$*" >>"${MOCK_STATE_DIR}/python-calls"
if [[ "${1:-}" == */tools/build-mac-dmg-prepublication.py \
    || "${1:-}" == */tools/process_instance_identity.py ]]; then
  exec /usr/bin/python3 "$@"
fi
if [[ "${MOCK_BUNDLE_VERIFY_MODE:-success}" == "fail" ]]; then
  printf 'bundle verification failed\n' >&2
  exit 1
fi
MOCK_PYTHON

cat >"${mock_bin}/shasum" <<'MOCK_SHASUM'
#!/usr/bin/env bash
set -euo pipefail
/usr/bin/shasum "$@"
MOCK_SHASUM

cat >"${mock_bin}/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${1:-}" >>"${MOCK_STATE_DIR}/sleep-calls"
MOCK_SLEEP

chmod +x "${mock_bin}"/*

run_build() {
  local mode="$1"
  local output_path="$2"
  local attach_mode="${3:-success}"
  local bundle_verify_mode="${4:-success}"
  local publication_mode="${5:-success}"
  local build_mode="${6:-success}"
  MOCK_STATE_DIR="${state_dir}" \
  MOCK_VERIFY_MODE="${mode}" \
  MOCK_ATTACH_MODE="${attach_mode}" \
  MOCK_BUNDLE_VERIFY_MODE="${bundle_verify_mode}" \
  MOCK_PUBLICATION_MODE="${publication_mode}" \
  MOCK_BUILD_MODE="${build_mode}" \
  MOCK_CANONICAL_OUTPUT="${output_path}" \
  TMPDIR="${test_root}" \
  PATH="${mock_bin}:${PATH}" \
    bash "${repo_root}/tools/build-mac-dmg.sh" \
      --app "${app_path}" \
      --output "${output_path}"
}

reset_state() {
  rm -f "${state_dir}"/*
}

seed_release_pair() {
  local output_path="$1"
  printf 'previous-verified-dmg\n' >"${output_path}"
  (
    cd "$(dirname "${output_path}")"
    /usr/bin/shasum -a 256 "$(basename "${output_path}")" \
      >"$(basename "${output_path}").sha256"
  )
}

assert_previous_pair() {
  local output_path="$1"
  [[ "$(<"${output_path}")" == "previous-verified-dmg" ]]
  (
    cd "$(dirname "${output_path}")"
    /usr/bin/shasum -a 256 -c "$(basename "${output_path}").sha256" \
      >/dev/null 2>&1
  )
}

assert_no_candidate() {
  local output_path="$1"
  local candidate
  candidate="$(find "$(dirname "${output_path}")" -maxdepth 1 \
    -name ".$(basename "${output_path}").candidate.*" -print -quit)"
  [[ -z "${candidate}" ]]
  candidate="$(find "$(dirname "${output_path}")" -maxdepth 1 \
    -name ".$(basename "${output_path}").previous.*" -print -quit)"
  [[ -z "${candidate}" ]]
  [[ ! -e "$(dirname "${output_path}")/.$(basename "${output_path}").publication-transaction" \
    && ! -L "$(dirname "${output_path}")/.$(basename "${output_path}").publication-transaction" ]]
}

publication_transaction_path() {
  local output_path="$1"
  printf '%s/.%s.publication-transaction' \
    "$(dirname "${output_path}")" "$(basename "${output_path}")"
}

success_output="${test_root}/success.dmg"
run_build transient_then_success "${success_output}" >"${test_root}/success.out" 2>&1
[[ "$(<"${state_dir}/verify-count")" == "3" ]]
[[ "$(wc -l <"${state_dir}/sleep-calls" | tr -d ' ')" == "2" ]]
[[ -s "${success_output}" && -s "${success_output}.sha256" ]]
(cd "$(dirname "${success_output}")" && \
  /usr/bin/shasum -a 256 "$(basename "${success_output}")" | \
    cmp - "$(basename "${success_output}").sha256")
assert_no_candidate "${success_output}"
grep -q 'hdiutil verify temporarily unavailable; retrying (1/3)' "${test_root}/success.out"
grep -q '中文：hdiutil verify 暂时不可用；正在重试（2/3）' "${test_root}/success.out"

reset_state
relative_root="${test_root}/relative-output"
mkdir "${relative_root}"
(
  cd "${relative_root}"
  run_build transient_then_success DroidMatch.dmg \
    >"${test_root}/relative-output.out" 2>&1
)
relative_output="${relative_root}/DroidMatch.dmg"
[[ -s "${relative_output}" && -s "${relative_output}.sha256" ]]
(
  cd "${relative_root}"
  /usr/bin/shasum -a 256 -c DroidMatch.dmg.sha256 >/dev/null 2>&1
)
assert_no_candidate "${relative_output}"

for initialization_kind in transaction initializer; do
  for initialization_phase in empty owner marker; do
    reset_state
    initialization_label="${initialization_kind}-${initialization_phase}"
    initialization_output="${test_root}/initialization-${initialization_label}.dmg"
    stable_transaction="$(publication_transaction_path "${initialization_output}")"
    initialization_transaction="${stable_transaction}"
    if [[ "${initialization_kind}" == initializer ]]; then
      initialization_transaction="${stable_transaction}.initializing.999999"
    fi
    mkdir -m 0700 "${initialization_transaction}"
    if [[ "${initialization_phase}" != empty ]]; then
      printf '999999\n' >"${initialization_transaction}/owner-pid"
      chmod 0600 "${initialization_transaction}/owner-pid"
      printf '%s\n' "${current_process_identity}" \
        >"${initialization_transaction}/owner-instance"
      chmod 0600 "${initialization_transaction}/owner-instance"
    fi
    if [[ "${initialization_phase}" == marker ]]; then
      if [[ "${initialization_kind}" == transaction ]]; then
        /usr/bin/python3 "${repo_root}/tools/build-mac-dmg-prepublication.py" \
          record "${initialization_transaction}" "${initialization_output}" \
          999999 "${current_process_identity}"
      else
        printf '{}\n' >"${initialization_transaction}/prepublication"
        chmod 0600 "${initialization_transaction}/prepublication"
      fi
    fi
    set +e
    run_build permanent "${initialization_output}" \
      >"${test_root}/initialization-${initialization_label}.out" 2>&1
    initialization_status=$?
    set -e
    [[ "${initialization_status}" -ne 0 \
      && ! -e "${initialization_transaction}" ]]
    assert_no_candidate "${initialization_output}"
    if [[ "${initialization_kind}" == transaction ]]; then
      grep -q 'Removed an interrupted pre-publication transaction' \
        "${test_root}/initialization-${initialization_label}.out"
    fi
  done
done
reset_state
forged_marker_output="${test_root}/initialization-forged-marker.dmg"
forged_marker_transaction="$(publication_transaction_path \
  "${forged_marker_output}")"
mkdir -m 0700 "${forged_marker_transaction}"
printf '999999\n' >"${forged_marker_transaction}/owner-pid"
chmod 0600 "${forged_marker_transaction}/owner-pid"
printf '%s\n' "${current_process_identity}" \
  >"${forged_marker_transaction}/owner-instance"
chmod 0600 "${forged_marker_transaction}/owner-instance"
/usr/bin/python3 "${repo_root}/tools/build-mac-dmg-prepublication.py" \
  record "${forged_marker_transaction}" "${forged_marker_output}" \
  999999 "${current_process_identity}"
printf '{}\n' >"${forged_marker_transaction}/prepublication"
set +e
run_build permanent "${forged_marker_output}" \
  >"${test_root}/initialization-forged-marker.out" 2>&1
forged_marker_status=$?
set -e
[[ "${forged_marker_status}" -ne 0 \
  && -d "${forged_marker_transaction}" \
  && ! -e "${state_dir}/verify-count" ]]
grep -q 'Release pre-publication transaction is unsafe; it was preserved' \
  "${test_root}/initialization-forged-marker.out"
rm -rf "${forged_marker_transaction}"
reset_state
active_initializer_output="${test_root}/initialization-active.dmg"
active_initializer="$(publication_transaction_path \
  "${active_initializer_output}").initializing.$$"
mkdir -m 0700 "${active_initializer}"
set +e
run_build permanent "${active_initializer_output}" >/dev/null 2>&1
active_initializer_status=$?
set -e
[[ "${active_initializer_status}" -ne 0 && -d "${active_initializer}" \
  && ! -e "${state_dir}/verify-count" ]]
rm -rf "${active_initializer}"

reset_state
building_output="${test_root}/building-interrupted.dmg"
seed_release_pair "${building_output}"
set +e
run_build transient_then_success "${building_output}" \
  success success success kill_during_building \
  >"${test_root}/building-interrupted.out" 2>&1
building_status=$?
set -e
[[ "${building_status}" -ne 0 ]]
building_transaction="$(publication_transaction_path "${building_output}")"
[[ -d "${building_transaction}" \
  && "$(<"${building_transaction}/state")" == "building" \
  && -f "${building_transaction}/prepublication" \
  && ! -e "${building_transaction}/identities" ]]
[[ -s "${building_transaction}/candidate/$(basename "${building_output}")" ]]
assert_previous_pair "${building_output}"
reset_state
set +e
run_build permanent_expect_previous "${building_output}" \
  >"${test_root}/building-recovery.out" 2>&1
building_recovery_status=$?
set -e
[[ "${building_recovery_status}" -ne 0 ]]
assert_previous_pair "${building_output}"
assert_no_candidate "${building_output}"
grep -q 'Removed an interrupted pre-publication transaction' \
  "${test_root}/building-recovery.out"

reset_state
unknown_building_output="${test_root}/building-unknown.dmg"
set +e
run_build transient_then_success "${unknown_building_output}" \
  success success success kill_during_building \
  >"${test_root}/building-unknown-kill.out" 2>&1
unknown_building_status=$?
set -e
[[ "${unknown_building_status}" -ne 0 ]]
unknown_building_transaction="$(publication_transaction_path \
  "${unknown_building_output}")"
printf 'preserve unknown node\n' >"${unknown_building_transaction}/unexpected"
reset_state
set +e
run_build permanent "${unknown_building_output}" \
  >"${test_root}/building-unknown-recovery.out" 2>&1
unknown_building_recovery_status=$?
set -e
[[ "${unknown_building_recovery_status}" -ne 0 ]]
[[ "$(<"${unknown_building_transaction}/unexpected")" == \
  "preserve unknown node" ]]
[[ ! -e "${state_dir}/verify-count" ]]
grep -q 'Release publication transaction is unsafe; it was preserved' \
  "${test_root}/building-unknown-recovery.out"
rm -rf "${unknown_building_transaction}"

helper_output="${test_root}/helper-nofollow.dmg"
helper_transaction="$(publication_transaction_path "${helper_output}")"
helper_external="${test_root}/helper-external"
mkdir -m 0700 "${helper_transaction}" "${helper_external}"
printf 'external sentinel\n' >"${helper_external}/sentinel"
ln -s "${helper_external}" "${helper_transaction}/candidate"
set +e
/usr/bin/python3 "${repo_root}/tools/build-mac-dmg-prepublication.py" \
  remove-validated "${helper_transaction}" "$(basename "${helper_output}")" \
  >/dev/null 2>&1
helper_nofollow_status=$?
set -e
[[ "${helper_nofollow_status}" -ne 0 \
  && -L "${helper_transaction}/candidate" \
  && "$(<"${helper_external}/sentinel")" == "external sentinel" ]]
rm -rf "${helper_transaction}" "${helper_external}"

reset_state
set +e
run_build permanent "${test_root}/permanent.dmg" >"${test_root}/permanent.out" 2>&1
permanent_status=$?
set -e
[[ "${permanent_status}" -ne 0 ]]
[[ "$(<"${state_dir}/verify-count")" == "1" ]]
[[ ! -e "${state_dir}/sleep-calls" ]]
[[ ! -e "${test_root}/permanent.dmg" ]]
[[ ! -e "${test_root}/permanent.dmg.sha256" ]]
assert_no_candidate "${test_root}/permanent.dmg"
grep -q 'invalid disk image' "${test_root}/permanent.out"
if grep -q 'retrying' "${test_root}/permanent.out"; then
  printf 'non-transient hdiutil failures must not be retried\n' >&2
  exit 1
fi

reset_state
set +e
run_build transient_forever "${test_root}/exhausted.dmg" >"${test_root}/exhausted.out" 2>&1
exhausted_status=$?
set -e
[[ "${exhausted_status}" -ne 0 ]]
[[ "$(<"${state_dir}/verify-count")" == "3" ]]
[[ "$(wc -l <"${state_dir}/sleep-calls" | tr -d ' ')" == "2" ]]
[[ ! -e "${test_root}/exhausted.dmg" ]]
[[ ! -e "${test_root}/exhausted.dmg.sha256" ]]
assert_no_candidate "${test_root}/exhausted.dmg"
grep -q 'Resource temporarily unavailable' "${test_root}/exhausted.out"

for failure_mode in verify attach bundle; do
  reset_state
  preserved_output="${test_root}/${failure_mode}-preserved.dmg"
  seed_release_pair "${preserved_output}"
  set +e
  case "${failure_mode}" in
    verify)
      run_build permanent "${preserved_output}" \
        >"${test_root}/${failure_mode}-preserved.out" 2>&1
      ;;
    attach)
      run_build transient_then_success "${preserved_output}" fail \
        >"${test_root}/${failure_mode}-preserved.out" 2>&1
      ;;
    bundle)
      run_build transient_then_success "${preserved_output}" success fail \
        >"${test_root}/${failure_mode}-preserved.out" 2>&1
      ;;
  esac
  failure_status=$?
  set -e
  [[ "${failure_status}" -ne 0 ]]
  assert_previous_pair "${preserved_output}"
  assert_no_candidate "${preserved_output}"
done

reset_state
rollback_output="${test_root}/publication-rollback.dmg"
seed_release_pair "${rollback_output}"
set +e
run_build transient_then_success "${rollback_output}" success success fail_checksum \
  >"${test_root}/publication-rollback.out" 2>&1
rollback_status=$?
set -e
[[ "${rollback_status}" -ne 0 ]]
assert_previous_pair "${rollback_output}"
assert_no_candidate "${rollback_output}"
grep -q 'Release artifact publication rename failed' \
  "${test_root}/publication-rollback.out"

reset_state
uncertain_output="${test_root}/publication-uncertain.dmg"
seed_release_pair "${uncertain_output}"
set +e
run_build transient_then_success "${uncertain_output}" \
  success success fail_checksum_and_restore \
  >"${test_root}/publication-uncertain.out" 2>&1
uncertain_status=$?
set -e
[[ "${uncertain_status}" -ne 0 ]]
uncertain_directory="$(publication_transaction_path "${uncertain_output}")"
[[ -d "${uncertain_directory}" && ! -L "${uncertain_directory}" ]]
[[ "$(<"${uncertain_directory}/previous.dmg")" == "previous-verified-dmg" ]]
saved_digest="$(/usr/bin/shasum -a 256 \
  "${uncertain_directory}/previous.dmg")"
saved_digest="${saved_digest%% *}"
read -r recorded_digest _ <"${uncertain_directory}/previous.sha256"
[[ "${recorded_digest}" == "${saved_digest}" ]]
grep -q 'Release artifact rollback is incomplete' \
  "${test_root}/publication-uncertain.out"
reset_state
set +e
run_build permanent_expect_previous "${uncertain_output}" \
  >"${test_root}/publication-uncertain-recovery.out" 2>&1
uncertain_recovery_status=$?
set -e
[[ "${uncertain_recovery_status}" -ne 0 ]]
assert_previous_pair "${uncertain_output}"
assert_no_candidate "${uncertain_output}"
grep -q 'Restored the previous release artifact pair' \
  "${test_root}/publication-uncertain-recovery.out"

reset_state
interrupted_output="${test_root}/publication-interrupted.dmg"
seed_release_pair "${interrupted_output}"
set +e
run_build transient_then_success "${interrupted_output}" \
  success success kill_after_dmg_replace \
  >"${test_root}/publication-interrupted.out" 2>&1
interrupted_status=$?
set -e
[[ "${interrupted_status}" -ne 0 ]]
[[ "$(<"${interrupted_output}")" == "mock-dmg" ]]
[[ -d "$(publication_transaction_path "${interrupted_output}")" ]]
reset_state
set +e
run_build permanent_expect_previous "${interrupted_output}" \
  >"${test_root}/publication-recovery.out" 2>&1
recovery_status=$?
set -e
[[ "${recovery_status}" -ne 0 ]]
assert_previous_pair "${interrupted_output}"
assert_no_candidate "${interrupted_output}"
grep -q 'Restored the previous release artifact pair' \
  "${test_root}/publication-recovery.out"

reset_state
first_publication_output="${test_root}/first-publication-interrupted.dmg"
set +e
run_build transient_then_success "${first_publication_output}" \
  success success kill_after_dmg_replace \
  >"${test_root}/first-publication-interrupted.out" 2>&1
first_publication_status=$?
set -e
[[ "${first_publication_status}" -ne 0 ]]
[[ "$(<"${first_publication_output}")" == "mock-dmg" ]]
[[ ! -e "${first_publication_output}.sha256" ]]
[[ -d "$(publication_transaction_path "${first_publication_output}")" ]]
reset_state
set +e
run_build permanent "${first_publication_output}" \
  >"${test_root}/first-publication-recovery.out" 2>&1
first_publication_recovery_status=$?
set -e
[[ "${first_publication_recovery_status}" -ne 0 ]]
[[ ! -e "${first_publication_output}" ]]
[[ ! -e "${first_publication_output}.sha256" ]]
assert_no_candidate "${first_publication_output}"
grep -q 'Removed an incomplete release artifact publication' \
  "${test_root}/first-publication-recovery.out"

reset_state
completed_output="${test_root}/publication-completed-before-kill.dmg"
seed_release_pair "${completed_output}"
set +e
run_build transient_then_success "${completed_output}" \
  success success kill_after_checksum_replace \
  >"${test_root}/publication-completed-before-kill.out" 2>&1
completed_status=$?
set -e
[[ "${completed_status}" -ne 0 ]]
[[ "$(<"${completed_output}")" == "mock-dmg" ]]
[[ -d "$(publication_transaction_path "${completed_output}")" ]]
reset_state
set +e
run_build permanent "${completed_output}" \
  >"${test_root}/publication-complete-recovery.out" 2>&1
complete_recovery_status=$?
set -e
[[ "${complete_recovery_status}" -ne 0 ]]
[[ "$(<"${completed_output}")" == "mock-dmg" ]]
(
  cd "$(dirname "${completed_output}")"
  /usr/bin/shasum -a 256 -c "$(basename "${completed_output}").sha256" \
    >/dev/null 2>&1
)
assert_no_candidate "${completed_output}"
grep -q 'Recovered a complete release artifact publication' \
  "${test_root}/publication-complete-recovery.out"

reset_state
replaced_first_output="${test_root}/first-publication-replaced.dmg"
set +e
run_build transient_then_success "${replaced_first_output}" \
  success success kill_after_dmg_replace \
  >"${test_root}/first-publication-replaced-kill.out" 2>&1
replaced_first_kill_status=$?
set -e
[[ "${replaced_first_kill_status}" -ne 0 ]]
/bin/rm -f "${replaced_first_output}"
printf 'later-first-output\n' >"${replaced_first_output}"
reset_state
set +e
run_build permanent "${replaced_first_output}" \
  >"${test_root}/first-publication-replaced-recovery.out" 2>&1
replaced_first_recovery_status=$?
set -e
[[ "${replaced_first_recovery_status}" -ne 0 ]]
[[ "$(<"${replaced_first_output}")" == "later-first-output" ]]
[[ ! -e "${replaced_first_output}.sha256" ]]
[[ -d "$(publication_transaction_path "${replaced_first_output}")" ]]
[[ ! -e "${state_dir}/verify-count" ]]
grep -q 'identities do not match current nodes; transaction was preserved' \
  "${test_root}/first-publication-replaced-recovery.out"
rm -rf "$(publication_transaction_path "${replaced_first_output}")"

reset_state
missing_first_output="${test_root}/first-publication-missing.dmg"
set +e
run_build transient_then_success "${missing_first_output}" \
  success success kill_after_dmg_replace \
  >"${test_root}/first-publication-missing-kill.out" 2>&1
missing_first_kill_status=$?
set -e
[[ "${missing_first_kill_status}" -ne 0 ]]
/bin/rm -f "${missing_first_output}"
reset_state
set +e
run_build permanent "${missing_first_output}" \
  >"${test_root}/first-publication-missing-recovery.out" 2>&1
missing_first_recovery_status=$?
set -e
[[ "${missing_first_recovery_status}" -ne 0 ]]
[[ ! -e "${missing_first_output}" && ! -e "${missing_first_output}.sha256" ]]
[[ -d "$(publication_transaction_path "${missing_first_output}")" ]]
[[ ! -e "${state_dir}/verify-count" ]]
grep -q 'identities do not match current nodes; transaction was preserved' \
  "${test_root}/first-publication-missing-recovery.out"
rm -rf "$(publication_transaction_path "${missing_first_output}")"

reset_state
replaced_previous_output="${test_root}/previous-publication-replaced.dmg"
seed_release_pair "${replaced_previous_output}"
set +e
run_build transient_then_success "${replaced_previous_output}" \
  success success kill_after_dmg_replace \
  >"${test_root}/previous-publication-replaced-kill.out" 2>&1
replaced_previous_kill_status=$?
set -e
[[ "${replaced_previous_kill_status}" -ne 0 ]]
/bin/rm -f "${replaced_previous_output}"
printf 'later-previous-output\n' >"${replaced_previous_output}"
reset_state
set +e
run_build permanent "${replaced_previous_output}" \
  >"${test_root}/previous-publication-replaced-recovery.out" 2>&1
replaced_previous_recovery_status=$?
set -e
[[ "${replaced_previous_recovery_status}" -ne 0 ]]
[[ "$(<"${replaced_previous_output}")" == "later-previous-output" ]]
[[ -s "${replaced_previous_output}.sha256" ]]
[[ -d "$(publication_transaction_path "${replaced_previous_output}")" ]]
[[ ! -e "${state_dir}/verify-count" ]]
grep -q 'identities do not match current nodes; transaction was preserved' \
  "${test_root}/previous-publication-replaced-recovery.out"
rm -rf "$(publication_transaction_path "${replaced_previous_output}")"

reset_state
replaced_checksum_output="${test_root}/publication-checksum-replaced.dmg"
seed_release_pair "${replaced_checksum_output}"
set +e
run_build transient_then_success "${replaced_checksum_output}" \
  success success kill_after_checksum_replace \
  >"${test_root}/publication-checksum-replaced-kill.out" 2>&1
replaced_checksum_kill_status=$?
set -e
[[ "${replaced_checksum_kill_status}" -ne 0 ]]
/bin/rm -f "${replaced_checksum_output}.sha256"
printf 'later-checksum\n' >"${replaced_checksum_output}.sha256"
reset_state
set +e
run_build permanent "${replaced_checksum_output}" \
  >"${test_root}/publication-checksum-replaced-recovery.out" 2>&1
replaced_checksum_recovery_status=$?
set -e
[[ "${replaced_checksum_recovery_status}" -ne 0 ]]
[[ "$(<"${replaced_checksum_output}")" == "mock-dmg" ]]
[[ "$(<"${replaced_checksum_output}.sha256")" == "later-checksum" ]]
[[ -d "$(publication_transaction_path "${replaced_checksum_output}")" ]]
[[ ! -e "${state_dir}/verify-count" ]]
grep -q 'identities do not match current nodes; transaction was preserved' \
  "${test_root}/publication-checksum-replaced-recovery.out"
rm -rf "$(publication_transaction_path "${replaced_checksum_output}")"

for race_mode in insert_first_output replace_previous_output; do
  reset_state
  race_output="${test_root}/${race_mode}.dmg"
  if [[ "${race_mode}" == "replace_previous_output" ]]; then
    seed_release_pair "${race_output}"
  fi
  set +e
  run_build transient_then_success "${race_output}" \
    success success "${race_mode}" >"${test_root}/${race_mode}.out" 2>&1
  race_status=$?
  set -e
  [[ "${race_status}" -ne 0 ]]
  if [[ "${race_mode}" == "insert_first_output" ]]; then
    [[ "$(<"${race_output}")" == "concurrent-first-output" ]]
    [[ ! -e "${race_output}.sha256" ]]
  else
    [[ "$(<"${race_output}")" == "concurrent-replacement" ]]
    [[ -s "${race_output}.sha256" ]]
  fi
  race_transaction="$(publication_transaction_path "${race_output}")"
  [[ -d "${race_transaction}" && ! -L "${race_transaction}" ]]
  grep -q 'Release artifact publication rename failed' \
    "${test_root}/${race_mode}.out"
  rm -rf "${race_transaction}"
done

# shellcheck source=test-build-mac-dmg-owner-identity.sh
source "${repo_root}/tools/test-build-mac-dmg-owner-identity.sh"

reset_state
unsafe_output="${test_root}/publication-unsafe.dmg"
unsafe_transaction="$(publication_transaction_path "${unsafe_output}")"
unsafe_target="${test_root}/unsafe-transaction-target"
mkdir "${unsafe_target}"
printf 'unsafe sentinel\n' >"${unsafe_target}/sentinel"
ln -s "${unsafe_target}" "${unsafe_transaction}"
set +e
run_build permanent "${unsafe_output}" \
  >"${test_root}/publication-unsafe.out" 2>&1
unsafe_status=$?
set -e
[[ "${unsafe_status}" -ne 0 ]]
[[ -L "${unsafe_transaction}" ]]
[[ "$(<"${unsafe_target}/sentinel")" == "unsafe sentinel" ]]
[[ ! -e "${state_dir}/verify-count" ]]
grep -q 'Release publication transaction is unsafe' \
  "${test_root}/publication-unsafe.out"
rm -f "${unsafe_transaction}"

reset_state
legacy_output="${test_root}/publication-legacy.dmg"
legacy_transaction="${test_root}/.publication-legacy.dmg.previous.orphan"
mkdir "${legacy_transaction}"
printf 'legacy sentinel\n' >"${legacy_transaction}/previous.dmg"
set +e
run_build permanent "${legacy_output}" \
  >"${test_root}/publication-legacy.out" 2>&1
legacy_status=$?
set -e
[[ "${legacy_status}" -ne 0 ]]
[[ "$(<"${legacy_transaction}/previous.dmg")" == "legacy sentinel" ]]
[[ ! -e "${state_dir}/verify-count" ]]
grep -q 'legacy release publication transaction requires manual recovery' \
  "${test_root}/publication-legacy.out"
rm -rf "${legacy_transaction}"

reset_state
directory_output="${test_root}/directory-target.dmg"
mkdir "${directory_output}"
set +e
run_build transient_then_success "${directory_output}" \
  >"${test_root}/directory-target.out" 2>&1
directory_status=$?
set -e
[[ "${directory_status}" -ne 0 ]]
[[ -d "${directory_output}" ]]
[[ -z "$(find "${directory_output}" -mindepth 1 -print -quit)" ]]
assert_no_candidate "${directory_output}"

reset_state
external_directory="${test_root}/external-target"
symlink_output="${test_root}/symlink-target.dmg"
mkdir "${external_directory}"
printf 'external sentinel\n' >"${external_directory}/sentinel"
ln -s "${external_directory}" "${symlink_output}"
set +e
run_build transient_then_success "${symlink_output}" \
  >"${test_root}/symlink-target.out" 2>&1
symlink_status=$?
set -e
[[ "${symlink_status}" -ne 0 ]]
[[ -L "${symlink_output}" ]]
[[ "$(readlink "${symlink_output}")" == "${external_directory}" ]]
[[ "$(<"${external_directory}/sentinel")" == "external sentinel" ]]
[[ ! -e "${external_directory}/symlink-target.dmg" ]]
assert_no_candidate "${symlink_output}"

printf 'Mac DMG transactional publication and transient retry tests passed.\n'
printf '中文：Mac DMG 事务化发布与瞬时重试测试通过。\n'
