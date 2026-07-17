#!/usr/bin/env bash

# Sourced by test-build-mac-app.sh after its mocks and assertion helpers exist.

active_output="${test_root}/active/DroidMatch.app"
seed_droidmatch_bundle "${active_output}" active-old
active_transaction="$(transaction_path "${active_output}")"
mkdir -m 700 "${active_transaction}"
printf 'droidmatch-app-publication-v2\n' >"${active_transaction}/format"
printf '%s\n' "$$" >"${active_transaction}/owner-pid"
"${real_python}" "${repo_root}/tools/process_instance_identity.py" capture "$$" \
  >"${active_transaction}/owner-instance"
printf 'preparing\n' >"${active_transaction}/state"
set +e
run_build "${active_output}" >"${test_root}/active.out" 2>&1
active_status=$?
set -e
[[ "${active_status}" -ne 0 && -d "${active_transaction}" ]]
assert_bundle_marker "${active_output}" active-old
grep -q 'Another App publication transaction is active' "${test_root}/active.out"

reused_pid_output="${test_root}/reused-pid/DroidMatch.app"
seed_droidmatch_bundle "${reused_pid_output}" reused-pid-old
reused_pid_transaction="$(transaction_path "${reused_pid_output}")"
mkdir -m 700 "${reused_pid_transaction}"
printf 'droidmatch-app-publication-v2\n' >"${reused_pid_transaction}/format"
printf '%s\n' "$$" >"${reused_pid_transaction}/owner-pid"
/bin/sleep 30 &
other_process_pid=$!
"${real_python}" "${repo_root}/tools/process_instance_identity.py" \
  capture "${other_process_pid}" >"${reused_pid_transaction}/owner-instance"
kill "${other_process_pid}"
wait "${other_process_pid}" 2>/dev/null || true
printf 'preparing\n' >"${reused_pid_transaction}/state"
set +e
run_build "${reused_pid_output}" build_fail >"${test_root}/reused-pid.out" 2>&1
reused_pid_status=$?
set -e
[[ "${reused_pid_status}" -ne 0 ]]
assert_bundle_marker "${reused_pid_output}" reused-pid-old
assert_no_transaction "${reused_pid_output}"
! grep -q 'Another App publication transaction is active' \
  "${test_root}/reused-pid.out"
