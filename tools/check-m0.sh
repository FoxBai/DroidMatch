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
  "fixtures/m1-runs/legacy-v0.sha256"
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
  "tools/test-check-mac-app-bundle.py"
  "tools/mac-bundle-check-retry.sh"
  "tools/test-mac-bundle-check-retry.sh"
  "tools/check-third-party-notices.py"
  "tools/check-no-external-model-workflow.py"
  "tools/test-check-no-external-model-workflow.py"
  "tools/check-ci-action-pins.py"
  "tools/check-m1-skeleton.sh"
  "tools/check-m1-run-logs.sh"
  "tools/m1-run-log-common.sh"
  "tools/m1-run-log-profile.sh"
  "tools/test-check-m1-run-logs.sh"
  "tools/test-m1-throughput-profile-validator.sh"
  "tools/check-live-doc-truth.py"
  "tools/check-maintainer-contract.py"
  "tools/check-product-help.py"
  "tools/test-check-product-help.py"
  "tools/check-product-runtime-freshness.py"
  "tools/test-check-product-runtime-freshness.py"
  "tools/check-media-upload-contract.py"
  "tools/test-check-media-upload-contract.py"
  "tools/test-check-maintainer-contract.py"
  "tools/check-localizations.py"
  "tools/check-proto.sh"
  "tools/check-release-readiness.sh"
  "tools/test-release-readiness.sh"
  "tools/test-build-mac-app.sh"
  "tools/test-build-mac-app-owner-identity.sh"
  "tools/mac-app-publication-recovery.sh"
  "tools/process_instance_identity.py"
  "tools/test-process-instance-identity.py"
  "tools/atomic_rename.py"
  "tools/test-atomic-rename.py"
  "tools/build-mac-icon.sh"
  "tools/package-mac-icon.py"
  "tools/test-package-mac-icon.py"
  "tools/swift-build-compat.sh"
  "tools/test-build-mac-dmg.sh"
  "tools/test-build-mac-dmg-owner-identity.sh"
  "tools/test-run-swift-tests.sh"
  "tools/run-command-with-timeout.py"
  "tools/test-run-command-with-timeout.py"
  "tools/push-main-with-gates.sh"
  "tools/test-push-main-with-gates.sh"
  "tools/generate-swift-proto.sh"
  "tools/bootstrap-swift-protobuf.sh"
  "tools/test-bootstrap-swift-protobuf.sh"
  "tools/test-generate-swift-proto.sh"
  "tools/m1-fault-proxy.py"
  "tools/m1-output-redaction.sh"
  "tools/m1-device-smoke-usage.sh"
  "tools/m1-device-smoke-options.sh"
  "tools/m1-device-smoke-device-control.sh"
  "tools/m1-device-smoke-evidence.sh"
  "tools/m1-device-smoke-app-sandbox.sh"
  "tools/m1-device-smoke-result-log.sh"
  "tools/m1-device-smoke-cleanup.sh"
  "tools/run-m1-device-smoke.sh"
  "tools/run-m1-throughput-gate.sh"
  "tools/test-run-m1-throughput-gate.sh"
  "tools/quick-test-scenarios.sh"
  "tools/test-quick-test-scenarios.sh"
  "tools/run-large-directory-device-smoke.sh"
  "tools/test-large-directory-device-smoke.sh"
  "tools/test-run-m1-device-smoke-redaction.sh"
  "tools/run-download-unplug-device-smoke.sh"
  "tools/test-download-unplug-device-smoke.sh"
  "tools/product-device-visible.swift"
  "tools/product-device-visibility-policy.swift"
  "tools/test-product-device-visibility-policy.swift"
  "tools/run-product-usb-insertion-smoke.sh"
  "tools/test-product-usb-insertion-smoke.sh"
  "tools/check-product-usb-insertion-logs.sh"
  "tools/test-product-usb-insertion-logs.sh"
  "tools/test-check-live-doc-truth.py"
  "fixtures/product-usb-insertion/README.md"
)

for file in "${required_files[@]}"; do
  if [[ ! -s "${file}" ]]; then
    printf 'missing or empty required file: %s\n' "${file}" >&2
    exit 1
  fi
done

python3 tools/check-maintainer-contract.py
python3 tools/check-product-help.py
python3 tools/test-check-product-help.py
python3 tools/check-product-runtime-freshness.py
python3 tools/test-check-product-runtime-freshness.py
python3 tools/test-check-mac-app-not-running.py
python3 tools/check-media-upload-contract.py
python3 tools/test-check-media-upload-contract.py
python3 tools/test-check-maintainer-contract.py
python3 tools/test-check-live-doc-truth.py
python3 tools/check-live-doc-truth.py
python3 tools/test-check-source-size.py
python3 tools/check-localizations.py
python3 tools/check-third-party-notices.py
python3 tools/test-check-no-external-model-workflow.py
python3 tools/check-no-external-model-workflow.py
python3 tools/check-ci-action-pins.py
python3 tools/test-check-mac-app-bundle.py
bash tools/test-mac-bundle-check-retry.sh
bash tools/test-release-readiness.sh
python3 tools/test-package-mac-icon.py
python3 tools/test-process-instance-identity.py
python3 tools/test-atomic-rename.py
bash tools/test-build-mac-app.sh
bash tools/test-build-mac-dmg.sh
bash tools/test-run-swift-tests.sh
python3 tools/test-run-command-with-timeout.py
bash tools/test-bootstrap-swift-protobuf.sh
bash tools/test-generate-swift-proto.sh
bash tools/test-push-main-with-gates.sh
bash tools/test-android-keystore-instrumentation.sh
bash tools/test-quick-test-scenarios.sh
bash tools/test-download-unplug-device-smoke.sh
bash tools/test-large-directory-device-smoke.sh
bash tools/test-check-m1-run-logs.sh
bash tools/test-run-m1-device-smoke-redaction.sh
bash tools/test-run-m1-throughput-gate.sh
bash tools/test-product-usb-insertion-smoke.sh
bash tools/test-product-usb-insertion-logs.sh
bash tools/check-product-usb-insertion-logs.sh

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
