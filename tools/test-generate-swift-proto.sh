#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-swift-proto-test.XXXXXX")"
test_root="$(cd "${test_root}" && pwd -P)"
trap 'rm -rf "${test_root}"' EXIT

mock_bin="${test_root}/bin"
output_dir="${test_root}/Generated"
transaction_dir="${test_root}/.Generated.transaction"
real_python="$(command -v python3)"
real_bash="$(command -v bash)"
host_system="${DROIDMATCH_TEST_HOST_SYSTEM:-$(uname -s)}"
mkdir -p "${mock_bin}"

seed_generated_tree() {
  local tree_path="$1"
  local marker="$2"
  rm -rf "${tree_path}"
  mkdir -p "${tree_path}/v1"
  for proto_path in "${repo_root}"/proto/v1/*.proto; do
    generated_name="$(basename "${proto_path}" .proto).pb.swift"
    printf '%s %s\n' "${marker}" "${generated_name}" \
      >"${tree_path}/v1/${generated_name}"
  done
  chmod 0755 "${tree_path}" "${tree_path}/v1"
  chmod 0644 "${tree_path}"/v1/*.pb.swift
}

assert_generated_tree() {
  local tree_path="$1"
  local marker="$2"
  [[ -d "${tree_path}/v1" && ! -L "${tree_path}" ]]
  local expected_names=()
  for proto_path in "${repo_root}"/proto/v1/*.proto; do
    generated_name="$(basename "${proto_path}" .proto).pb.swift"
    grep -Fq "${marker}" "${tree_path}/v1/${generated_name}"
    expected_names+=("${generated_name}")
  done
  "${real_python}" -c '
import os, stat, sys
root, *expected = sys.argv[1:]
root_info = os.lstat(root)
v1 = os.path.join(root, "v1")
v1_info = os.lstat(v1)
assert stat.S_ISDIR(root_info.st_mode) and stat.S_IMODE(root_info.st_mode) == 0o755
assert stat.S_ISDIR(v1_info.st_mode) and stat.S_IMODE(v1_info.st_mode) == 0o755
assert set(os.listdir(root)) == {"v1"}
assert set(os.listdir(v1)) == set(expected)
for name in expected:
    info = os.lstat(os.path.join(v1, name))
    assert stat.S_ISREG(info.st_mode)
    assert stat.S_IMODE(info.st_mode) == 0o644
    assert info.st_nlink == 1 and info.st_size > 0
' "${tree_path}" "${expected_names[@]}"
}

assert_no_transaction() {
  [[ ! -e "${transaction_dir}" && ! -L "${transaction_dir}" ]]
  [[ "$(find "${test_root}" -maxdepth 1 \
      -name '.Generated.transaction.new.*' -print -quit)" == "" ]]
}

cat >"${mock_bin}/protoc" <<'MOCK_PROTOC'
#!/usr/bin/env bash
set -euo pipefail

output_dir=""
for argument in "$@"; do
  case "${argument}" in
    --swift_out=*) output_dir="${argument#--swift_out=}" ;;
  esac
done
[[ -n "${output_dir}" ]]
mkdir -p "${output_dir}/v1"

if [[ "${FAKE_PROTOC_MODE}" == "slow_success" ]]; then
  /bin/sleep 2
fi
if [[ "${FAKE_PROTOC_MODE}" == "partial_failure" ]]; then
  printf 'partial output\n' >"${output_dir}/v1/device.pb.swift"
  exit 7
fi
if [[ "${FAKE_PROTOC_MODE}" == "incomplete_success" ]]; then
  printf 'incomplete output\n' >"${output_dir}/v1/device.pb.swift"
  exit 0
fi

for proto_path in "$@"; do
  case "${proto_path}" in
    proto/v1/*.proto)
      generated_name="$(basename "${proto_path}" .proto).pb.swift"
      printf 'generated %s\n' "${generated_name}" \
        >"${output_dir}/v1/${generated_name}"
      ;;
  esac
done

case "${FAKE_PROTOC_MODE}" in
  empty_file)
    : >"${output_dir}/v1/device.pb.swift"
    ;;
  extra_file)
    printf 'unexpected\n' >"${output_dir}/v1/unexpected.pb.swift"
    ;;
  extra_directory)
    mkdir "${output_dir}/v1/unexpected"
    ;;
  hardlink)
    rm "${output_dir}/v1/error.pb.swift"
    ln "${output_dir}/v1/device.pb.swift" "${output_dir}/v1/error.pb.swift"
    ;;
  symlink)
    rm "${output_dir}/v1/device.pb.swift"
    ln -s error.pb.swift "${output_dir}/v1/device.pb.swift"
    ;;
  fifo)
    rm "${output_dir}/v1/device.pb.swift"
    mkfifo "${output_dir}/v1/device.pb.swift"
    ;;
  noncanonical_modes)
    chmod 0700 "${output_dir}" "${output_dir}/v1"
    chmod 0600 "${output_dir}"/v1/*.pb.swift
    ;;
esac
MOCK_PROTOC

cat >"${mock_bin}/protoc-gen-swift" <<'MOCK_PLUGIN'
#!/usr/bin/env bash
exit 0
MOCK_PLUGIN

cat >"${mock_bin}/python3" <<'MOCK_PYTHON'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-c" && "${2:-}" == *"snapshot-proto-transaction"* \
    && "${MOCK_PUBLICATION_MODE:-success}" == "root_rebind" ]]; then
  snapshot="$("${REAL_PYTHON}" "$@")"
  root_path="${3}"
  /bin/mv "${root_path}" "${root_path}.detached-by-test"
  /bin/mkdir -m 0700 "${root_path}"
  printf 'replacement must survive\n' >"${root_path}/sentinel"
  printf '%s\n' "${snapshot}"
  exit 0
fi

if [[ "${1:-}" == "-c" && "${2:-}" == *"create-proto-transaction"* ]]; then
  if [[ "${HOST_SYSTEM}" == "Darwin" ]]; then
    exec "${REAL_PYTHON}" "$@"
  fi
  exec "${REAL_PYTHON}" -c '
import os, sys
root, owner = sys.argv[1:]
os.mkdir(root, 0o700)
try:
    for name, value in (("format", "droidmatch-swift-proto-publication-v2\n"),
                        ("owner-pid", owner + "\n"), ("state", "preparing\n")):
        fd = os.open(os.path.join(root, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(fd, value.encode("ascii"))
            os.fsync(fd)
        finally:
            os.close(fd)
    root_fd = os.open(root, os.O_RDONLY)
    try:
        os.fsync(root_fd)
        info = os.fstat(root_fd)
    finally:
        os.close(root_fd)
    parent_fd = os.open(os.path.dirname(root), os.O_RDONLY)
    try:
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)
    print(f"{info.st_dev}:{info.st_ino}")
except BaseException:
    for name in os.listdir(root):
        os.unlink(os.path.join(root, name))
    os.rmdir(root)
    raise
' "${3}" "${4}"
fi

if [[ "${1:-}" == "-c" && "${2:-}" == *"swap-generated-directories"* ]]; then
  source_path="${3}"
  destination_path="${4}"
  case "${MOCK_PUBLICATION_MODE:-success}" in
    fail_swap)
      exit 9
      ;;
    replace_output)
      /bin/mv "${destination_path}" "${destination_path}.replaced-by-test"
      /bin/mv "${RACE_REPLACEMENT_PATH}" "${destination_path}"
      ;;
  esac
  if [[ "${HOST_SYSTEM}" == "Darwin" ]]; then
    "${REAL_PYTHON}" "$@"
  else
    "${REAL_PYTHON}" -c '
import os, stat, sys
source, destination, source_id, destination_id, root_id = sys.argv[1:]
def identity(path):
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode):
        raise RuntimeError("publication node is not a directory")
    return f"{info.st_dev}:{info.st_ino}"
if identity(os.path.dirname(source)) != root_id:
    raise RuntimeError("transaction root changed")
if identity(source) != source_id or identity(destination) != destination_id:
    raise RuntimeError("publication identity changed")
temporary = source + ".mock-swap"
os.rename(source, temporary)
try:
    os.rename(destination, source)
    os.rename(temporary, destination)
except BaseException:
    if os.path.exists(temporary) and not os.path.exists(source):
        os.rename(temporary, source)
    raise
if identity(source) != destination_id or identity(destination) != source_id:
    raise RuntimeError("mock swap postcondition failed")
' "${3}" "${4}" "${5}" "${6}" "${7}"
  fi
  if [[ "${MOCK_PUBLICATION_MODE:-success}" == "kill_after_swap" ]]; then
    kill -9 "${PPID}"
  fi
  exit 0
fi

if [[ "${1:-}" == "-c" && "${2:-}" == *"install-generated-directory"* ]]; then
  destination_path="${4}"
  case "${MOCK_PUBLICATION_MODE:-success}" in
    insert_file)
      printf 'concurrent file\n' >"${destination_path}"
      exit 9
      ;;
    insert_directory)
      /bin/mkdir "${destination_path}"
      exit 9
      ;;
  esac
  if [[ "${HOST_SYSTEM}" == "Darwin" ]]; then
    "${REAL_PYTHON}" "$@"
  else
    "${REAL_PYTHON}" -c '
import os, stat, sys
source, destination, source_id, root_id = sys.argv[1:]
def identity(path):
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode):
        raise RuntimeError("publication node is not a directory")
    return f"{info.st_dev}:{info.st_ino}"
if identity(os.path.dirname(source)) != root_id or identity(source) != source_id:
    raise RuntimeError("candidate identity changed")
if os.path.lexists(destination):
    raise FileExistsError(destination)
os.rename(source, destination)
if identity(destination) != source_id:
    raise RuntimeError("mock install postcondition failed")
' "${3}" "${4}" "${5}" "${6}"
  fi
  if [[ "${MOCK_PUBLICATION_MODE:-success}" == "kill_after_install" ]]; then
    kill -9 "${PPID}"
  fi
  exit 0
fi

exec "${REAL_PYTHON}" "$@"
MOCK_PYTHON

chmod +x "${mock_bin}/protoc" "${mock_bin}/protoc-gen-swift" \
  "${mock_bin}/python3"

run_generator() {
  local mode="$1"
  local publication_mode="${2:-success}"
  FAKE_PROTOC_MODE="${mode}" \
  MOCK_PUBLICATION_MODE="${publication_mode}" \
  REAL_PYTHON="${real_python}" \
  HOST_SYSTEM="${host_system}" \
  RACE_REPLACEMENT_PATH="${race_replacement_path:-}" \
  PROTOC_GEN_SWIFT="${mock_bin}/protoc-gen-swift" \
  SWIFT_PROTO_OUTPUT_DIR="${output_dir}" \
  PATH="${mock_bin}:${PATH}" \
    "${real_bash}" "${repo_root}/tools/generate-swift-proto.sh"
}

seed_generated_tree "${output_dir}" old
set +e
run_generator partial_failure >"${test_root}/partial-failure.out" 2>&1
partial_failure_status=$?
set -e
[[ "${partial_failure_status}" -eq 7 ]]
assert_generated_tree "${output_dir}" old
assert_no_transaction

set +e
run_generator partial_failure root_rebind >"${test_root}/root-rebind.out" 2>&1
root_rebind_status=$?
set -e
[[ "${root_rebind_status}" -eq 7 ]]
assert_generated_tree "${output_dir}" old
[[ -d "${transaction_dir}" && ! -L "${transaction_dir}" ]]
[[ "$(<"${transaction_dir}/sentinel")" == "replacement must survive" ]]
[[ -d "${transaction_dir}.detached-by-test" ]]
grep -q 'private transaction was preserved' "${test_root}/root-rebind.out"
rm -rf "${transaction_dir}" "${transaction_dir}.detached-by-test"

set +e
run_generator incomplete_success >"${test_root}/incomplete.out" 2>&1
incomplete_status=$?
set -e
[[ "${incomplete_status}" -ne 0 ]]
assert_generated_tree "${output_dir}" old
assert_no_transaction
grep -q 'incomplete or unsafe tree' "${test_root}/incomplete.out"

for unsafe_mode in empty_file extra_file extra_directory hardlink symlink fifo; do
  seed_generated_tree "${output_dir}" old
  set +e
  run_generator "${unsafe_mode}" >"${test_root}/${unsafe_mode}.out" 2>&1
  unsafe_mode_status=$?
  set -e
  [[ "${unsafe_mode_status}" -ne 0 ]]
  assert_generated_tree "${output_dir}" old
  assert_no_transaction
  grep -q 'incomplete or unsafe tree' "${test_root}/${unsafe_mode}.out"
done

seed_generated_tree "${output_dir}" old
run_generator noncanonical_modes >"${test_root}/normalized-modes.out" 2>&1
assert_generated_tree "${output_dir}" generated
assert_no_transaction

seed_generated_tree "${output_dir}" old
set +e
run_generator success fail_swap >"${test_root}/swap-failure.out" 2>&1
swap_failure_status=$?
set -e
[[ "${swap_failure_status}" -ne 0 ]]
assert_generated_tree "${output_dir}" old
assert_no_transaction

run_generator slow_success >"${test_root}/concurrent-owner.out" 2>&1 &
concurrent_owner_pid=$!
transaction_observed=false
for _ in {1..100}; do
  if [[ -d "${transaction_dir}" ]]; then
    transaction_observed=true
    break
  fi
  /bin/sleep 0.02
done
[[ "${transaction_observed}" == true ]]
set +e
run_generator success >"${test_root}/concurrent-contender.out" 2>&1
concurrent_contender_status=$?
set -e
[[ "${concurrent_contender_status}" -ne 0 ]]
grep -q 'transaction is active' "${test_root}/concurrent-contender.out"
wait "${concurrent_owner_pid}"
assert_generated_tree "${output_dir}" generated
assert_no_transaction

run_generator success >"${test_root}/replacement-success.out" 2>&1
assert_generated_tree "${output_dir}" generated
assert_no_transaction

rm -rf "${output_dir}"
run_generator success >"${test_root}/first-success.out" 2>&1
assert_generated_tree "${output_dir}" generated
assert_no_transaction

for race_mode in insert_file insert_directory; do
  rm -rf "${output_dir}"
  set +e
  run_generator success "${race_mode}" \
    >"${test_root}/first-${race_mode}.out" 2>&1
  race_status=$?
  set -e
  [[ "${race_status}" -ne 0 ]]
  assert_no_transaction
  if [[ "${race_mode}" == "insert_file" ]]; then
    [[ -f "${output_dir}" && ! -L "${output_dir}" ]]
    [[ "$(<"${output_dir}")" == "concurrent file" ]]
  else
    [[ -d "${output_dir}" && ! -L "${output_dir}" ]]
    [[ -z "$(find "${output_dir}" -mindepth 1 -print -quit)" ]]
  fi
done

seed_generated_tree "${output_dir}" old
race_replacement_path="${test_root}/concurrent-generated"
seed_generated_tree "${race_replacement_path}" concurrent
set +e
run_generator success replace_output >"${test_root}/replace-race.out" 2>&1
replace_race_status=$?
set -e
[[ "${replace_race_status}" -ne 0 ]]
assert_generated_tree "${output_dir}" concurrent
assert_generated_tree "${output_dir}.replaced-by-test" old
assert_no_transaction
rm -rf "${output_dir}.replaced-by-test"
unset race_replacement_path

seed_generated_tree "${output_dir}" old
set +e
run_generator success kill_after_swap >"${test_root}/kill-after-swap.out" 2>&1
kill_after_swap_status=$?
set -e
[[ "${kill_after_swap_status}" -ne 0 ]]
assert_generated_tree "${output_dir}" generated
[[ -d "${transaction_dir}" ]]
assert_generated_tree "${transaction_dir}/staging" old

set +e
run_generator partial_failure >"${test_root}/swap-recovery.out" 2>&1
swap_recovery_status=$?
set -e
[[ "${swap_recovery_status}" -eq 7 ]]
assert_generated_tree "${output_dir}" generated
assert_no_transaction

rm -rf "${output_dir}"
set +e
run_generator success kill_after_install >"${test_root}/kill-after-install.out" 2>&1
kill_after_install_status=$?
set -e
[[ "${kill_after_install_status}" -ne 0 ]]
assert_generated_tree "${output_dir}" generated
[[ -d "${transaction_dir}" ]]
[[ ! -e "${transaction_dir}/staging" ]]

set +e
run_generator partial_failure >"${test_root}/install-recovery.out" 2>&1
install_recovery_status=$?
set -e
[[ "${install_recovery_status}" -eq 7 ]]
assert_generated_tree "${output_dir}" generated
assert_no_transaction

outside_transaction_target="${test_root}/outside-transaction-target"
mkdir "${outside_transaction_target}"
printf 'preserve me\n' >"${outside_transaction_target}/sentinel"
ln -s "${outside_transaction_target}" "${transaction_dir}"
set +e
run_generator partial_failure >"${test_root}/unsafe-symlink.out" 2>&1
unsafe_symlink_status=$?
set -e
[[ "${unsafe_symlink_status}" -ne 0 && -L "${transaction_dir}" ]]
[[ "$(<"${outside_transaction_target}/sentinel")" == "preserve me" ]]
grep -q 'transaction is unsafe' "${test_root}/unsafe-symlink.out"
rm "${transaction_dir}"

mkdir -m 0700 "${transaction_dir}"
printf 'unknown content\n' >"${transaction_dir}/sentinel"
set +e
run_generator partial_failure >"${test_root}/unsafe-layout.out" 2>&1
unsafe_layout_status=$?
set -e
[[ "${unsafe_layout_status}" -ne 0 ]]
[[ "$(<"${transaction_dir}/sentinel")" == "unknown content" ]]
grep -q 'transaction is unsafe' "${test_root}/unsafe-layout.out"
rm -rf "${transaction_dir}"

mkdir -m 0700 "${transaction_dir}"
printf 'droidmatch-swift-proto-publication-v2\n' >"${transaction_dir}/format"
printf '%s\n' "$$" >"${transaction_dir}/owner-pid"
printf 'preparing\n' >"${transaction_dir}/state"
chmod 0600 "${transaction_dir}/format" "${transaction_dir}/owner-pid" \
  "${transaction_dir}/state"
set +e
run_generator partial_failure >"${test_root}/active.out" 2>&1
active_status=$?
set -e
[[ "${active_status}" -ne 0 && -d "${transaction_dir}" ]]
grep -q 'transaction is active' "${test_root}/active.out"
rm -rf "${transaction_dir}"

outside_partial_target="${test_root}/outside-partial-target"
mkdir "${outside_partial_target}"
printf 'outside partial\n' >"${outside_partial_target}/sentinel"
mkdir -m 0700 "${transaction_dir}"
printf 'droidmatch-swift-proto-publication-v2\n' >"${transaction_dir}/format"
printf '99999999\n' >"${transaction_dir}/owner-pid"
printf 'preparing\n' >"${transaction_dir}/state"
chmod 0600 "${transaction_dir}/format" "${transaction_dir}/owner-pid" \
  "${transaction_dir}/state"
mkdir -m 0700 "${transaction_dir}/staging"
ln -s "${outside_partial_target}" "${transaction_dir}/staging/untrusted-link"
set +e
run_generator partial_failure >"${test_root}/stale-preparing.out" 2>&1
stale_status=$?
set -e
[[ "${stale_status}" -eq 7 ]]
[[ "$(<"${outside_partial_target}/sentinel")" == "outside partial" ]]
assert_generated_tree "${output_dir}" generated
assert_no_transaction

rm -rf "${output_dir}"
printf 'unrecognized output\n' >"${output_dir}"
set +e
run_generator success >"${test_root}/unsafe-output.out" 2>&1
unsafe_output_status=$?
set -e
[[ "${unsafe_output_status}" -ne 0 && -f "${output_dir}" ]]
[[ "$(<"${output_dir}")" == "unrecognized output" ]]
assert_no_transaction

rm -f "${output_dir}"
seed_generated_tree "${output_dir}" old
chmod 0600 "${output_dir}/v1/device.pb.swift"
set +e
run_generator success >"${test_root}/unsafe-output-mode.out" 2>&1
unsafe_output_mode_status=$?
set -e
[[ "${unsafe_output_mode_status}" -ne 0 ]]
grep -Fq 'old device.pb.swift' "${output_dir}/v1/device.pb.swift"
[[ ! -e "${transaction_dir}" && ! -L "${transaction_dir}" ]]

seed_generated_tree "${output_dir}" old
rm "${output_dir}/v1/error.pb.swift"
ln "${output_dir}/v1/device.pb.swift" "${output_dir}/v1/error.pb.swift"
set +e
run_generator success >"${test_root}/unsafe-output-hardlink.out" 2>&1
unsafe_output_hardlink_status=$?
set -e
[[ "${unsafe_output_hardlink_status}" -ne 0 ]]
grep -Fq 'old device.pb.swift' "${output_dir}/v1/device.pb.swift"
[[ ! -e "${transaction_dir}" && ! -L "${transaction_dir}" ]]

seed_generated_tree "${output_dir}" old
rm -rf "${output_dir}"
run_generator success >"${test_root}/final-success.out" 2>&1
assert_generated_tree "${output_dir}" generated
assert_no_transaction
grep -q "Generated Swift protobuf files in ${output_dir}" \
  "${test_root}/final-success.out"

default_repo="${test_root}/default-repo"
default_output="${test_root}/DefaultGenerated"
bootstrap_log="${test_root}/bootstrap.log"
mkdir -p "${default_repo}/tools" "${default_repo}/proto/v1"
cp "${repo_root}/tools/generate-swift-proto.sh" \
  "${default_repo}/tools/generate-swift-proto.sh"
cp "${repo_root}"/proto/v1/*.proto "${default_repo}/proto/v1/"
cat >"${default_repo}/tools/bootstrap-swift-protobuf.sh" <<'MOCK_BOOTSTRAP'
#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' >>"${BOOTSTRAP_LOG}"
if [[ "${BOOTSTRAP_STATUS:-0}" != "0" ]]; then
  exit "${BOOTSTRAP_STATUS}"
fi
mkdir -p .tools/bin
cp "${MOCK_PLUGIN_SOURCE}" .tools/bin/protoc-gen-swift
chmod 0755 .tools/bin/protoc-gen-swift
MOCK_BOOTSTRAP
chmod 0755 "${default_repo}/tools/bootstrap-swift-protobuf.sh"

(
  cd "${default_repo}"
  unset PROTOC_GEN_SWIFT
  FAKE_PROTOC_MODE=success \
  MOCK_PUBLICATION_MODE=success \
  REAL_PYTHON="${real_python}" \
  HOST_SYSTEM="${host_system}" \
  BOOTSTRAP_LOG="${bootstrap_log}" \
  MOCK_PLUGIN_SOURCE="${mock_bin}/protoc-gen-swift" \
  RACE_REPLACEMENT_PATH= \
  SWIFT_PROTO_OUTPUT_DIR="${default_output}" \
  PATH="${mock_bin}:${PATH}" \
    "${real_bash}" tools/generate-swift-proto.sh
) >"${test_root}/default-composition.out" 2>&1
assert_generated_tree "${default_output}" generated
[[ "$(wc -l <"${bootstrap_log}" | tr -d ' ')" -eq 1 ]]

: >"${bootstrap_log}"
rm -rf "${default_output}"
(
  cd "${default_repo}"
  FAKE_PROTOC_MODE=success \
  MOCK_PUBLICATION_MODE=success \
  REAL_PYTHON="${real_python}" \
  HOST_SYSTEM="${host_system}" \
  BOOTSTRAP_LOG="${bootstrap_log}" \
  MOCK_PLUGIN_SOURCE="${mock_bin}/protoc-gen-swift" \
  RACE_REPLACEMENT_PATH= \
  PROTOC_GEN_SWIFT="${mock_bin}/protoc-gen-swift" \
  SWIFT_PROTO_OUTPUT_DIR="${default_output}" \
  PATH="${mock_bin}:${PATH}" \
    "${real_bash}" tools/generate-swift-proto.sh
) >"${test_root}/explicit-override.out" 2>&1
assert_generated_tree "${default_output}" generated
[[ ! -s "${bootstrap_log}" ]]

seed_generated_tree "${default_output}" old
set +e
(
  cd "${default_repo}"
  FAKE_PROTOC_MODE=success \
  REAL_PYTHON="${real_python}" \
  HOST_SYSTEM="${host_system}" \
  BOOTSTRAP_LOG="${bootstrap_log}" \
  MOCK_PLUGIN_SOURCE="${mock_bin}/protoc-gen-swift" \
  PROTOC_GEN_SWIFT= \
  SWIFT_PROTO_OUTPUT_DIR="${default_output}" \
  PATH="${mock_bin}:${PATH}" \
    "${real_bash}" tools/generate-swift-proto.sh
) >"${test_root}/empty-override.out" 2>&1
empty_override_status=$?
set -e
[[ "${empty_override_status}" -ne 0 && ! -s "${bootstrap_log}" ]]
assert_generated_tree "${default_output}" old

: >"${bootstrap_log}"
rm -f "${default_repo}/.tools/bin/protoc-gen-swift"
set +e
(
  cd "${default_repo}"
  unset PROTOC_GEN_SWIFT
  FAKE_PROTOC_MODE=success \
  REAL_PYTHON="${real_python}" \
  HOST_SYSTEM="${host_system}" \
  BOOTSTRAP_LOG="${bootstrap_log}" \
  BOOTSTRAP_STATUS=23 \
  MOCK_PLUGIN_SOURCE="${mock_bin}/protoc-gen-swift" \
  SWIFT_PROTO_OUTPUT_DIR="${default_output}" \
  PATH="${mock_bin}:${PATH}" \
    "${real_bash}" tools/generate-swift-proto.sh
) >"${test_root}/bootstrap-failure.out" 2>&1
bootstrap_failure_status=$?
set -e
[[ "${bootstrap_failure_status}" -eq 23 ]]
[[ "$(wc -l <"${bootstrap_log}" | tr -d ' ')" -eq 1 ]]
assert_generated_tree "${default_output}" old

printf 'Swift protobuf transactional generation tests passed.\n'
printf '中文：Swift protobuf 事务化生成测试通过。\n'
