#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-swift-lock-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

fake_repo="${test_root}/repo"
mock_bin="${test_root}/bin"
call_log="${test_root}/swift-calls"
mkdir -p "${fake_repo}/mac" "${mock_bin}"
cp "${repo_root}/mac/Package.resolved" "${fake_repo}/mac/Package.resolved"

cat >"${mock_bin}/swiftc" <<'MOCK_SWIFTC'
#!/usr/bin/env bash
exit 0
MOCK_SWIFTC

cat >"${mock_bin}/swift" <<'MOCK_SWIFT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_SWIFT_CALL_LOG}"
case "${MOCK_SWIFT_MODE:-success}" in
  success) exit 0 ;;
  fail) exit 23 ;;
  mutate)
    printf '\n' >>"${MOCK_SWIFT_LOCK}"
    exit 0
    ;;
  *) exit 64 ;;
esac
MOCK_SWIFT

chmod +x "${mock_bin}/swift" "${mock_bin}/swiftc"
source "${repo_root}/tools/swift-build-compat.sh"

PATH="${mock_bin}:${PATH}"
export PATH
DROIDMATCH_SWIFT_MODULE_CACHE_PATH="${test_root}/module-cache"
export DROIDMATCH_SWIFT_MODULE_CACHE_PATH
MOCK_SWIFT_CALL_LOG="${call_log}"
export MOCK_SWIFT_CALL_LOG
MOCK_SWIFT_LOCK="${fake_repo}/mac/Package.resolved"
export MOCK_SWIFT_LOCK

droidmatch_prepare_swift_build_environment "${fake_repo}"
[[ " ${droidmatch_swift_compat_args[*]} " == *" --disable-automatic-resolution "* ]]

: >"${call_log}"
droidmatch_run_with_immutable_swift_lock \
  swift build --package-path "${fake_repo}/mac" \
    "${droidmatch_swift_compat_args[@]}"
grep -Fq -- '--disable-automatic-resolution' "${call_log}"

set +e
MOCK_SWIFT_MODE=fail droidmatch_run_with_immutable_swift_lock \
  swift build --package-path "${fake_repo}/mac" \
    "${droidmatch_swift_compat_args[@]}" >/dev/null 2>&1
failure_status=$?
set -e
[[ "${failure_status}" -eq 23 ]]

set +e
MOCK_SWIFT_MODE=mutate droidmatch_run_with_immutable_swift_lock \
  swift build --package-path "${fake_repo}/mac" \
    "${droidmatch_swift_compat_args[@]}" >"${test_root}/mutation.out" 2>&1
mutation_status=$?
set -e
[[ "${mutation_status}" -ne 0 ]]
grep -Fq 'Package.resolved changed during an immutable SwiftPM operation' \
  "${test_root}/mutation.out"

printf 'SwiftPM immutable lock regression passed.\n'
