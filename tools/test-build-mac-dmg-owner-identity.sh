#!/usr/bin/env bash

# Sourced by test-build-mac-dmg.sh after its mocks and assertion helpers exist.

reset_state
active_output="${test_root}/publication-active.dmg"
active_transaction="$(publication_transaction_path "${active_output}")"
mkdir -m 0700 "${active_transaction}"
printf '%s\n' "$$" >"${active_transaction}/owner-pid"
printf '%s\n' "${current_process_identity}" \
  >"${active_transaction}/owner-instance"
printf 'building\n' >"${active_transaction}/state"
set +e
run_build permanent "${active_output}" >"${test_root}/publication-active.out" 2>&1
active_status=$?
set -e
[[ "${active_status}" -ne 0 && -d "${active_transaction}" ]]
[[ ! -e "${state_dir}/verify-count" ]]
grep -q 'Another release publication transaction is active' \
  "${test_root}/publication-active.out"
rm -rf "${active_transaction}"

reset_state
reused_pid_output="${test_root}/publication-reused-pid.dmg"
reused_pid_transaction="$(publication_transaction_path "${reused_pid_output}")"
mkdir -m 0700 "${reused_pid_transaction}"
printf '%s\n' "$$" >"${reused_pid_transaction}/owner-pid"
/bin/sleep 30 &
other_process_pid=$!
/usr/bin/python3 "${repo_root}/tools/process_instance_identity.py" \
  capture "${other_process_pid}" >"${reused_pid_transaction}/owner-instance"
kill "${other_process_pid}"
wait "${other_process_pid}" 2>/dev/null || true
printf 'building\n' >"${reused_pid_transaction}/state"
chmod 0600 "${reused_pid_transaction}"/*
set +e
run_build permanent "${reused_pid_output}" \
  >"${test_root}/publication-reused-pid.out" 2>&1
reused_pid_status=$?
set -e
[[ "${reused_pid_status}" -ne 0 ]]
assert_no_candidate "${reused_pid_output}"
! grep -q 'Another release publication transaction is active' \
  "${test_root}/publication-reused-pid.out"

reset_state
legacy_v1_output="${test_root}/publication-legacy-v1.dmg"
legacy_v1_transaction="$(publication_transaction_path "${legacy_v1_output}")"
mkdir -m 0700 "${legacy_v1_transaction}"
printf '999999\n' >"${legacy_v1_transaction}/owner-pid"
chmod 0600 "${legacy_v1_transaction}/owner-pid"
/usr/bin/python3 -c '
import json, os, sys
root, image = sys.argv[1:]
node = lambda value: {"dev": value.st_dev, "ino": value.st_ino}
payload = {"version": 1, "root": node(os.stat(root)),
           "parent": node(os.stat(os.path.dirname(root))),
           "ownerPid": 999999, "imageName": os.path.basename(image)}
with open(os.path.join(root, "prepublication"), "x", encoding="ascii") as target:
    json.dump(payload, target, sort_keys=True, separators=(",", ":"))
    target.write("\n")
os.chmod(os.path.join(root, "prepublication"), 0o600)
' "${legacy_v1_transaction}" "${legacy_v1_output}"
set +e
run_build permanent "${legacy_v1_output}" \
  >"${test_root}/publication-legacy-v1.out" 2>&1
legacy_v1_status=$?
set -e
[[ "${legacy_v1_status}" -ne 0 ]]
assert_no_candidate "${legacy_v1_output}"
grep -q 'Removed an interrupted pre-publication transaction' \
  "${test_root}/publication-legacy-v1.out"
