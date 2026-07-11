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
  "docs/maintainer-runbook.md"
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
  "android/gradle/verification-metadata.xml"
  "android/app/build.gradle"
  "fixtures/m1-runs/README.md"
  "proto/v1/error.proto"
  "proto/v1/rpc.proto"
  "proto/v1/session.proto"
  "proto/v1/device.proto"
  "proto/v1/file.proto"
  "proto/v1/transfer.proto"
  "mac/Package.resolved"
  "mac/App/PrivacyInfo.xcprivacy"
  "third_party/README.md"
  "third_party/mac/THIRD-PARTY-NOTICES.md"
  "third_party/mac/swift-protobuf-LICENSE.txt"
  "third_party/android/THIRD-PARTY-NOTICES.md"
  "third_party/android/protobuf-LICENSE.txt"
  "mac/Sources/DroidMatchCore/Generated/v1/error.pb.swift"
  "mac/Sources/DroidMatchCore/Generated/v1/rpc.pb.swift"
  "mac/Sources/DroidMatchCore/Generated/v1/session.pb.swift"
  "mac/Sources/DroidMatchCore/Generated/v1/device.pb.swift"
  "mac/Sources/DroidMatchCore/Generated/v1/file.pb.swift"
  "mac/Sources/DroidMatchCore/Generated/v1/transfer.pb.swift"
  "tools/check-m0.sh"
  "tools/check-android-release-manifest.py"
  "tools/check-mac-app-bundle.py"
  "tools/check-third-party-notices.py"
  "tools/check-ci-action-pins.py"
  "tools/check-m1-skeleton.sh"
  "tools/check-m1-run-logs.sh"
  "tools/check-maintainer-contract.py"
  "tools/check-localizations.py"
  "tools/check-proto.sh"
  "tools/check-release-readiness.sh"
  "tools/test-release-readiness.sh"
  "tools/generate-swift-proto.sh"
  "tools/m1-fault-proxy.py"
  "tools/run-m1-device-smoke.sh"
)

for file in "${required_files[@]}"; do
  if [[ ! -s "${file}" ]]; then
    printf 'missing or empty required file: %s\n' "${file}" >&2
    exit 1
  fi
done

python3 tools/check-maintainer-contract.py
python3 tools/test-check-source-size.py
python3 tools/check-localizations.py
python3 tools/check-third-party-notices.py
python3 tools/check-ci-action-pins.py
bash tools/test-release-readiness.sh
bash tools/test-android-keystore-instrumentation.sh

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
