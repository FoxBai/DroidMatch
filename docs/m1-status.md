# M1 Status Summary

Last updated: 2026-07-09

## Current Implementation Status

### ✅ Completed Features

**Mac Side:**
- ADB client (discovery, forward, device listing)
- Frame codec (4 MiB max, length-prefixed)
- Framed TCP client/session (Network.framework)
- Handshake smoke client (ClientHello/ServerHello)
- M1 smoke client (full control-plane test)
- RPC control client (request/response handling)
- Transfer implementation:
  - Single-stream download (windowed receiver-paced, with CRC32 validation)
  - Single-stream upload (windowed, 4 chunk / 2 MiB in-flight, to app-sandbox/MediaStore/SAF)
  - Download resume (with source fingerprint validation)
  - Upload resume (app-sandbox and SAF)
  - Transfer cancel and pause
  - Sidecar-backed transport-loss retry (legacy single retry by default, configurable recovery queue via `--max-retry-attempts`)
  - Atomic download writer (partial → final commit)
- CLI harness with commands: devices, forward, handshake-smoke, m1-smoke, list-dir, download, upload, etc.
- Throughput measurement (elapsed_ms, throughput_mib_per_sec)

**Android Side:**
- Foreground connection service
- ADB endpoint (loopback only, with timeouts)
- Framed I/O (uint32_be length + payload)
- RPC dispatcher (session management, request routing)
- Protocol handlers:
  - ClientHello/ServerHello
  - HeartbeatRequest
  - DeviceInfoRequest
  - ListDirRequest (roots, media, SAF, app-sandbox)
  - OpenTransferRequest (download and upload)
  - TransferChunk/TransferChunkAck
  - CancelTransferRequest
  - PauseTransferRequest
  - DiagnosticsRequest
- File providers:
  - MediaStore (images/videos via content resolver)
  - SAF (tree URI permissions, directory listing)
  - App sandbox (private files/droidmatch-sandbox)
- Provider features:
  - Download: seekable FD or stream with offset skip
  - Upload: hidden partial files, atomic commit on final chunk
  - Resume: source fingerprint validation (download), partial offset validation (upload)
  - ACK loss tolerance (app-sandbox upload truncate/replay)
- Permission state provider
- Diagnostics reporter (with concurrent test coverage)
- Debug harness Activity (keeps endpoint alive during testing)
- Launcher entry (DiagnosticsActivity for authorization)

**Tooling:**
- `tools/run-m1-device-smoke.sh`: comprehensive device test script
- `tools/m1-fault-proxy.py`: local frame proxy for fault injection
- `tools/check-m1-skeleton.sh`: CI validation
- `tools/check-m1-run-logs.sh`: log redaction verification
- Automated result logging to `fixtures/m1-runs/`

**Documentation:**
- M0 closeout (specs finalized)
- Protocol documentation (schema, runtime, paths)
- Device matrix requirements
- Testing guide (step-by-step for exit criteria)
- Architecture, security model, feature matrix

### ⚠️ Partially Implemented

**Transfer Features:**
- Transport-loss retry: configurable multi-attempt recovery queue now implemented
  via `RecoveryPolicy` (exponential backoff, attempt cap, sidecar-gated retry).
  - Default `--retry-on-transport-loss` still reproduces the legacy single retry
    for backward-compatible matrix scripts.
  - `--max-retry-attempts N` enables up to N additional reconnect attempts.
  - `--retry-backoff-ms M` overrides the base backoff (default 500 ms).
  - Unit + end-to-end tests cover backoff timing, attempt exhaustion, and
    multi-loss recovery on a local fault-injecting server.
  - Persistent queue across app restarts remains post-M1.
- Concurrency: only single-stream transfers
  - Protocol supports stream_id for multiplexing
  - Scheduler for 2 concurrent transfers not yet implemented

