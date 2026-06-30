#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

swift_protobuf_checkout="${SWIFT_PROTOBUF_CHECKOUT:-mac/.build/checkouts/swift-protobuf}"
protoc_gen_swift="${PROTOC_GEN_SWIFT:-}"

if [[ -z "${protoc_gen_swift}" ]]; then
  if [[ ! -d "${swift_protobuf_checkout}" ]]; then
    swift package --package-path mac resolve
  fi
  swift build --package-path "${swift_protobuf_checkout}" -c release --product protoc-gen-swift
  protoc_gen_swift="${swift_protobuf_checkout}/.build/release/protoc-gen-swift"
fi

if [[ ! -x "${protoc_gen_swift}" ]]; then
  printf 'protoc-gen-swift not found or not executable: %s\n' "${protoc_gen_swift}" >&2
  exit 1
fi

output_dir="mac/Sources/DroidMatchCore/Generated"
rm -rf "${output_dir}"
mkdir -p "${output_dir}"

protoc \
  --plugin="protoc-gen-swift=${protoc_gen_swift}" \
  --proto_path=proto \
  --swift_out="${output_dir}" \
  --swift_opt=Visibility=Public \
  proto/v1/*.proto

printf 'Generated Swift protobuf files in %s\n' "${output_dir}"
