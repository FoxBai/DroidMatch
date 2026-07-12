#!/usr/bin/env bash
# Quick test scenarios for M1 validation
# Usage: tools/quick-test-scenarios.sh <scenario> [--serial <serial>] [--adb <path>] [--device-slot <slot>] [--max-list-ms <ms>] [--max-retry-attempts <count>]

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

scenario="${1:-help}"
serial=""
adb_bin="${DROIDMATCH_ADB:-}"
device_slot="${DROIDMATCH_DEVICE_SLOT:-}"
notes="${DROIDMATCH_RUN_NOTES:-}"
max_list_ms="${DROIDMATCH_MAX_LIST_MS:-}"
max_retry_attempts="${DROIDMATCH_MAX_RETRY_ATTEMPTS:-}"
retry_backoff_ms="${DROIDMATCH_RETRY_BACKOFF_MS:-}"
reuse_successful_build=false
smoke_build_completed=false
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      serial="${2:?missing value for --serial}"
      shift 2
      ;;
    --adb)
      adb_bin="${2:?missing value for --adb}"
      shift 2
      ;;
    --device-slot)
      device_slot="${2:?missing value for --device-slot}"
      shift 2
      ;;
    --notes)
      notes="${2:?missing value for --notes}"
      shift 2
      ;;
    --max-list-ms)
      max_list_ms="${2:?missing value for --max-list-ms}"
      shift 2
      ;;
    --max-retry-attempts)
      max_retry_attempts="${2:?missing value for --max-retry-attempts}"
      shift 2
      ;;
    --retry-backoff-ms)
      retry_backoff_ms="${2:?missing value for --retry-backoff-ms}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

serial_args=()
if [[ -n "${serial}" ]]; then
  serial_args=(--serial "${serial}")
fi

metadata_args=()
if [[ -n "${device_slot}" ]]; then
  metadata_args+=(--device-slot "${device_slot}")
fi
if [[ -n "${notes}" ]]; then
  metadata_args+=(--notes "${notes}")
fi
if [[ -n "${max_list_ms}" ]]; then
  metadata_args+=(--max-list-ms "${max_list_ms}")
fi

retry_policy_args=()
if [[ -n "${max_retry_attempts}" ]]; then
  retry_policy_args+=(--max-retry-attempts "${max_retry_attempts}")
fi
if [[ -n "${retry_backoff_ms}" ]]; then
  retry_policy_args+=(--retry-backoff-ms "${retry_backoff_ms}")
fi

