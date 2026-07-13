# M1 Testing Guide

This guide provides step-by-step instructions for running M1 device tests that satisfy the exit criteria defined in `docs/m1-device-matrix.md`.

## Prerequisites

- One or more physical Android devices (see device requirements below)
- USB cable connected and device authorized via `adb devices -l`
- Developer options must allow ADB package installation. On some OEM devices
  this is named "Install via USB", "USB install", or "USB debugging security
  settings"; keep the device unlocked while the debug APK installs.
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

If installation fails with `INSTALL_FAILED_USER_RESTRICTED`, the phone is
blocking ADB installs. Reopen Developer options, enable the USB install/security
toggle described above, and rerun the smoke command. Do not commit a result log
for this setup failure unless it is documenting a vendor-specific blocker.
Some Flyme builds additionally show an on-device confirmation for each test-APK
install. The Keystore runner can pass after the user explicitly taps Allow; such
evidence is attended and must not be described as an unattended device run.

## Device Requirements

M1 requires at least three physical devices covering these slots:

| Slot | Android API | Device Type | Purpose |
|---|---|---|---|
| A | API 26-29 | Legacy storage-era phone | Verify SAF/MediaStore behavior on minimum supported generation |
| C | API 33-35 | Recent mainstream phone | Verify current permission prompts and AOA viability |
| D | API 30+ | Non-Google OEM or tablet | Verify vendor USB behavior and large storage |

Current test coverage:
- ✅ Slot D: NIO N2301, API 34 (multiple tests recorded)
- ⚠️ Slot A: SHARP 704SH, API 26 has 20/20 handshake and warm media-images list evidence. Its archived 100MiB download/upload resume probes used the old debug/Onone Mac harness and predate the current transfer optimizations, so their sub-20 MiB/s results are historical diagnostics rather than current-tip gate evidence; both directions require a release-configured rerun
- ✅ Slot C: MEIZU M20, API 34 has 20/20 handshake, warm media-images list, app-sandbox 100MiB download/upload resume throughput, permission revocation, expected errors, MediaStore fresh-only upload, recovery, real-device source-mutation/deletion rejection, writable SAF resume/recovery, and attended physical-USB upload and 10GiB download unplug/reconnect/resume evidence
- ℹ️ Unclassified: Pixel 9 Pro Fold, API 37 has a 20/20 two-device ADB routing smoke; it does not satisfy the Slot A API 26-29 requirement

### Optional pairing Keystore instrumentation

The normal CI gate compiles but does not execute the isolated Android Keystore
tests. On an explicitly selected writable test device, run:

```bash
tools/run-android-keystore-instrumentation.sh --serial <serial>
```

Do not substitute Gradle `connectedDebugAndroidTest` on an OEM device. Its app
installer may remove the product package before a vendor policy rejects the test
APK, which destroys private product test data without running any tests. The
repository runner builds both APKs, requires an already-installed product package,
installs the test APK first, runs the isolated runner, and removes only
`app.droidmatch.test`. If installation is rejected, it exits while leaving the
product package and data intact.

`PairingKeystoreInstrumentationTest` creates unique test-only aliases and
preferences, verifies that the P-256 identity and AES wrapping private material is
non-exportable, checks signature and encrypted-record round trips, then removes its
test state in `finally`. Record a result as device evidence only after this command
actually passes; APK compilation alone is not evidence.

### Attended product USB insertion timing

Build and launch the latest `app.droidmatch.mac` product App, keep it
foreground-active, physically disconnect the selected device, and confirm its
visible model label has disappeared. The runner reads only the macOS
Accessibility tree; it does not use ADB as a substitute for product visibility:

```bash
tools/run-product-usb-insertion-smoke.sh \
  --expected-label 'MEIZU M20' \
  --timeout-seconds 5
```

