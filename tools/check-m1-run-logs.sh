#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

shopt -s nullglob
logs=(fixtures/m1-runs/*.md)

required_fields=(
  "date:"
  "device slot:"
  "manufacturer/model:"
  "android version/api:"
  "build channel:"
  "transport:"
  "handshake attempts:"
  "visible time:"
  "first list time:"
  "100MB download:"
  "100MB upload:"
  "resume result:"
  "permission cases:"
  "diagnostics bundle:"
  "notes:"
)

checked=0
for log in "${logs[@]}"; do
  [[ "${log}" == "fixtures/m1-runs/README.md" ]] && continue
  checked=$((checked + 1))

  if [[ ! -s "${log}" ]]; then
    printf 'empty M1 run log: %s\n' "${log}" >&2
    exit 1
  fi
  if ! head -n 1 "${log}" | grep -q '^# '; then
    printf 'M1 run log must start with a markdown title: %s\n' "${log}" >&2
    exit 1
  fi
  for field in "${required_fields[@]}"; do
    if ! grep -q "^${field}" "${log}"; then
      printf 'M1 run log missing field "%s": %s\n' "${field}" "${log}" >&2
      exit 1
    fi
  done

  if grep -nE '/Users/|content://|Authorization:|authorization:|Bearer[[:space:]]+|access[_-]?token|refresh[_-]?token|password|secret' "${log}"; then
    printf 'M1 run log contains sensitive-looking content: %s\n' "${log}" >&2
    exit 1
  fi
  if grep -nE 'serial[=:][[:space:]]*[^<[:space:]][^[:space:]]{5,}' "${log}"; then
    printf 'M1 run log appears to contain an unredacted serial: %s\n' "${log}" >&2
    exit 1
  fi
done

printf 'M1 run log check passed (%d logs).\n' "${checked}"