if [[ -n "${adb_bin}" && "${adb_bin}" == */* && ! -x "${adb_bin}" ]]; then
  echo "ADB executable not found or not executable: ${adb_bin}" >&2
  exit 2
fi

run_smoke() {
  if [[ "${reuse_successful_build}" == true && "${smoke_build_completed}" == true ]]; then
    set -- --skip-build "$@"
  fi

  if [[ -n "${adb_bin}" ]]; then
    DROIDMATCH_ADB="${adb_bin}" bash "${repo_root}/tools/run-m1-device-smoke.sh" "${serial_args[@]}" "${metadata_args[@]}" "$@" || return $?
  else
    bash "${repo_root}/tools/run-m1-device-smoke.sh" "${serial_args[@]}" "${metadata_args[@]}" "$@" || return $?
  fi

  if [[ "${reuse_successful_build}" == true ]]; then
    smoke_build_completed=true
  fi
}

ensure_zero_file() {
  local path="$1"
  local mib="$2"
  if [[ ! -f "${path}" ]]; then
    echo "Creating ${path} (${mib} MiB)..."
    dd if=/dev/zero of="${path}" bs=1048576 count="${mib}" 2>/dev/null
  fi
}

run_scenario() {
  local name="$1"
  shift
  echo "=========================================="
  echo "Running scenario: ${name}"
  echo "=========================================="
  run_smoke "$@"
  echo ""
  echo "✅ Scenario '${name}' completed"
  echo ""
}

case "${scenario}" in
  help|--help|-h)
    cat <<'HELP'
Quick Core ADB Test Scenarios

Usage:
  tools/quick-test-scenarios.sh <scenario> [--serial <serial>] [--adb <path>] [--device-slot <slot>] [--max-list-ms <ms>] [--max-retry-attempts <count>]

Options:
  --serial <serial>
      adb device serial. Use when multiple devices are connected.

  --adb <path>
      adb executable path. Overrides DROIDMATCH_ADB; otherwise the smoke script
      auto-discovers $ANDROID_HOME, $ANDROID_SDK_ROOT, or ~/Library/Android/sdk.

  --device-slot <slot>
      M1 matrix slot label to write into result logs.

  --notes <text>
      Notes to write into result logs.

  --max-list-ms <ms>
      Optional maximum elapsed time for timed list scenarios.

  --max-retry-attempts <count>
      Optional extra reconnect attempts for retry/fault scenarios only.

  --retry-backoff-ms <ms>
      Optional base backoff for retry/fault scenarios.

Available scenarios:

  basic-smoke
      Quick smoke test: handshake, heartbeat, device info, roots listing.
      Takes ~5 seconds.

  handshake-stability
      20 handshake attempts with 19+ required passes.
      Validates connection reliability.
      Takes ~2 minutes.

  download-100mb-throughput
      Prepares 100MB file, downloads with 1MiB chunks, asserts ≥20 MiB/s.
      Validates M1 download throughput requirement.
      Takes ~30 seconds.

  upload-100mb-throughput
      Uploads 100MB file with 1MiB chunks, asserts ≥20 MiB/s, cleans up.
      Requires: /tmp/droidmatch-100mb-upload.bin
      Validates M1 upload throughput requirement.
      Takes ~30 seconds.

  download-resume-100mb
      Prepares 100MB file, partial download, then resume.
      Validates resume with source fingerprint.
      Takes ~1 minute.

  upload-resume-100mb
      Uploads 100MB partially, then resumes.
      Requires: /tmp/droidmatch-100mb-upload.bin
      Validates app-sandbox upload resume.
      Takes ~1 minute.

  download-retry-fault
      Injects transport loss during 100MB download, requires recovery.
      Validates sidecar-backed retry with recovered=true.
      Takes ~1 minute.

  upload-retry-fault
      Injects transport loss during 100MB upload, requires recovery.
      Requires: /tmp/droidmatch-100mb-upload.bin
      Validates sidecar-backed retry with recovered=true.
      Takes ~1 minute.

  upload-ack-loss
      Simulates ACK loss during upload, validates truncate/replay.
      Requires: /tmp/droidmatch-10mb-upload.bin
      Validates ACK-loss tolerance window.
      Takes ~30 seconds.

  permission-revocation
      Revokes media permissions, requires permissionRequired error.
      Restores permissions after test.
      Takes ~30 seconds.

  mediastore-fresh-upload
      Uploads JPEG to MediaStore images, verifies fresh-only behavior.
      Requires: /tmp/droidmatch-upload.jpg
      Cleans up after test.
      Takes ~10 seconds.

  expected-errors
      Tests stable error boundaries: missing files, unauthorized roots.
      Validates protocol error mapping.
      Takes ~15 seconds.

  full-matrix
      Runs the automated core ADB matrix on one device.
      Includes: stability, throughput, resume, retry, permissions.
      Excludes complementary attended product discovery/SAS approval/SAF
      authorization and physical-unplug runs.
      Takes ~10 minutes.

Examples:
  # Quick smoke test
  tools/quick-test-scenarios.sh basic-smoke

  # Download throughput on specific device
  tools/quick-test-scenarios.sh download-100mb-throughput --serial ABC123

  # Automated core ADB matrix (compatibility scenario name)
  tools/quick-test-scenarios.sh full-matrix --serial ABC123

  # adb is installed but not in PATH
  tools/quick-test-scenarios.sh handshake-stability \
    --adb "$HOME/Library/Android/sdk/platform-tools/adb" \
    --serial ABC123 \
    --device-slot D \
    --max-list-ms 1000

  # Recovery queue with multiple reconnect attempts
  tools/quick-test-scenarios.sh download-retry-fault \
    --serial ABC123 \
    --device-slot D \
    --max-retry-attempts 3 \
    --retry-backoff-ms 100

Notes:
  - Some scenarios require pre-created test files (see scenario descriptions)
  - Use --serial when multiple devices are connected
  - All tests write logs to fixtures/m1-runs/ by default
HELP
    exit 0
    ;;

  basic-smoke)
    run_scenario "basic-smoke" \
      --list-path dm://media-images/
    ;;

  handshake-stability)
    run_scenario "handshake-stability" \
      --handshake-attempts 20 \
      --min-handshake-passes 19 \
      --list-path dm://media-images/
    ;;

  download-100mb-throughput)
    run_scenario "download-100mb-throughput" \
      --prepare-app-sandbox-file dm-100mb-zero.bin \
      --chunk-size-bytes 1048576 \
      --min-download-mib-per-second 20
    ;;

  upload-100mb-throughput)
    ensure_zero_file /tmp/droidmatch-100mb-upload.bin 100
    run_scenario "upload-100mb-throughput" \
      --upload-source /tmp/droidmatch-100mb-upload.bin \
      --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
      --min-upload-bytes 104857600 \
      --chunk-size-bytes 1048576 \
      --min-upload-mib-per-second 20 \
      --cleanup-upload-destination
    ;;

  download-resume-100mb)
    run_scenario "download-resume-100mb" \
      --prepare-app-sandbox-file dm-100mb-zero.bin \
      --resume-check \
      --chunk-size-bytes 1048576
    ;;

  upload-resume-100mb)
    ensure_zero_file /tmp/droidmatch-100mb-upload.bin 100
    run_scenario "upload-resume-100mb" \
      --upload-source /tmp/droidmatch-100mb-upload.bin \
      --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
      --upload-resume-check \
      --upload-partial-bytes 1048576 \
      --chunk-size-bytes 1048576 \
      --cleanup-upload-destination
    ;;

  download-retry-fault)
    run_scenario "download-retry-fault" \
      --prepare-app-sandbox-file dm-100mb-zero.bin \
      --resume-check \
      --download-retry-fault-check \
      --chunk-size-bytes 1048576 \
      "${retry_policy_args[@]}"
    ;;

  upload-retry-fault)
    ensure_zero_file /tmp/droidmatch-100mb-upload.bin 100
    run_scenario "upload-retry-fault" \
      --upload-source /tmp/droidmatch-100mb-upload.bin \
      --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
      --upload-resume-check \
      --upload-retry-fault-check \
      --chunk-size-bytes 1048576 \
      --cleanup-upload-destination \
      "${retry_policy_args[@]}"
    ;;

  upload-ack-loss)
    ensure_zero_file /tmp/droidmatch-10mb-upload.bin 10
    run_scenario "upload-ack-loss" \
      --upload-source /tmp/droidmatch-10mb-upload.bin \
      --upload-destination-path dm://app-sandbox/dm-10mb-upload-ack-loss.bin \
      --upload-resume-check \
      --upload-retry-ack-loss-check \
      --chunk-size-bytes 1048576 \
      --cleanup-upload-destination \
      "${retry_policy_args[@]}"
    ;;

  permission-revocation)
    run_scenario "permission-revocation" \
      --media-permission-revoked-check \
      --list-path dm://media-images/
    ;;

  mediastore-fresh-upload)
    if [[ ! -f /tmp/droidmatch-upload.jpg ]]; then
      echo "Error: /tmp/droidmatch-upload.jpg not found" >&2
      echo "Create a test JPEG file first:" >&2
      echo "  cp /path/to/test-image.jpg /tmp/droidmatch-upload.jpg" >&2
      exit 1
    fi
    run_scenario "mediastore-fresh-upload" \
      --upload-source /tmp/droidmatch-upload.jpg \
      --upload-destination-path dm://media-images/droidmatch-test-$(date +%s).jpg \
      --upload-resume-unsupported-check \
      --min-upload-bytes 1 \
      --cleanup-upload-destination
    ;;

  expected-errors)
    echo "=========================================="
    echo "Running scenario: expected-errors"
    echo "=========================================="
    echo ""
    echo "Test 1: List missing SAF root"
    run_smoke \
      --list-expect-error-path dm://saf-missing-root-12345/ \
      --list-expect-error-code notFound \
      --no-result-log
    echo ""
    echo "Test 2: Download missing file"
    run_smoke \
      --download-open-expect-error-path dm://app-sandbox/nonexistent-file.bin \
      --download-open-expect-error-code notFound \
      --no-result-log
    echo ""
    echo "✅ Scenario 'expected-errors' completed"
    echo ""
    ;;

  full-matrix)
    echo "=========================================="
    echo "Running Automated Core ADB Matrix"
    echo "=========================================="
    echo ""
    echo "This runs the scripted core ADB scenarios only."
    echo "Complementary attended product discovery/SAS approval/SAF authorization"
    echo "and physical-unplug runs are not included."
    echo "Estimated time: ~10 minutes"
    echo ""

    ensure_zero_file /tmp/droidmatch-100mb-upload.bin 100
    ensure_zero_file /tmp/droidmatch-10mb-upload.bin 10
    echo ""

    # This compatibility scenario runs in one process against one set of build outputs.
    # Only reuse them after the first smoke invocation has completed successfully.
    # 该兼容场景在同一进程中复用构建产物，但仅限首轮 smoke 成功之后。
    reuse_successful_build=true

    run_scenario "1. Handshake Stability" \
      --handshake-attempts 20 \
      --min-handshake-passes 19 \
      --list-path dm://media-images/

    run_scenario "2. Download Throughput" \
      --prepare-app-sandbox-file dm-100mb-zero.bin \
      --chunk-size-bytes 1048576 \
      --min-download-mib-per-second 20

    run_scenario "3. Upload Throughput" \
      --upload-source /tmp/droidmatch-100mb-upload.bin \
      --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
      --min-upload-bytes 104857600 \
      --chunk-size-bytes 1048576 \
      --min-upload-mib-per-second 20 \
      --cleanup-upload-destination

    run_scenario "4. Download Resume" \
      --prepare-app-sandbox-file dm-100mb-zero.bin \
      --resume-check \
      --chunk-size-bytes 1048576

    run_scenario "5. Upload Resume" \
      --upload-source /tmp/droidmatch-100mb-upload.bin \
      --upload-destination-path dm://app-sandbox/dm-100mb-upload-resume.bin \
      --upload-resume-check \
      --upload-partial-bytes 1048576 \
      --chunk-size-bytes 1048576 \
      --cleanup-upload-destination

    run_scenario "6. Download Fault Recovery" \
      --prepare-app-sandbox-file dm-100mb-zero.bin \
      --resume-check \
      --download-retry-fault-check \
      --chunk-size-bytes 1048576 \
      "${retry_policy_args[@]}"

    run_scenario "7. Upload Fault Recovery" \
      --upload-source /tmp/droidmatch-100mb-upload.bin \
      --upload-destination-path dm://app-sandbox/dm-100mb-upload-fault.bin \
      --upload-resume-check \
      --upload-retry-fault-check \
      --chunk-size-bytes 1048576 \
      --cleanup-upload-destination \
      "${retry_policy_args[@]}"

    run_scenario "8. Upload ACK Loss" \
      --upload-source /tmp/droidmatch-10mb-upload.bin \
      --upload-destination-path dm://app-sandbox/dm-10mb-upload-ack-loss.bin \
      --upload-resume-check \
      --upload-retry-ack-loss-check \
      --chunk-size-bytes 1048576 \
      --cleanup-upload-destination \
      "${retry_policy_args[@]}"

    run_scenario "9. Permission Revocation" \
      --media-permission-revoked-check \
      --list-path dm://media-images/

    echo "=========================================="
    echo "Automated Core ADB Matrix Completed"
    echo "=========================================="
    echo ""
    echo "Core ADB scenarios passed. Review logs in fixtures/m1-runs/"
    echo ""
    ;;

  *)
    echo "Unknown scenario: ${scenario}" >&2
    echo "Run 'tools/quick-test-scenarios.sh help' for available scenarios" >&2
    exit 2
    ;;
esac
