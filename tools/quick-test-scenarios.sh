#!/usr/bin/env bash
# Quick test scenarios for M1 validation
# Usage: tools/quick-test-scenarios.sh <scenario> [--serial <serial>]

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

scenario="${1:-help}"
serial=""
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      serial="${2:?missing value for --serial}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

serial_arg=""
if [[ -n "${serial}" ]]; then
  serial_arg="--serial ${serial}"
fi

run_scenario() {
  local name="$1"
  shift
  echo "=========================================="
  echo "Running scenario: ${name}"
  echo "=========================================="
  bash "${repo_root}/tools/run-m1-device-smoke.sh" ${serial_arg} "$@"
  echo ""
  echo "✅ Scenario '${name}' completed"
  echo ""
}

case "${scenario}" in
  help|--help|-h)
    cat <<'HELP'
Quick M1 Test Scenarios

Usage:
  tools/quick-test-scenarios.sh <scenario> [--serial <serial>]

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
      Runs complete M1 validation matrix on one device.
      Includes: stability, throughput, resume, retry, permissions.
      Takes ~10 minutes.

Examples:
  # Quick smoke test
  tools/quick-test-scenarios.sh basic-smoke

  # Download throughput on specific device
  tools/quick-test-scenarios.sh download-100mb-throughput --serial ABC123

  # Full matrix
  tools/quick-test-scenarios.sh full-matrix --serial ABC123

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
    if [[ ! -f /tmp/droidmatch-100mb-upload.bin ]]; then
      echo "Creating /tmp/droidmatch-100mb-upload.bin (100 MiB)..."
      dd if=/dev/zero of=/tmp/droidmatch-100mb-upload.bin bs=1048576 count=100 2>/dev/null
    fi
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
    if [[ ! -f /tmp/droidmatch-100mb-upload.bin ]]; then
      echo "Creating /tmp/droidmatch-100mb-upload.bin (100 MiB)..."
      dd if=/dev/zero of=/tmp/droidmatch-100mb-upload.bin bs=1048576 count=100 2>/dev/null
    fi
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
      --chunk-size-bytes 1048576
    ;;

  upload-retry-fault)
    if [[ ! -f /tmp/droidmatch-100mb-upload.bin ]]; then
      echo "Creating /tmp/droidmatch-100mb-upload.bin (100 MiB)..."
      dd if=/dev/zero of=/tmp/droidmatch-100mb-upload.bin bs=1048576 count=100 2>/dev/null
    fi
    run_scenario "upload-retry-fault" \
      --upload-source /tmp/droidmatch-100mb-upload.bin \
      --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
      --upload-resume-check \
      --upload-retry-fault-check \
      --chunk-size-bytes 1048576 \
      --cleanup-upload-destination
    ;;

  upload-ack-loss)
    if [[ ! -f /tmp/droidmatch-10mb-upload.bin ]]; then
      echo "Creating /tmp/droidmatch-10mb-upload.bin (10 MiB)..."
      dd if=/dev/zero of=/tmp/droidmatch-10mb-upload.bin bs=1048576 count=10 2>/dev/null
    fi
    run_scenario "upload-ack-loss" \
      --upload-source /tmp/droidmatch-10mb-upload.bin \
      --upload-destination-path dm://app-sandbox/dm-10mb-upload-ack-loss.bin \
      --upload-resume-check \
      --upload-retry-ack-loss-check \
      --chunk-size-bytes 1048576 \
      --cleanup-upload-destination
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
    bash "${repo_root}/tools/run-m1-device-smoke.sh" ${serial_arg} \
      --list-expect-error-path dm://saf-missing-root-12345/ \
      --list-expect-error-code notFound \
      --no-result-log
    echo ""
    echo "Test 2: Download missing file"
    bash "${repo_root}/tools/run-m1-device-smoke.sh" ${serial_arg} \
      --download-open-expect-error-path dm://app-sandbox/nonexistent-file.bin \
      --download-open-expect-error-code notFound \
      --no-result-log
    echo ""
    echo "✅ Scenario 'expected-errors' completed"
    echo ""
    ;;

  full-matrix)
    echo "=========================================="
    echo "Running Full M1 Validation Matrix"
    echo "=========================================="
    echo ""
    echo "This will run all M1 exit criteria tests."
    echo "Estimated time: ~10 minutes"
    echo ""
    
    # Prepare test files
    if [[ ! -f /tmp/droidmatch-100mb-upload.bin ]]; then
      echo "Creating test files..."
      dd if=/dev/zero of=/tmp/droidmatch-100mb-upload.bin bs=1048576 count=100 2>/dev/null
      dd if=/dev/zero of=/tmp/droidmatch-10mb-upload.bin bs=1048576 count=10 2>/dev/null
      echo ""
    fi
    
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
      --chunk-size-bytes 1048576
    
    run_scenario "7. Upload Fault Recovery" \
      --upload-source /tmp/droidmatch-100mb-upload.bin \
      --upload-destination-path dm://app-sandbox/dm-100mb-upload-fault.bin \
      --upload-resume-check \
      --upload-retry-fault-check \
      --chunk-size-bytes 1048576 \
      --cleanup-upload-destination
    
    run_scenario "8. Upload ACK Loss" \
      --upload-source /tmp/droidmatch-10mb-upload.bin \
      --upload-destination-path dm://app-sandbox/dm-10mb-upload-ack-loss.bin \
      --upload-resume-check \
      --upload-retry-ack-loss-check \
      --chunk-size-bytes 1048576 \
      --cleanup-upload-destination
    
    run_scenario "9. Permission Revocation" \
      --media-permission-revoked-check \
      --list-path dm://media-images/
    
    echo "=========================================="
    echo "Full M1 Matrix Completed"
    echo "=========================================="
    echo ""
    echo "All tests passed. Review logs in fixtures/m1-runs/"
    echo ""
    ;;

  *)
    echo "Unknown scenario: ${scenario}" >&2
    echo "Run 'tools/quick-test-scenarios.sh help' for available scenarios" >&2
    exit 2
    ;;
esac