Grant Accessibility access to the invoking terminal/Codex process if macOS asks.
Press Enter and immediately insert the cable. The reported monotonic elapsed time
includes the human insertion motion and ends only when one foreground discovery
button contains both the label and `ADB`. A trusted-device record or file name
does not count. A matching discovery button already visible at preflight, an inactive/missing App,
missing Accessibility permission, or a result over five seconds fails closed.
The runner does not archive evidence; review the physical action and redact the
terminal output before adding a fixture. Its state machine is covered without
hardware by `tools/test-product-usb-insertion-smoke.sh`.

### Attended physical-download interruption and resume

Use the dedicated runner only with an explicitly selected disposable device and
an already-installed debug product. It never installs an APK and does not delete
a caller-supplied destination:

```bash
tools/run-download-unplug-device-smoke.sh \
  --serial <serial> \
  --source-path dm://app-sandbox/<large-test-file> \
  --expected-bytes <exact-bytes> \
  --destination /tmp/droidmatch-download-unplug.bin
```

Physically unplug only after `UNPLUG NOW`, then reconnect the same device after
the script reports a durable partial. A passing run proves that the selected
serial left ADB, a non-empty partial plus checkpoint survived, the same serial
returned ready, `download --resume` completed, the exact final size matched, and
both script-owned forwards were removed. The runner deliberately does not archive
evidence; review and redact the terminal output before adding a physical-device
fixture. Its state machine is exercised without hardware by
`tools/test-download-unplug-device-smoke.sh`.

## Critical M1 Exit Criteria Tests

The same checks are also available through the quick scenario wrapper:

```bash
tools/quick-test-scenarios.sh help
tools/quick-test-scenarios.sh handshake-stability --serial <serial> --device-slot D --max-list-ms 1000
tools/quick-test-scenarios.sh full-matrix --serial <serial> --device-slot D
```

The compatibility-named `full-matrix` scenario runs the automated core ADB
matrix only: stability, throughput, resume, retry, and permission checks. It
does not by itself satisfy every M1 exit criterion and excludes the complementary
attended product discovery/connection and SAS approval, SAF authorization, and
physical-unplug/reconnect-resume runs. Complete those physical-device workflows
separately as described above and in `docs/m1-device-matrix.md`.

The device runner builds and invokes `droidmatch-harness` with Swift's release
configuration. Do not use a debug/Onone `swift run` result as throughput evidence:
it measures a different host execution mode and cannot pass or fail the current
20 MiB/s download or upload gate.

For the open Slot A gate, use the versioned strict wrapper rather than archiving
two loosely composed commands:

```bash
tools/run-m1-throughput-gate.sh \
  --serial <serial> \
  --expected-main-sha <40-hex-origin-main-sha>
```

Before any build or device write, the wrapper fetches `origin/main` and requires
that full SHA, local HEAD, and the caller-reviewed SHA to match in a clean tree.
It requires API 26–29, runs one fresh baseline/download/upload profile, verifies
both directions are exactly 104857600 bytes with requested and negotiated
1048576-byte chunks and at least 20 MiB/s, and reserves absent high-entropy
app-sandbox source/final/partial names before creating them. It then verifies the prepared source,
upload final/hidden partial, local transfer artifacts, and owned ADB forward are
absent, fetches `origin/main` again to close the long-run race, and refuses stale
evidence. The generic runner's output stays in a private temporary file; only a
privacy-bounded summary and a validated `m1-adb-throughput-v1` fixture are
published after cleanup. The offline profile test never counts as device evidence.

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
- Test passes on the same three selected required devices (one Slot A, one Slot C, and one Slot D or E)

### 3. Upload Throughput Test

**Goal:** Verify 100MB app-sandbox ADB upload throughput ≥ 20 MiB/s.

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
- Upload completes with `throughput_mib_per_sec` ≥ 20.0
- Result log includes `elapsed_ms` and `throughput_mib_per_sec`
- Test passes on the same 3 required devices as the download gate
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

### 4a. Download Resume Source Mutation Test