**Testing Coverage:**
- Slot D device (NIO N2301, API 34): extensive coverage
- Slot A (API 26-29): no required-slot tests yet
- Slot C (MEIZU M20, API 34): handshake/list plus app-sandbox 100MiB download/upload resume throughput coverage
- Unclassified: Pixel 9 Pro Fold (API 37) has a 20/20 two-device ADB routing smoke, but it does not satisfy Slot A's API 26-29 requirement
- Handshake stability: Slot D and Slot C have 20/20 runs; required Slot A is still missing
- Throughput: Slot D and Slot C download/upload now have passing 100MiB probes

### ❌ Not Yet Implemented

**Core Features (per M1 scope):**
- Multi-stream transfer scheduling (protocol ready, harness not)
- Persistent recovery queue across app restarts (post-M1; in-process
  multi-attempt recovery queue is now implemented)
- AOA transport path (blocked until ADB path completes M1)

**Product UI (out of M1 scope):**
- macOS native UI (M1 is harness-only)
- File browser
- Transfer queue UI
- Settings/preferences
- Notification integration

**Optional Features (post-v1.0):**
- Screen mirroring
- Notification mirroring
- Clipboard sync
- Folder subscriptions
- Wi-Fi transport

## M1 Exit Criteria Progress

| Criterion | Status | Notes |
|---|---|---|
| ADB handshake ≥19/20 | ⚠️ Slot C/D passing | NIO N2301 Slot D and MEIZU M20 Slot C both logged 20/20 attempts; Pixel 9 Pro Fold API 37 also logged an unclassified 20/20 smoke, but required Slot A API 26-29 is still missing |
| USB insertion ≤5s | ⚠️ Needs measurement | Device smoke shows "already authorized" |
| First list ≤1s (warm) | ✅ Slot C/D passing | NIO N2301 Slot D measured harness `elapsed_ms=98` for 48 entries; MEIZU M20 Slot C measured `elapsed_ms=84` for 8 entries; command wall time is logged separately |
| 100MB download ≥20 MiB/s | ⚠️ Slot C/D passing | NIO N2301 measured 48.95 MiB/s with a 75.70 MiB/s ADB baseline; MEIZU M20 app-sandbox resume measured 35.52 MiB/s with a 36.90 MiB/s ADB baseline |
| 100MB upload ≥20 MiB/s | ⚠️ Slot C/D passing | NIO N2301 measured 33.51 MiB/s; MEIZU M20 app-sandbox upload resume measured 20.22 MiB/s after the Mac harness partial-upload send-limit fix |
| Download resume | ✅ Implemented | Partial + resume with fingerprint validation; Android unit tests cover missing, changed, and unavailable source fingerprints |
| App-sandbox upload resume | ✅ Implemented | Partial + resume with truncate/replay tolerance |
| Sidecar transport retry | ✅ Implemented | Fault injection passes with `recovered=true`; Slot D log records `--max-retry-attempts 3` / `--retry-backoff-ms 100` |
| Fresh MediaStore upload | ✅ Implemented | Pictures/Movies collections |
| Fresh SAF upload | ✅ Implemented | User-selected writable roots |
| SAF upload resume | ✅ Implemented | Transfer-id hidden partial documents |
| Permission-denied mapping | ✅ Slot D passing | Media listing revoke returns `permissionRequired`; media download revoke records expected transport loss; grants are restored |
| Diagnostics attribution | ✅ Implemented | Service/permission/transfer state |
| Three-device coverage | ❌ Missing | Slot D has broad coverage and Slot C now has handshake/list plus app-sandbox throughput/resume evidence; required Slot A API 26-29 is still missing |
| AOA viability (2 devices) | ❌ Blocked | Waiting for ADB path completion |

## Immediate Next Steps

### High Priority (M1 Blockers)

1. **Acquire a required Slot A device (API 26-29)** and run the basic matrix; expand MEIZU M20 Slot C from app-sandbox throughput/resume evidence to the permission, SAF, MediaStore, and USB-abnormal matrix.

2. **Cover abnormal device scenarios** that still lack archived evidence:
   USB unplug during upload/download. Repeat the media permission-revoke-during-transfer check on MEIZU M20 Slot C.

### Medium Priority (M1 Enhancements)

3. **Implement multi-stream scheduling:**
   - Extend harness to open 2 concurrent transfers
   - Verify stream_id multiplexing
   - Demonstrate control-plane remains responsive during dual transfers

