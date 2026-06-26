#!/usr/bin/env bash

set -euo pipefail

required_files=(
  "README.md"
  "docs/m0-checklist.md"
  "docs/m1-device-matrix.md"
  "docs/product-scope.md"
  "docs/feature-matrix.md"
  "docs/handshaker-relationship.md"
  "docs/architecture.md"
  "docs/protocol.md"
  "docs/transport-usb.md"
  "docs/android-permissions.md"
  "docs/diagnostics.md"
  "docs/decision-log.md"
  "proto/v1/error.proto"
  "proto/v1/rpc.proto"
  "proto/v1/session.proto"
  "proto/v1/device.proto"
  "proto/v1/file.proto"
  "proto/v1/transfer.proto"
  "tools/check-m0.sh"
  "tools/check-proto.sh"
)

for file in "${required_files[@]}"; do
  if [[ ! -s "${file}" ]]; then
    printf 'missing or empty required file: %s\n' "${file}" >&2
    exit 1
  fi
done

printf 'M0 scaffold check passed.\n'