**Goal:** Verify a real device rejects resume when the source changes after the partial-download sidecar is captured.

**Command:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-source-mutation.bin \
  --prepare-app-sandbox-bytes 1048576 \
  --resume-check \
  --partial-bytes 262144 \
  --download-resume-source-mutation-check
```

**What this does:**
- Limits the mutation to a zero-filled file created by this script in `dm://app-sandbox/`; it never changes user files or MediaStore content
- Stops a partial download, then appends one byte to the prepared source before the resume request
- Requires remote `invalidArgument` with `source fingerprint changed`
- Removes the prepared source and local partial/sidecar artifacts on exit

**Expected result:**
- The result log reports the before/after source sizes and the expected fingerprint rejection
- The scenario itself passes because rejection is the required behavior

### 4b. Download Resume Source Deletion Test

**Goal:** Verify a real device returns not-found when the source is deleted after the partial-download sidecar is captured.

**Command:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-source-deletion.bin \
  --prepare-app-sandbox-bytes 1048576 \
  --resume-check \
  --partial-bytes 262144 \
  --download-resume-source-deletion-check
```

**What this does:**
- Limits deletion to a zero-filled file created by this script in `dm://app-sandbox/`; it never deletes user files or MediaStore content
- Stops a partial download, removes the prepared source before the resume request, and verifies it no longer exists
- Requires remote `notFound` with `app sandbox file is not available`
- Removes local partial/sidecar artifacts on exit

**Expected result:**
- The result log records the controlled deletion and the expected not-found rejection
- The scenario itself passes because rejection is the required behavior

### 4c. Dual Download Stream Test

**Goal:** Verify two download streams remain active on one device session, their
chunks are routed independently, and the control plane remains responsive.

**Command:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-dual-stream.bin \
  --prepare-app-sandbox-bytes 1048576 \
  --dual-download-check \
  --chunk-size-bytes 262144
```

**What this does:**
- Creates one disposable app-sandbox source and opens two independent readers for it
- Opens both transfers before acknowledging either first chunk
- Requires a heartbeat response while both streams are active
- Routes and validates each stream independently, then also runs the ordinary download gate
- Removes the script-created Android source and local download artifacts on exit

**Expected result:**
- Harness output contains `dual-download-smoke passed`
- The result log records both stream IDs, chunk/byte totals, and the heartbeat value

### 4d. Mixed Upload/Download Stream Test

**Goal:** Make the product-async mixed-direction path directly runnable on a
device: one download, one fresh upload, and a heartbeat share one session after
both transfer streams are open.

**Command:**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-mixed-download.bin \
  --prepare-app-sandbox-bytes 1048576 \
  --upload-source /tmp/dm-mixed-upload.bin \
  --upload-destination-path dm://app-sandbox/dm-standalone-upload.bin \
  --mixed-transfer-check \
  --mixed-upload-destination-path dm://app-sandbox/dm-concurrent-upload.bin \
  --chunk-size-bytes 262144 \
  --cleanup-upload-destination
```

**What this does:**
- Opens a download and a distinct upload before starting either file operation
- Requires heartbeat while download is still unacknowledged and upload has sent no chunk, then concurrently runs atomic receive and 4-chunk / 2 MiB upload refill through the async single-reader router
- Revalidates the local upload source after the final ACK and compares reported byte counts with both local files
- Uses an opaque upload source label on the wire, so the Mac path and file name are not copied into remote diagnostics
- Runs the ordinary download/upload checks too; the standalone and concurrent upload destinations must differ

