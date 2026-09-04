#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/droidmatch-icon-renderer.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

blocked_parent="${test_root}/not-a-directory"
output_path="${blocked_parent}/DroidMatch.png"
stdout_path="${test_root}/stdout"
stderr_path="${test_root}/stderr"
touch "${blocked_parent}"

set +e
swift "${repo_root}/tools/render-mac-icon.swift" "${output_path}" \
  >"${stdout_path}" 2>"${stderr_path}"
status=$?
set -e

if [[ "${status}" -ne 1 ]]; then
  printf 'icon renderer write failure must exit 1\n' >&2
  exit 1
fi
if [[ -s "${stdout_path}" ]]; then
  printf 'icon renderer write failure must not use stdout\n' >&2
  exit 1
fi
expected_error=$'DroidMatch icon output could not be written.\nDroidMatch 图标输出无法写入。'
if [[ "$(<"${stderr_path}")" != "${expected_error}" ]]; then
  printf 'icon renderer write failure must use the fixed bilingual error\n' >&2
  exit 1
fi
if grep -Eiq 'fatal error|stack dump|stack trace|backtrace' "${stderr_path}" \
    || grep -Fq "${output_path}" "${stderr_path}"; then
  printf 'icon renderer write failure leaked a path or runtime crash detail\n' >&2
  exit 1
fi
if [[ -e "${output_path}" || -L "${output_path}" ]]; then
  printf 'icon renderer write failure unexpectedly published output\n' >&2
  exit 1
fi

printf 'Mac icon renderer failure-boundary test passed.\n'
printf '中文：Mac 图标渲染器失败边界测试通过。\n'
