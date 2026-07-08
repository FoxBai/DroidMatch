# M1 Testing Guide

This guide provides step-by-step instructions for running M1 device tests that satisfy the exit criteria defined in `docs/m1-device-matrix.md`.

## Prerequisites

- One or more physical Android devices (see device requirements below)
- USB cable connected and device authorized via `adb devices -l`
- Debug APK installed (`tools/run-m1-device-smoke.sh` handles installation automatically)

If `adb` is installed but not on `PATH`, either export `DROIDMATCH_ADB` or pass
`--adb` to the quick scenario wrapper:

```bash
tools/quick-test-scenarios.sh handshake-stability \
  --adb "$HOME/Library/Android/sdk/platform-tools/adb" \
  --serial <serial> \
  --device-slot D \
  --max-list-ms 1000
```

`tools/run-m1-device-smoke.sh` also auto-discovers `adb` from `$ANDROID_HOME`,
`$ANDROID_SDK_ROOT`, or `~/Library/Android/sdk`.

## Device Requirements

M1 requires at least three physical devices covering these slots:

| Slot | Android API | Device Type | Purpose |
|---|---|---|---|
| A | API 26-29 | Legacy storage-era phone | Verify SAF/MediaStore behavior on minimum supported generation |
| C | API 33-35 | Recent mainstream phone | Verify current permission prompts and AOA viability |
| D | API 30+ | Non-Google OEM or tablet | Verify vendor USB behavior and large storage |

Current test coverage:
- ✅ Slot D: NIO N2301, API 34 (multiple tests recorded)
- ⚠️ Slot A: No tests recorded yet
- ⚠️ Slot C: No tests recorded yet (unless NIO N2301 also serves this role)

## Critical M1 Exit Criteria Tests

The same checks are also available through the quick scenario wrapper:

```bash
tools/quick-test-scenarios.sh help
tools/quick-test-scenarios.sh handshake-stability --serial <serial> --device-slot D --max-list-ms 1000
tools/quick-test-scenarios.sh full-matrix --serial <serial> --device-slot D
```

### 1. Handshake Stability Test

**Goal:** Verify ADB handshake succeeds in at least 19 of 20 attempts.

**Command:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --handshake-attempts 20 \
  --min-handshake-passes 19 \
  --list-path dm://media-images/ \
  --max-list-ms 1000
```

**Expected result:**
- Script output shows `handshake attempts: 19-20/20 passed` (at least 19)
- First directory listing reports harness `elapsed_ms` ≤ 1000 (for warm service).
  The result log also records command wall time separately; the gate uses harness
  elapsed time so SwiftPM/process startup overhead does not pollute the device
  latency assertion. If this fails, keep the result log and treat it as a
  latency issue rather than a handshake issue.
- Result log written to `fixtures/m1-runs/`

### 2. Download Throughput Test

**Goal:** Verify 100MB ADB download throughput ≥ 20 MiB/s.

**Setup:**
First, prepare a 100MB test file in the app sandbox:
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-100mb-zero.bin \
  --adb-baseline-download-check \
  --resume-check \
  --chunk-size-bytes 1048576 \
  --min-download-mib-per-second 20
```