**Expected result:**
- Harness output contains `mixed-transfer-smoke passed`
- The result log records two distinct stream IDs, both byte/chunk totals, and the heartbeat value
- This makes the probe runnable but is not device evidence until a redacted run is archived

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
   - App-sandbox source mutation rejection before download resume
   - App-sandbox source deletion rejection before download resume

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
- ✅ Slot A SHARP 704SH handshake stability (20/20 attempts) and warm media-images list assertion (`elapsed_ms=165`, below 1000)
- ⚠️ Historical Slot A SHARP 704SH 100MiB download diagnostic: the initial resume completed at 16.64 MiB/s (raw ADB baseline 7.19 MiB/s); the fully charged rerun completed at 16.63 MiB/s (raw ADB baseline 11.21 MiB/s). Both used the old debug/Onone harness and predate the current transfer optimizations, so neither proves current-tip failure or success
- ⚠️ Historical Slot A SHARP 704SH 100MiB upload diagnostic: the initial resume completed at 15.20 MiB/s; the fully charged rerun completed at 15.70 MiB/s under the same now-stale execution path
- ✅ Slot C MEIZU M20 app-sandbox 100MiB download resume assertion (35.52 MiB/s with 1MiB chunks, above 20; ADB baseline 36.90 MiB/s)
- ✅ Slot C MEIZU M20 app-sandbox 100MiB upload resume assertion (20.22 MiB/s with 1MiB chunks, above 20)
- ✅ Slot C MEIZU M20 media permission revocation (`permissionRequired`, prior grants restored)
- ✅ Slot C MEIZU M20 expected-error boundaries (`notFound` for missing SAF root and missing app-sandbox download source)
- ✅ Slot C MEIZU M20 MediaStore fresh-only upload boundary (`unsupportedCapability` for non-zero offset, then fresh upload succeeds and cleans up)
- ✅ Slot C MEIZU M20 app-sandbox upload ACK-loss replay (`recovered=true`)
- ✅ Slot C MEIZU M20 app-sandbox download fault retry (`recovered=true`, 100MiB final offset)
- ✅ Slot C MEIZU M20 media permission revocation during MediaStore download (`completed_after_revoke`, prior grants restored)
- ✅ Slot C MEIZU M20 app-sandbox source mutation before download resume (1MiB source grew to 1048577 bytes after a 262144-byte partial download; resume returned `invalidArgument` / `source fingerprint changed`, and cleanup completed)
- ✅ Slot C MEIZU M20 app-sandbox source deletion before download resume (1MiB source was deleted after a 262144-byte partial download; resume returned `notFound` / `app sandbox file is not available`, and cleanup completed)
- ✅ Unclassified Pixel 9 Pro Fold API 37 two-device ADB routing smoke (20/20 attempts with explicit serial)
- ✅ Android unit coverage for download resume missing/changed/unavailable source fingerprint rejection
- ✅ Local TCP coverage for `mixed-transfer-smoke`: two directions open together, atomic download, four-chunk upload refill, heartbeat, stable-source recheck, and opaque upload source label
- ✅ Android unit coverage for invalid and query-mismatched page token rejection
- ✅ Mac/Android unit coverage for oversized envelope rejection
- ✅ Mac/Android unit coverage for bad transfer-chunk CRC rejection
- ❌ **Blocking:** Slot A API 26 lacks current-tip, release-configured ≥20 MiB/s download and upload evidence; rerun through a direct physical USB path. A second API 26-29 device is a recommended non-gating cross-check before changing protocol assumptions or the threshold
- ❌ **Blocking:** attended product USB insertion ≤5 seconds lacks archived evidence on every required Slot A/C/D device
- ✅ Slot C writable SAF root listing plus 10MiB incompressible upload resume
  (27.36 MiB/s) and transport-loss recovery (`recovered=true`, 27.14 MiB/s).
  The first recovery run exposed an ACK-loss window where the provider partial
  was ahead of the durable Mac ACK; the failing evidence is archived. Android
  now truncates seekable SAF partials to that ACK before replay, and the test
  grant, hidden partials, final files, and disposable folder were removed.
- ✅ Slot C physical USB unplug during a 2GiB app-sandbox upload. The disconnect
  returned transport close with a durable Mac checkpoint at 768,081,920 bytes.
  After physical reconnect, Android authorization, Activity restart, and a new
  dynamic ADB forward, manual `upload --resume` completed the remaining
  1,379,401,728 bytes at 37.03 MiB/s. A fresh device listing verified the final
  2,147,483,648-byte destination. The disconnect and post-resume verification
  are archived as separate redacted logs because physical reconnect destroys
  the original ADB forward.