4. **Expand SAF upload testing:**
   - Test writable SAF directories on multiple OEMs
   - Verify partial document cleanup on non-final close
   - Document SAF provider quirks by vendor

5. **Persistent recovery queue (post-M1):**
   - Survive harness/app restart with on-disk queue state
   - User-visible retry state in diagnostics

### Low Priority (Post-M1)

6. **USB timing measurements:**
   - Cable insertion to device-visible latency
   - Authorization flow timing
   - Reconnect after unplug/replug

7. **Large directory stress tests:**
   - 1000+ entry MediaStore listings
   - Pagination performance
   - Provider memory usage

8. **AOA path exploration:**
   - After ADB passes M1 on 3 devices
   - Requires at least 2 AOA-capable devices
   - Throughput target: ≥30 MB/s

## Known Limitations

- **Single-stream transfers:** Current harness opens one transfer at a time
- **Default single retry:** `--retry-on-transport-loss` keeps the legacy single retry unless `--max-retry-attempts N` is supplied
- **No automatic cleanup for SAF uploads:** Manual deletion required until delete/mutation protocol exists
- **MediaStore fresh-only:** Upload resume not supported (returns unsupportedCapability)
- **ADB loopback only:** Android endpoint rejects non-127.0.0.1 clients
- **Debug harness Activity required:** Some OEM devices freeze service accept() thread without foreground Activity

## Test Result Summary

As of 2026-07-09, `fixtures/m1-runs/` contains:
- 26 test result logs
- NIO N2301 (Slot D, API 34) broad matrix coverage, MEIZU M20 (Slot C, API 34) handshake/list plus app-sandbox throughput/resume evidence, and an unclassified Pixel 9 Pro Fold (API 37) two-device ADB routing smoke
- Coverage: app-sandbox upload (fresh/resume/100MB), app-sandbox download resume/100MB, MediaStore upload, media permission revocation during listing and download, cancel, pause, Slot D handshake stability (20/20), Slot C handshake stability (20/20), Slot D/Slot C throughput assertions, ADB baseline download diagnostics, configurable recovery policy fault smoke
- Passing: Slot D windowed download measured 48.95 MiB/s with 1MiB chunks against a 75.70 MiB/s ADB baseline
- Passing: Slot D windowed upload measured 33.51 MiB/s with 1MiB chunks against the 20 MiB/s gate
- Passing: Slot D warm media-images list measured harness `elapsed_ms=98` against the 1000 ms gate
- Passing: Slot D media permission revocation returned `permissionRequired` for `dm://media-images/` and restored prior grants
- Passing: Slot D media permission revocation during `dm://media-images/media/1000001148` download observed `transport_lost_after_revoke` and restored prior grants
- Passing: MEIZU M20 Slot C warm media-images list measured harness `elapsed_ms=84` against the 1000 ms gate after 20/20 `m1-smoke` attempts
- Passing: MEIZU M20 Slot C app-sandbox 100MiB download resume measured 35.52 MiB/s after a 36.90 MiB/s ADB baseline
- Passing: MEIZU M20 Slot C app-sandbox 100MiB upload resume measured 20.22 MiB/s after the Mac harness send-limit fix
- Passing: Pixel 9 Pro Fold API 37 unclassified smoke passed 20/20 attempts with explicit serial routing while two ADB devices were connected
- Unit-covered abnormal paths: stale download resume source fingerprints, invalid page tokens, oversized envelopes, and bad transfer-chunk CRC32
- Missing: required Slot A API 26-29 device; Slot C permission, SAF, MediaStore, and USB-abnormal matrix coverage

## References

- [M1 Testing Guide](m1-testing-guide.md): step-by-step test instructions
- [M1 Device Matrix](m1-device-matrix.md): required devices and pass criteria
- [M0 Closeout](m0-closeout.md): specification decisions
- [Protocol Runtime](protocol-runtime.md): concurrency limits and backpressure
- [Protocol](protocol.md): message schemas and semantics
- [Path Model](path-model.md): logical path abstraction