**What this does:**
- Creates a 100MiB zero-filled file in `dm://app-sandbox/dm-100mb-zero.bin`
- Records a raw ADB `exec-out run-as ... cat` baseline for the same app-sandbox file
- Runs an intentional partial download, then resumes
- Uses 1MiB chunks (Android's current negotiated max)
- Asserts throughput ≥ 20 MiB/s
- Records `elapsed_ms` and `throughput_mib_per_sec` in the result log

**Expected result:**
- Download completes with `throughput_mib_per_sec` ≥ 20.0
- Result log includes M1 timing metrics and the ADB baseline download throughput
- Test passes on at least 3 required devices

### 3. Upload Throughput Test

**Goal:** Verify 100MB app-sandbox upload throughput.

**Setup:**
Create a local 100MB test file:
```bash
dd if=/dev/zero of=/tmp/droidmatch-100mb-upload.bin bs=1048576 count=100
```

**Command:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --upload-source /tmp/droidmatch-100mb-upload.bin \
  --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
  --min-upload-bytes 104857600 \
  --chunk-size-bytes 1048576 \
  --min-upload-mib-per-second 20 \
  --cleanup-upload-destination
```

**Expected result:**
- Upload completes with `throughput_mib_per_sec` recorded
- Result log includes `elapsed_ms` and `throughput_mib_per_sec`
- Cleanup removes the uploaded file automatically

### 4. Download Resume Test

**Goal:** Verify interrupted download resumes from accepted offset without corruption.

**Command:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-100mb-zero.bin \
  --resume-check \
  --chunk-size-bytes 1048576
```

**What this does:**
- Downloads partially (default: stops after 1 byte)
- Creates sidecar with source fingerprint
- Resumes from the partial offset
- Verifies final file integrity

**Expected result:**
- Partial download leaves `.droidmatch-part` and `.droidmatch-transfer.json`
- Resume command completes successfully with `final_offset=104857600`
- No data corruption

### 5. Upload Resume Test

**Goal:** Verify interrupted app-sandbox upload resumes and commits final destination.

**Command:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --upload-source /tmp/droidmatch-100mb-upload.bin \
  --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
  --upload-resume-check \
  --upload-partial-bytes 1048576 \
  --chunk-size-bytes 1048576 \
  --cleanup-upload-destination
```

**What this does:**
- Uploads partially (stops after 1MiB)
- Creates `.droidmatch-upload-transfer.json` sidecar
- Resumes from the partial offset
- Verifies Android commits the final file

**Expected result:**
- Partial upload creates Android hidden `.droidmatch-upload-part`
- Resume completes with `final_offset=104857600`
- Android replaces destination file atomically

### 6. Transport Loss Recovery Test

**Goal:** Verify sidecar-backed retry reconnects after transport loss.

**Download with fault injection:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-100mb-zero.bin \
  --resume-check \
  --download-retry-fault-check \
  --chunk-size-bytes 1048576 \
  --max-retry-attempts 3 \
  --retry-backoff-ms 100
```

**Upload with fault injection:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --upload-source /tmp/droidmatch-100mb-upload.bin \
  --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
  --upload-resume-check \
  --upload-retry-fault-check \
  --chunk-size-bytes 1048576 \
  --max-retry-attempts 3 \
  --retry-backoff-ms 100 \
  --cleanup-upload-destination
```

**What this does:**
- Routes transfer through `tools/m1-fault-proxy.py`
- Proxy drops first transfer connection after 3rd server frame
- Mac harness detects loss and retries with sidecar; without `--max-retry-attempts`
  it keeps the legacy single retry, while the example above records a
  configurable recovery queue policy in the result log.
- Requires final output contains `recovered=true`

**Expected result:**
- Transfer completes despite injected disconnect
- Harness output includes `recovered=true`
- Demonstrates resilience to cable unplug/replug

### 7. Upload ACK Loss Recovery Test

**Goal:** Verify app-sandbox upload tolerates ACK loss by truncating and replaying.

**Command:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --upload-source /tmp/droidmatch-10mb-upload.bin \
  --upload-destination-path dm://app-sandbox/dm-10mb-upload-ack-loss.bin \
  --upload-resume-check \
  --upload-retry-ack-loss-check \
  --chunk-size-bytes 1048576 \
  --cleanup-upload-destination
```

**What this does:**
- Routes upload through proxy that drops first ACK
- Android writes chunk but Mac doesn't advance offset
- Mac retries, Android truncates partial back to confirmed offset
- Verifies duplicate chunk is accepted

**Expected result:**
- Upload completes despite first ACK loss
- Demonstrates window tolerance between Android write and Mac ACK

### 8. Permission Revocation Test

**Goal:** Verify media root listing returns `permissionRequired` after revocation.

**Command:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --media-permission-revoked-check \
  --list-path dm://media-images/
```

**What this does:**
- Records current media permissions
- Revokes `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, and related permissions
- Requires `list-dir dm://media-images/` to return error code `permissionRequired`
- Restores original permissions after test

**Expected result:**
- ListDir fails with `ERROR_CODE_PERMISSION_REQUIRED` during revocation
- Permissions are restored automatically
- Android endpoint may require restart after restore

**During MediaStore download:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --source-path dm://media-images/media/<id> \
  --destination /tmp/droidmatch-media-revoke-during-download.jpg \
  --chunk-size-bytes 1048576 \
  --media-permission-revoked-during-download-check
```

**What this does:**
- Routes the media download through the local frame-aware fault proxy
- Revokes current media read permissions after the first proxied download chunks
- Accepts either a completed download or an expected transport-loss error
- Restores the original media grants after the check

**Expected result:**
- Slot D NIO N2301 currently records `transport_lost_after_revoke`
- The log includes the permission mutation, fault-proxy hook status, and restore output
- Do not combine this check with throughput or minimum-byte gates; this run proves permission-change behavior, not complete-file transfer performance

### 9. Expected Error Boundary Tests

**Goal:** Record stable error mappings for missing sources, unauthorized roots, and unsupported operations.

**List missing SAF root:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --list-expect-error-path dm://saf-missing/ \
  --list-expect-error-code notFound
```

**Download missing file:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --download-open-expect-error-path dm://app-sandbox/missing-file.bin \
  --download-open-expect-error-code notFound
```

**MediaStore fresh-only upload resume:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --upload-source /tmp/droidmatch-upload.jpg \
  --upload-destination-path dm://media-images/droidmatch-test.jpg \
  --upload-resume-unsupported-check \
  --min-upload-bytes 1 \
  --cleanup-upload-destination
```

**Expected result:**
- Each test records the expected error code and optional message substring
- Proves protocol returns stable, typed errors for well-defined failure cases

## Test Matrix Recommendations

For a complete M1 validation across three devices:

1. **Slot A device (API 26-29):**
   - Handshake stability (20 attempts)
   - 100MB download throughput
   - 100MB upload throughput
   - Download resume
   - Upload resume

2. **Slot C device (API 33-35):**
   - Same as Slot A, plus:
   - Permission revocation test
   - Permission revocation during MediaStore download
   - Expected error boundaries
   - Fresh MediaStore upload
   - Transport loss recovery

3. **Slot D device (domestic OEM or tablet):**
   - Handshake stability
   - Large directory listing (if available)
   - 100MB throughput tests
   - Vendor-specific behavior verification

## Result Logs

All tests write redacted logs to `fixtures/m1-runs/` unless `--no-result-log` is passed.

Before committing logs:
```bash
bash tools/check-m1-run-logs.sh
```

This ensures logs don't contain:
- Full device serials (should be redacted)
- Personal file paths
- Unredacted support bundles

## Current Test Coverage Status

Based on existing logs in `fixtures/m1-runs/` and automated tests:
- ✅ App-sandbox upload (fresh, resume, 100MB)
- ✅ Download cancel and pause
- ✅ MediaStore upload fresh-only boundary
- ✅ Slot D handshake stability (20/20 attempts on NIO N2301)
- ✅ Transport loss recovery with `recovered=true`
- ✅ Slot D ADB baseline download diagnostic (75.70 MiB/s on the same 100MiB app-sandbox file)
- ✅ Slot D 100MB windowed download assertion (48.95 MiB/s with 1MiB chunks, above 20)
- ✅ Slot D 100MB windowed upload assertion (33.51 MiB/s with 1MiB chunks, above 20)
- ✅ Slot D warm media-images list assertion (harness `elapsed_ms=98`, below 1000)
- ✅ Slot D media permission revocation (`permissionRequired`, prior grants restored)
- ✅ Slot D media permission revocation during MediaStore download (`transport_lost_after_revoke`, prior grants restored)
- ✅ Android unit coverage for download resume missing/changed/unavailable source fingerprint rejection
- ❌ **Missing:** Handshake stability and broader matrix coverage on Slot A and Slot C devices
- ❌ **Missing:** USB unplug during upload/download
- ❌ **Missing:** Real-device source deletion/modification before resume

## Next Steps

Priority tests to run when devices are available:

1. Add Slot A device (API 26-29) and run the basic matrix.
2. Add Slot C device (API 33-35) and run the full matrix with permission tests.
3. Record USB unplug during upload/download behavior.
4. Record real-device source deletion/modification before resume.
5. Document throughput results and USB timing per device.

This will satisfy the M1 exit criteria defined in `docs/m1-device-matrix.md`.
