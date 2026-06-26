#!/usr/bin/env bash

set -euo pipefail

required_files=(
  "README.md"
  "docs/m0-checklist.md"
  "docs/product-scope.md"
  "docs/feature-matrix.md"
  "docs/architecture.md"
  "docs/protocol.md"
  "docs/transport-usb.md"
  "docs/android-permissions.md"
  "docs/diagnostics.md"
  "docs/decision-log.md"
  "proto/v1/error.proto"
  "proto/v1/session.proto"
  "proto/v1/device.proto"
  "proto/v1/file.proto"
  "proto/v1/transfer.proto"
)

for file in "${required_files[@]}"; do
  if [[ ! -s "${file}" ]]; then
    printf 'missing or empty required file: %s\n' "${file}" >&2
    exit 1
  fi
done

printf 'M0 scaffold check passed.\n'

