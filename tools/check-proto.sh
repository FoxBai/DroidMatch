#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

# Accepted-history comparisons must not be redirected by local replacement or
# graft metadata. CI normally fetches neither, but local guarded integration is
# held to the same object identity.
export GIT_NO_REPLACE_OBJECTS=1
export GIT_GRAFT_FILE=/dev/null

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
  --include_imports \
  --descriptor_set_out="${tmp_dir}/droidmatch-v1.pb" \
  proto/v1/*.proto

comparison_arguments=(
  --descriptor "${tmp_dir}/droidmatch-v1.pb"
  --baseline proto/v1/compatibility-baseline.json
)

selected_base_ref="${DROIDMATCH_PROTO_BASE_REF:-}"
if [[ "${GITHUB_EVENT_NAME:-}" == "push" ]] && \
  [[ "${GITHUB_REF:-}" == refs/heads/codex/main-gate/* ]]; then
  if ! selected_base_ref="$(
    git rev-parse --verify 'refs/remotes/origin/main^{commit}' 2>/dev/null
  )"; then
    printf 'The main-gate base commit is unavailable after full checkout.\n' >&2
    exit 1
  fi
elif [[ "${selected_base_ref}" =~ ^0{40}$ ]]; then
  selected_base_ref=""
  if [[ "${GITHUB_EVENT_NAME:-}" == "push" ]]; then
    printf 'Push event has no usable previous commit for proto comparison.\n' >&2
    exit 1
  fi
fi

if [[ -n "${selected_base_ref}" ]]; then
  if [[ ! "${selected_base_ref}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    printf 'DROIDMATCH_PROTO_BASE_REF must be a full commit SHA.\n' >&2
    exit 1
  fi
  if ! git cat-file -e "${selected_base_ref}^{commit}" 2>/dev/null; then
    printf 'Proto base commit is unavailable; fetch full history before checking.\n' >&2
    exit 1
  fi
  if git cat-file -e \
    "${selected_base_ref}:proto/v1/compatibility-baseline.json" \
    2>/dev/null; then
    git show \
      "${selected_base_ref}:proto/v1/compatibility-baseline.json" \
      > "${tmp_dir}/previous-compatibility-baseline.json"
    comparison_arguments+=(
      --previous-baseline "${tmp_dir}/previous-compatibility-baseline.json"
    )
  else
    printf 'Proto baseline bootstrap: the selected base commit has no baseline.\n'
    printf '中文：Protobuf 基线首次引入：所选基准提交尚无兼容性基线。\n'
  fi
fi

python3 tools/check_proto_compatibility.py "${comparison_arguments[@]}"

printf 'Proto check passed with %s.\n' "$("${protoc_bin}" --version)"
