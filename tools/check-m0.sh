#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

required_files=(
  "README.md"
  "LICENSE"
  "CONTRIBUTING.md"
  "SECURITY.md"
  ".github/CODEOWNERS"
  "docs/m0-closeout.md"
  "docs/m0-checklist.md"
  "docs/m1-device-matrix.md"
  "docs/path-model.md"
  "docs/product-scope.md"
  "docs/protocol-runtime.md"
  "docs/feature-matrix.md"
  "docs/handshaker-relationship.md"
  "docs/security-model.md"
  "docs/architecture.md"
  "docs/protocol.md"
  "docs/transport-usb.md"
  "docs/android-permissions.md"
  "docs/diagnostics.md"
  "docs/decision-log.md"
  "android/settings.gradle"
  "android/build.gradle"
  "android/gradle.properties"
  "android/gradlew"
  "android/gradlew.bat"
  "android/gradle/wrapper/gradle-wrapper.jar"
  "android/gradle/wrapper/gradle-wrapper.properties"
  "android/app/build.gradle"
  "fixtures/m1-runs/README.md"
  "proto/v1/error.proto"
  "proto/v1/rpc.proto"
  "proto/v1/session.proto"
  "proto/v1/device.proto"
  "proto/v1/file.proto"
  "proto/v1/transfer.proto"
  "mac/Package.resolved"
  "mac/Sources/DroidMatchCore/Generated/v1/error.pb.swift"
  "mac/Sources/DroidMatchCore/Generated/v1/rpc.pb.swift"
  "mac/Sources/DroidMatchCore/Generated/v1/session.pb.swift"
  "mac/Sources/DroidMatchCore/Generated/v1/device.pb.swift"
  "mac/Sources/DroidMatchCore/Generated/v1/file.pb.swift"
  "mac/Sources/DroidMatchCore/Generated/v1/transfer.pb.swift"
  "tools/check-m0.sh"
  "tools/check-m1-skeleton.sh"
  "tools/check-proto.sh"
  "tools/generate-swift-proto.sh"
  "tools/run-m1-device-smoke.sh"
)

for file in "${required_files[@]}"; do
  if [[ ! -s "${file}" ]]; then
    printf 'missing or empty required file: %s\n' "${file}" >&2
    exit 1
  fi
done

for script in tools/*.sh; do
  if [[ ! -x "${script}" ]]; then
    printf 'tool script must be executable: %s\n' "${script}" >&2
    exit 1
  fi
done

if grep -n '^- \[ \]' docs/m0-checklist.md; then
  printf 'M0 checklist still has unchecked items.\n' >&2
  exit 1
fi

printf 'M0 gate check passed.\n'
