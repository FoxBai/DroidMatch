#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-swift-proto-freshness-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

committed="${test_root}/Committed"
mock_generator="${test_root}/mock-generator.sh"
cp -R "${repo_root}/mac/Sources/DroidMatchCore/Generated" "${committed}"

cat >"${mock_generator}" <<'MOCK_GENERATOR'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${PROTOC_GEN_SWIFT+x}" ]]
[[ -z "${SWIFT_PROTOBUF_PACKAGE_RESOLVED+x}" ]]
[[ -z "${SWIFT_PROTOBUF_CHECKOUT+x}" ]]
[[ -n "${SWIFT_PROTO_OUTPUT_DIR:-}" ]]
cp -R "${MOCK_COMMITTED}" "${SWIFT_PROTO_OUTPUT_DIR}"
case "${MOCK_FRESHNESS_MODE:-match}" in
  match) ;;
  content)
    printf '// stale mutation\n' \
      >>"${SWIFT_PROTO_OUTPUT_DIR}/v1/device.pb.swift"
    ;;
  missing)
    rm "${SWIFT_PROTO_OUTPUT_DIR}/v1/device.pb.swift"
    ;;
  extra)
    printf '// unexpected\n' \
      >"${SWIFT_PROTO_OUTPUT_DIR}/v1/unexpected.pb.swift"
    ;;
  *) exit 64 ;;
esac
MOCK_GENERATOR
chmod +x "${mock_generator}"

run_gate() {
  DROIDMATCH_SWIFT_PROTO_TEST_MODE=1 \
  DROIDMATCH_TEST_SWIFT_PROTO_GENERATOR="${mock_generator}" \
  DROIDMATCH_TEST_SWIFT_PROTO_COMMITTED_DIR="${committed}" \
  MOCK_COMMITTED="${committed}" \
  MOCK_FRESHNESS_MODE="$1" \
  PROTOC_GEN_SWIFT="${test_root}/poison-plugin" \
  SWIFT_PROTOBUF_PACKAGE_RESOLVED="${test_root}/poison-lock" \
  SWIFT_PROTOBUF_CHECKOUT="${test_root}/poison-checkout" \
    bash "${repo_root}/tools/check-swift-proto-freshness.sh"
}

run_gate match >"${test_root}/match.out"
grep -Fq 'generated sources match' "${test_root}/match.out"

for mode in content missing extra; do
  set +e
  run_gate "${mode}" >"${test_root}/${mode}.out" 2>&1
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
done
grep -Fq 'committed Swift protobuf sources are stale: v1/device.pb.swift' \
  "${test_root}/content.out"
grep -Fq 'missing=device.pb.swift' "${test_root}/missing.out"
grep -Fq 'extra=unexpected.pb.swift' "${test_root}/extra.out"

printf 'Swift protobuf freshness gate regression passed.\n'
