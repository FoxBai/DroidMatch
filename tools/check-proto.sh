#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

if command -v protoc >/dev/null 2>&1; then
  protoc_bin="protoc"
elif [[ -x "${HOME}/.local/bin/protoc" ]]; then
  protoc_bin="${HOME}/.local/bin/protoc"
else
  printf 'protoc not found. Install protobuf-compiler or add protoc to PATH.\n' >&2
  printf '中文：未找到 protoc；请安装 protobuf-compiler，或把 protoc 加到 PATH。\n' >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

"${protoc_bin}" \
  --proto_path=proto \
  --descriptor_set_out="${tmp_dir}/droidmatch-v1.pb" \
  proto/v1/*.proto

printf 'Proto check passed with %s.\n' "$("${protoc_bin}" --version)"