- ✅ Slot C attended physical USB unplug during a 10GiB app-sandbox download.
  The selected serial disappeared from ADB after a 3,626,762,240-byte durable
  partial, returned with a new transport identity, and resumed the remaining
  7,110,656,000 bytes at 28.35 MiB/s. The exact 10,737,418,240-byte final size,
  atomic checkpoint cleanup, and owned-forward cleanup were verified.
- ✅ Slot C sandbox-entitled product App paired with visible SAS, listed the
  app sandbox, downloaded 1MiB through an explicitly selected directory scope,
  and uploaded 1MiB with its checkpoint in the App-owned device queue directory;
  both directions matched SHA-256 and disposable files were cleaned.
- ✅ Slot C sandbox App was terminated with `SIGKILL` during a 4GiB upload after
  a 598,999,040-byte durable checkpoint. Relaunch restored a paused job,
  reacquired the source bookmark, and resumed attempt 2 from the checkpoint;
  the 4,294,967,296-byte final file matched SHA-256 and recovery artifacts were
  cleaned.
- ✅ Slot C MEIZU M20 physical-device `--dual-download-check` and
  `--mixed-transfer-check` evidence (two 1MiB readers plus responsive heartbeat;
  concurrent 1MiB download and 10MiB upload completed on one async session)
- ✅ Slot C MEIZU M20 disposable app-sandbox large-directory probe: 1,005
  empty entries paginated as 1,000 + 5 with aggregate-only output in 833 ms;
  the generated directory and dynamic forward were removed on exit. Re-run with
  `tools/run-large-directory-device-smoke.sh --serial <serial>`.
  Add `--measure-memory` for a separate diagnostic run that samples only
  aggregate app PSS while the provider pages the directory. Because `dumpsys`
  sampling perturbs the request, do not use that run's elapsed time as a gate.
- ✅ Slot C memory diagnostic observed aggregate app PSS rise from 31,664 KiB
  to a sampled peak of 38,313 KiB while paging 1,005 entries. The 6,649 KiB
  delta is process-level device evidence, not a heap-allocation proof or a
  portable limit; the runner verified its exact directory and forward absent.
- ⚠️ Slot C MEIZU M20 upload throughput regressed on 2026-07-11: two controlled
  100MiB runs measured 15.54 and 15.45 MiB/s, below the 20 MiB/s gate; both
  failing results are archived and the full matrix stopped at this criterion
- ✅ Follow-up incompressible-file diagnostics measured 15.32 MiB/s to
  app-sandbox and 15.11 MiB/s to fresh MediaStore before the ACK-driven
  continuous-refill change. After the change, app-sandbox uploads measured
  32.73 MiB/s at 256KiB, 35.29 MiB/s at 512KiB, and 22.77 MiB/s at 1MiB;
  resume completed at 36.20 MiB/s. A first fault-recovery run exposed a teardown
  race that masked the retryable transport error; the archived failing run led
  to a terminal-error preservation fix. Its rerun recovered at 34.33 MiB/s, and
  ACK-loss truncate/replay recovered at 35.04 MiB/s.

## Next Steps

Priority tests to run when devices are available:

1. Re-run both Slot A throughput directions through a direct physical USB path,
   recording release-configured harness timings and the raw ADB download
   baseline; then validate with a second API 26-29 device. The historical
   debug/Onone results are diagnostics, not current-tip gate evidence.
2. Archive an attended product USB insertion ≤5-second result on each required
   Slot A/C/D device with `tools/run-product-usb-insertion-smoke.sh`. ADB-only
   visibility is not a substitute.

These are both M1 blockers. The attended Slot C download-unplug scenario is
already archived.
