# M1 Status Summary

Last updated: 2026-07-05

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
  - Single-stream download (receiver-paced, with CRC32 validation)
  - Single-stream upload (receiver-paced, to app-sandbox/MediaStore/SAF)
  - Download resume (with source fingerprint validation)
  - Upload resume (app-sandbox and SAF)
  - Transfer cancel and pause
  - Sidecar-backed transport-loss retry (one attempt)
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
- Transport-loss retry: only one automatic reconnect attempt
  - Full recovery queue with exponential backoff not yet implemented
  - Current retry logic: detect loss → reconnect → handshake → resume with sidecar
- Concurrency: only single-stream transfers
  - Protocol supports stream_id for multiplexing
  - Scheduler for 2 concurrent transfers not yet implemented

**Testing Coverage:**
- Slot D device (NIO N2301, API 34): extensive coverage
- Slot A (API 26-29): no tests yet
- Slot C (API 33-35): no tests yet (unless NIO also serves this)
- Handshake stability: no 20/20 attempt runs recorded
- Throughput: 100MB transfers exist but some logs lack throughput metrics

### ❌ Not Yet Implemented

**Core Features (per M1 scope):**
- Multi-stream transfer scheduling (protocol ready, harness not)
- Full automatic recovery queue (beyond single retry)
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
| ADB handshake ≥19/20 | ✅ Slot D passing | NIO N2301 Slot D logged 20/20 attempts |
| USB insertion ≤5s | ⚠️ Needs measurement | Device smoke shows "already authorized" |
| First list ≤1s (warm) | ⚠️ Needs assertion/tuning | app-sandbox 937-943ms logged; latest media-images run was 1042ms; `--max-list-ms` gate added |
| 100MB download ≥20 MiB/s | ⚠️ Needs assertion | 100MB tests exist, but throughput not all recorded |
| Download resume | ✅ Implemented | Partial + resume with fingerprint validation |
| App-sandbox upload resume | ✅ Implemented | Partial + resume with truncate/replay tolerance |
| Sidecar transport retry | ✅ Implemented | One-attempt retry with fault injection |
| Fresh MediaStore upload | ✅ Implemented | Pictures/Movies collections |
| Fresh SAF upload | ✅ Implemented | User-selected writable roots |
| SAF upload resume | ✅ Implemented | Transfer-id hidden partial documents |
| Permission-denied mapping | ✅ Implemented | Media permission revocation test |
| Diagnostics attribution | ✅ Implemented | Service/permission/transfer state |
| Three-device coverage | ❌ Missing | Only Slot D (NIO N2301) tested |
| AOA viability (2 devices) | ❌ Blocked | Waiting for ADB path completion |

## Immediate Next Steps

### High Priority (M1 Blockers)

1. **Run throughput tests** with assertions:
   ```bash
   # Download
   tools/run-m1-device-smoke.sh --serial <serial> \
     --prepare-app-sandbox-file dm-100mb-zero.bin \
     --resume-check \
     --chunk-size-bytes 1048576 \
     --min-download-mib-per-second 20

   # Upload
   tools/run-m1-device-smoke.sh --serial <serial> \
     --upload-source /tmp/100mb-upload.bin \
     --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
     --chunk-size-bytes 1048576 \
     --min-upload-mib-per-second 20 \
     --cleanup-upload-destination
   ```

2. **Repeat warm list latency** with an explicit gate:
   ```bash
   tools/run-m1-device-smoke.sh --serial <serial> \
     --list-path dm://media-images/ \
     --max-list-ms 1000
   ```

3. **Acquire Slot A and Slot C devices** and run basic matrix

### Medium Priority (M1 Enhancements)

4. **Implement multi-stream scheduling:**
   - Extend harness to open 2 concurrent transfers
   - Verify stream_id multiplexing
   - Demonstrate control-plane remains responsive during dual transfers

5. **Implement full recovery queue:**
   - Multiple retry attempts with exponential backoff
   - Persistent queue across app restarts (post-M1)
   - User-visible retry state in diagnostics

6. **Expand SAF upload testing:**
   - Test writable SAF directories on multiple OEMs
   - Verify partial document cleanup on non-final close
   - Document SAF provider quirks by vendor

### Low Priority (Post-M1)

7. **USB timing measurements:**
   - Cable insertion to device-visible latency
   - Authorization flow timing
   - Reconnect after unplug/replug

8. **Large directory stress tests:**
   - 1000+ entry MediaStore listings
   - Pagination performance
   - Provider memory usage

9. **AOA path exploration:**
   - After ADB passes M1 on 3 devices
   - Requires at least 2 AOA-capable devices
   - Throughput target: ≥30 MB/s

## Known Limitations

- **Single-stream transfers:** Current harness opens one transfer at a time
- **Single retry:** Transport loss triggers only one reconnect attempt
- **No automatic cleanup for SAF uploads:** Manual deletion required until delete/mutation protocol exists
- **MediaStore fresh-only:** Upload resume not supported (returns unsupportedCapability)
- **ADB loopback only:** Android endpoint rejects non-127.0.0.1 clients
- **Debug harness Activity required:** Some OEM devices freeze service accept() thread without foreground Activity

## Test Result Summary

As of 2026-07-05, `fixtures/m1-runs/` contains:
- 12 test result logs
- All from NIO N2301 (Slot D, API 34)
- Coverage: app-sandbox upload (fresh/resume/100MB), MediaStore upload, cancel, pause, Slot D handshake stability (20/20)
- Missing: throughput assertions, warm list ≤1s assertion, Slot A/C devices

## References

- [M1 Testing Guide](m1-testing-guide.md): step-by-step test instructions
- [M1 Device Matrix](m1-device-matrix.md): required devices and pass criteria
- [M0 Closeout](m0-closeout.md): specification decisions
- [Protocol Runtime](protocol-runtime.md): concurrency limits and backpressure
- [Protocol](protocol.md): message schemas and semantics
- [Path Model](path-model.md): logical path abstraction
