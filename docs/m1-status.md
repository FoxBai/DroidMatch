# M1 Status Summary

Last updated: 2026-07-11

## Current Implementation Status

### ✅ Completed Features

**Mac Side:**
- ADB client (discovery, forward, device listing)
- Frame codec (4 MiB max, length-prefixed)
- Framed TCP client/session (Network.framework)
- Handshake smoke client (ClientHello/ServerHello)
- M1 smoke client (full control-plane test)
- RPC control client (request/response handling)
- Product-facing async TCP/RPC actors with lifetime-selected I/O mode, one multiplexed reader, request deadlines, and cancellation-safe teardown
- SwiftUI `DroidMatch` product target with English/Chinese device dashboard, async ADB discovery, process-local opaque device IDs, stale-snapshot disclosure, generated native icon, and a verified ad-hoc local `.app` bundle
- Product session lifecycle with anonymous dynamic forward leases, stable-identity Keychain selection, visible SAS approval, paired reconnect proof, authenticated paginated file browsing, and privacy-bounded structured diagnostics
- Shared Mac envelope validation (`frame_version`, optional payload CRC, response/error request correlation)
- Enforced handshake nonce correlation plus locally tested first-pairing/reconnect security state machines; product-mode Mac/Android wiring is implemented, while archived physical-device product-auth evidence remains open
- Transfer implementation:
  - Single-stream download (windowed receiver-paced, with CRC32 validation)
  - Single-stream upload (windowed, 4 chunk / 2 MiB in-flight, to app-sandbox/MediaStore/SAF)
  - Scripted dual-download smoke on one session (stream-ID routing, fair chunk servicing, heartbeat while both streams are active)
  - Product-async mixed download/upload handles on one session, with locally verified atomic file receive, four-chunk upload windowing, heartbeat, cancellation, and refill routing; the same success contract is now exposed by `mixed-transfer-smoke`
  - Download resume (with source fingerprint validation)
  - Upload resume (app-sandbox and SAF)
  - Transfer cancel and pause
  - Session-unique active transfer IDs, upload cancellation, and ACK-bounded download pause offsets
  - Sidecar-backed transport-loss retry (legacy single retry by default, configurable recovery queue via `--max-retry-attempts`)
  - Atomic download writer (partial → final commit)
- CLI harness with commands: devices, forward, handshake-smoke, m1-smoke, dual-download-smoke, mixed-transfer-smoke, list-dir, download, upload, etc.
- Throughput measurement (elapsed_ms, throughput_mib_per_sec)
- Opt-in versioned transfer-queue manifest with atomic writes, stable job/FIFO identity, private file permissions, sidecar-gated scheduler reconstruction, and non-replayable `interrupted` state
- Protobuf-free product directory domain types plus paged `AsyncRpcControlClient` listing, embedded-error/row/token validation, and a MainActor `DirectoryBrowserModel` with atomic refresh, retryable load-more, stale-generation rejection, cross-page deduplication, and sanitized failure state
- Separate `DroidMatchPresentation` library with a MainActor `TransferQueueModel`: ordered full-snapshot observation, explicit idempotent start/stop/restart, non-optimistic pause/resume/cancel/remove forwarding, precise post-unwind removal capability, and local-basename-only row state
- Authenticated persistent bidirectional product queue: readable files use a native save panel; writable app-sandbox/SAF/MediaStore directories use a native single-file picker; manifests are private and isolated by authenticated device fingerprint; every attempt creates a fresh paired RPC client behind a session gate; app-sandbox/SAF retries resume while MediaStore remains fresh-only; disconnect pauses recoverable work and interrupts unsafe work before releasing the forward
- MainActor `DeviceDiscoveryModel` with atomic refresh, cancellation/generation guards, sanitized failures, and no ADB serial in presentation state

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
- Debug harness Activity (separate nonce-only evidence path used by device scripts)
- Product launcher entry (`DiagnosticsActivity`) with explicit paired-required endpoint enable/disable, coarse status, pairing approval, notification permission, and SAF authorization list/add/revoke controls
- Explicit no-backup/no-device-transfer rules for private app, pairing, SAF, transfer, and diagnostics state
- Original adaptive-vector launcher mark with Android 13+ monochrome themed-icon support

**Tooling:**
- `tools/check-source-size.py`: one 1,000-line ceiling for every handwritten production, unit-test, and instrumentation-test source file; no legacy exceptions remain
- `tools/run-m1-device-smoke.sh`: comprehensive device test script, including opt-in `--dual-download-check` and `--mixed-transfer-check` with a distinct fresh upload target
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

**Pairing and Authentication:**
- Nonce freshness/correlation is enforced on the current Hello exchange.
- The v1 P-256 pairing and two-stage HMAC reconnection design is specified in `docs/pairing-auth-design.md`.
- Swift and Java canonical transcript, SHA-256, role-separated HMAC, constant-time verification, and HKDF implementations pass one shared fixed vector.
- Two-stage reconnect protobuf, Android challenge/proof state, async Mac mutual-proof verification, downgrade detection, generic unknown-ID/bad-proof failure, and pre-auth capability denial are implemented and tested.
- First-pairing start/confirm/finalize protobuf, cross-platform P-256/ECDH + unbiased SAS + confirmation primitives, a non-synchronizing Keychain store, and an Android Keystore AES-GCM wrapping store are implemented with fixed vectors and injected-backend tests.
- Android stable identity signing, its default-closed 120-second visible pairing window, start/confirm/finalize dispatcher, async Mac client, and provisional Keychain rollback are implemented with JVM and loopback end-to-end tests.
- Per-ID plus global process-local exponential backoff is implemented and tested for first pairing, known/unknown reconnect failures, rotating identifiers, idle expiry, bounded memory, and generic failure shape.
- An isolated AndroidX instrumentation test now compiles for real P-256 identity stability/non-exportability, AES wrapping-key non-exportability, record reopen, and revoke. No device pass is claimed yet.
- The Mac product approval UI and paired-required product endpoint wiring are implemented and locally tested. Executed/archived Keychain/Keystore instrumentation evidence, revocation UI, and physical-device product-auth evidence remain open.

**Transfer Features:**
- Transport-loss retry: configurable multi-attempt recovery queue now implemented
  via `RecoveryPolicy` (exponential backoff, attempt cap, sidecar-gated retry).
  - Default `--retry-on-transport-loss` still reproduces the legacy single retry
    for backward-compatible matrix scripts.
  - `--max-retry-attempts N` enables up to N additional reconnect attempts.
  - `--retry-backoff-ms M` overrides the base backoff (default 500 ms).
  - Unit + end-to-end tests cover backoff timing, attempt exhaustion, and
    multi-loss recovery on a local fault-injecting server.
  - Core now has an opt-in on-disk queue manifest and restoration factory. A future app/harness still needs to supply its owned storage URL and lifecycle/file-access integration.
- Concurrency: both the stable M1 probe and product async core have bounded two-stream paths
  - Open responses and chunks are routed by request/stream ID and serviced fairly
  - Android enforces a two-active-transfer limit per session across both directions
  - Local TCP end-to-end coverage proves interleaving and a responsive heartbeat before first-chunk ACKs
  - Duplicate transfer IDs are rejected before the stream limit, keeping transfer-level controls deterministic
  - The product async router locally interleaves a refilling download, a preflighted four-chunk upload window, and heartbeat with one reader
  - Protocol cancellation wakes the pending upload window without closing the session; a following heartbeat proves reuse
  - Product async download writes on a private serial file queue, keeps the old destination until final ACK, preserves partial data on cancel, and rejects a changed resume offset before accepting bytes
  - `AsyncDownloadCoordinator` now reloads shared Core sidecars, reconnects through an injected authenticated-client factory, and resumes with the same transfer ID, actual partial offset, and accepted source fingerprint; local TCP coverage drops the first session and verifies atomic completion on the second
  - `AsyncUploadCoordinator` now performs serial stable-source reads, four-chunk/two-MiB refill, per-ACK sidecar commits, and app-sandbox/SAF reconnect; local TCP coverage proves replay from the last ACK and cancellation checkpoint retention
  - `AsyncTransferScheduler` provides FIFO admission, a two-job cap, buffering-newest queued/running/retrying/pausing/paused/interrupted/terminal snapshots, monotonic receiver-confirmed bytes/total across retries, a two-second time-weighted recent-throughput sample, retry visibility, completion waiting, cancellation, and checkpoint pause/resume. It remains process-local by default; `restoring(...)` opts into a versioned atomic manifest, writes queued-to-active intent before starting an executor, restores only matching download/app-sandbox/SAF sidecars, and keeps unsafe active work (including MediaStore) visible as non-replayable `interrupted`. Queued pause is a hold; running checkpoint pause closes only that coordinator session and requeues the same job/transfer identity. This local policy does not claim Android wire upload pause.
  - Dual/mixed probes are both script-invocable; download and provider-aware upload scheduling are wired into the authenticated visual target with device-isolated persistence, App-owned security-scoped bookmark leases, and lifecycle-ordered suspension. A locally signed sandbox bundle with embedded adb discovered both connected devices without denial logs; sandbox file transfer and archived product-auth/transfer evidence remain open.

**Testing Coverage:**
- Slot D device (NIO N2301, API 34): extensive coverage
- Slot A (SHARP 704SH, API 26): required-slot handshake/list evidence is archived; two fully charged 100MiB resume probes complete functionally but remain below the 20 MiB/s throughput gate
- Slot C (MEIZU M20, API 34): handshake/list, app-sandbox 100MiB download/upload resume throughput, permission revocation, expected errors, MediaStore fresh-only upload, sidecar/ACK-loss recovery, and real-device source-mutation/deletion rejection coverage
- Unclassified: Pixel 9 Pro Fold (API 37) has a 20/20 two-device ADB routing smoke, but it does not satisfy Slot A's API 26-29 requirement
- Handshake stability: Slot A, Slot C, and Slot D all have 20/20 runs
- Throughput: Slot D and Slot C download/upload have passing 100MiB probes; Slot A is below the 20 MiB/s gate

### ❌ Not Yet Implemented

**Core Features (per M1 scope):**
- AOA transport path (blocked until ADB path completes M1)

**Remaining product UI (out of M1 scope):**
- Archived physical-device evidence for the new authenticated App pairing/reconnect/download path
- End-to-end file transfer under App Sandbox; bundle signing, embedded adb discovery, bookmark capture, stale refresh, access balancing, orphan pruning, private storage, manifest location, and disconnect lifecycle are implemented or locally verified
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
| ADB handshake ≥19/20 | ✅ Slot A/C/D passing | SHARP 704SH Slot A, MEIZU M20 Slot C, and NIO N2301 Slot D all logged 20/20 attempts; Pixel 9 Pro Fold API 37 also logged an unclassified 20/20 smoke |
| USB insertion ≤5s | ⚠️ Needs measurement | Device smoke shows "already authorized" |
| First list ≤1s (warm) | ✅ Slot A/C/D passing | SHARP 704SH Slot A measured `elapsed_ms=165`; NIO N2301 Slot D measured `elapsed_ms=98`; MEIZU M20 Slot C measured `elapsed_ms=84`; command wall time is logged separately |
| 100MB download ≥20 MiB/s | ❌ Slot A below gate | Slot C/D pass: NIO N2301 measured 48.95 MiB/s; MEIZU M20 measured 35.52 MiB/s. SHARP 704SH Slot A completed resume at 16.64 MiB/s, then 16.63 MiB/s while fully charged; the corresponding raw ADB baselines were 7.19 and 11.21 MiB/s |
| 100MB upload ≥20 MiB/s | ❌ Slot A below gate | Slot C/D pass: NIO N2301 measured 33.51 MiB/s; MEIZU M20 measured 20.22 MiB/s. SHARP 704SH Slot A completed resume at 15.20 MiB/s, then 15.70 MiB/s while fully charged |
| Download resume | ✅ Slot C real-device change/deletion passing | Partial + resume with fingerprint validation; MEIZU M20 rejected a one-byte source change with `invalidArgument` / `source fingerprint changed` and a deleted source with `notFound` / `app sandbox file is not available`; Android unit tests also cover missing, changed, and unavailable source fingerprints |
| App-sandbox upload resume | ✅ Implemented | Partial + resume with truncate/replay tolerance |
| Sidecar transport retry | ✅ Slot C/D passing | Fault injection passes with `recovered=true`; Slot C and Slot D logs record non-default retry policy where used |
| Fresh MediaStore upload | ✅ Slot C/D passing | Pictures/Movies collections; MEIZU M20 records fresh upload plus non-zero-offset resume rejection |
| Fresh SAF upload | ✅ Implemented | User-selected writable roots |
| SAF upload resume | ✅ Implemented | Transfer-id hidden partial documents |
| Permission-denied mapping | ✅ Slot C/D passing | Media listing revoke returns `permissionRequired`; media download revoke is archived on Slot D as expected transport loss and on Slot C as completed-after-revoke; grants are restored |
| Diagnostics attribution | ✅ Implemented | Service/permission/transfer state |
| Three-device coverage | ❌ Blocked by Slot A throughput | Required Slot A/C/D devices are now represented, but Slot A download/upload throughput is below the M1 gate |
| AOA viability (2 devices) | ❌ Blocked | Waiting for ADB path completion |

## Immediate Next Steps

### High Priority (M1 Blockers)

1. **Investigate Slot A throughput on SHARP 704SH (API 26):** charging is no longer an open variable: the fully charged rerun completed at 16.63 MiB/s download (11.21 MiB/s raw ADB baseline) and 15.70 MiB/s upload, still below the 20 MiB/s gate. Re-run through a different physical USB path (direct host port, cable, and no hub), record the raw ADB baseline again, then validate with a second API 26-29 device before changing protocol assumptions or the gate.

2. **Cover remaining abnormal/manual scenarios** that still lack archived evidence:
   USB unplug during upload/download. Slot C source mutation and deletion before resume are now covered by disposable app-sandbox scenarios.

### Medium Priority (M1 Enhancements)

3. **Close multi-stream device evidence and generalize it:**
   - Run and archive `--dual-download-check` on the required device slots
   - Run and archive `--mixed-transfer-check --mixed-upload-destination-path <fresh-target>` if mixed-direction evidence remains in M1 acceptance scope
   - Archive product-authenticated download and upload through the native queue on disposable device data

4. **Expand SAF upload testing:**
   - Test writable SAF directories on multiple OEMs
   - Verify partial document cleanup on non-final close
   - Document SAF provider quirks by vendor

5. **Integrate the persistent queue into the app target (post-M1):**
   - Supply the app-owned manifest URL and align restore/flush with scene lifecycle
   - Reacquire sandboxed local-file access without storing fake bookmark support in Core
   - Present `interrupted` and persistence-health state with explicit remove/re-submit UX

### Low Priority (Post-M1)

6. **USB timing measurements:**
   - Cable insertion to device-visible latency
   - Authorization flow timing
   - Reconnect after unplug/replug

7. **Large directory stress tests:**
   - 1000+ entry MediaStore listings
   - Product pager performance across repeated 1,000-entry pages
   - Provider memory usage

8. **AOA path exploration:**
   - After ADB passes M1 on 3 devices
   - Requires at least 2 AOA-capable devices
   - Throughput target: ≥30 MB/s

## Known Limitations

- **Authenticated persistent bidirectional App path, not a complete manager:** the localized SwiftUI target discovers devices through a serial-redacted async boundary, owns dynamic forward cleanup, performs SAS pairing or Keychain-backed proof, and activates browsing, diagnostics, native file panels, a device-isolated queue, and App-owned bookmark leases after authentication. The sandbox-entitled bundle discovered the connected 704SH and MEIZU M20 through its embedded adb with no observed sandbox denial; pairing/reconnect/file-transfer evidence under that bundle remains unarchived. Developer ID signing, notarization, and DMG remain unverified.
- **Structural debt remains outside file size:** all handwritten production and test files fit the default 1,000-line budget with no exceptions. Every non-transfer CLI network probe now uses the async transport, but synchronous transfer evidence probes and concentrated ownership remain; see [Structural Debt Baseline](technical-debt.md)
- **Scoped multi-stream support:** ordinary CLI download/upload commands remain single-transfer; `dual-download-smoke` and `mixed-transfer-smoke` are explicit probes. The mixed path and its preflighted 4 chunk / 2 MiB upload windows have local TCP evidence and a device-script entry, but no archived physical-device result yet.
- **Default single retry:** `--retry-on-transport-loss` keeps the legacy single retry unless `--max-retry-attempts N` is supplied
- **No automatic cleanup for SAF uploads:** Manual deletion required until delete/mutation protocol exists
- **MediaStore fresh-only:** Upload resume not supported (returns unsupportedCapability)
- **ADB loopback only:** Android endpoint rejects non-127.0.0.1 clients
- **Debug harness Activity required by legacy device evidence scripts:** Some OEM devices freeze the service `accept()` thread without a foreground Activity. This limitation describes the nonce-only smoke workflow, not the Android product launcher's paired-required policy.
- **Android 15 background service budget:** the ADB loopback endpoint uses the `dataSync` foreground-service type and is limited to six background hours per 24-hour window. Timeout closes the endpoint and stops the non-sticky service; a future AOA path can use `connectedDevice` only after obtaining a real USB accessory grant.

## Test Result Summary

As of 2026-07-10, `fixtures/m1-runs/` contains:
- 39 test result logs
- SHARP 704SH (Slot A, API 26) handshake/list and failing 100MiB throughput evidence, NIO N2301 (Slot D, API 34) broad matrix coverage, MEIZU M20 (Slot C, API 34) handshake/list, app-sandbox throughput/resume, permission, expected-error, MediaStore, and recovery evidence, and an unclassified Pixel 9 Pro Fold (API 37) two-device ADB routing smoke
- Coverage: app-sandbox upload (fresh/resume/100MB), app-sandbox download resume/100MB, real-device app-sandbox source mutation and deletion before resume, MediaStore upload, media permission revocation during listing and download, expected error boundaries, cancel, pause, Slot D handshake stability (20/20), Slot C handshake stability (20/20), Slot D/Slot C throughput assertions, ADB baseline download diagnostics, configurable recovery policy fault smoke, and app-sandbox ACK-loss replay
- Passing: Slot D windowed download measured 48.95 MiB/s with 1MiB chunks against a 75.70 MiB/s ADB baseline
- Passing: Slot D windowed upload measured 33.51 MiB/s with 1MiB chunks against the 20 MiB/s gate
- Passing: Slot D warm media-images list measured harness `elapsed_ms=98` against the 1000 ms gate
- Passing: Slot D media permission revocation returned `permissionRequired` for `dm://media-images/` and restored prior grants
- Passing: Slot D media permission revocation during `dm://media-images/media/1000001148` download observed `transport_lost_after_revoke` and restored prior grants
- Passing: MEIZU M20 Slot C warm media-images list measured harness `elapsed_ms=84` against the 1000 ms gate after 20/20 `m1-smoke` attempts
- Passing: MEIZU M20 Slot C app-sandbox 100MiB download resume measured 35.52 MiB/s after a 36.90 MiB/s ADB baseline
- Passing: MEIZU M20 Slot C app-sandbox 100MiB upload resume measured 20.22 MiB/s after the Mac harness send-limit fix
- Passing: MEIZU M20 Slot C media permission revocation returned `permissionRequired` for `dm://media-images/` and restored prior grants
- Passing: MEIZU M20 Slot C expected errors returned `notFound` for a missing SAF root and a missing app-sandbox download source
- Passing: MEIZU M20 Slot C MediaStore fresh upload succeeded after non-zero-offset upload resume returned `unsupportedCapability`
- Passing: MEIZU M20 Slot C app-sandbox upload ACK-loss replay recovered with `recovered=true`
- Passing: MEIZU M20 Slot C app-sandbox 100MiB download fault retry recovered with `recovered=true`
- Passing: MEIZU M20 Slot C media permission revocation during `dm://media-images/media/1000000054` download completed after revoke and restored prior grants
- Passing: MEIZU M20 Slot C changed a script-created 1MiB app-sandbox source to 1048577 bytes after a 262144-byte partial download; resume correctly returned `invalidArgument` / `source fingerprint changed`, and device/Mac temporary artifacts were cleaned
- Passing: MEIZU M20 Slot C deleted a script-created 1MiB app-sandbox source after a 262144-byte partial download; resume correctly returned `notFound` / `app sandbox file is not available`, and device/Mac temporary artifacts were cleaned
- Passing: SHARP 704SH Slot A handshake stability passed 20/20 attempts and warm `dm://media-images/` listing measured `elapsed_ms=165`
- Failing: SHARP 704SH Slot A app-sandbox 100MiB download resume completed, but throughput was 16.64 MiB/s against the 20 MiB/s gate; raw ADB baseline was 7.19 MiB/s
- Failing: SHARP 704SH Slot A app-sandbox 100MiB upload resume completed, but throughput was 15.20 MiB/s against the 20 MiB/s gate
- Failing, fully charged rerun: SHARP 704SH Slot A app-sandbox 100MiB download resume completed at 16.63 MiB/s against the 20 MiB/s gate; raw ADB baseline was 11.21 MiB/s
- Failing, fully charged rerun: SHARP 704SH Slot A app-sandbox 100MiB upload resume completed at 15.70 MiB/s against the 20 MiB/s gate
- Passing: Pixel 9 Pro Fold API 37 unclassified smoke passed 20/20 attempts with explicit serial routing while two ADB devices were connected
- Unit-covered abnormal paths: stale download resume source fingerprints, invalid page tokens, oversized envelopes, and bad transfer-chunk CRC32
- Missing: Slot A passing throughput evidence through another physical USB path or a second API 26-29 device; Slot C writable SAF and USB-abnormal coverage

## References

- [M1 Testing Guide](m1-testing-guide.md): step-by-step test instructions
- [M1 Device Matrix](m1-device-matrix.md): required devices and pass criteria
- [M0 Closeout](m0-closeout.md): specification decisions
- [Protocol Runtime](protocol-runtime.md): concurrency limits and backpressure
- [Protocol](protocol.md): message schemas and semantics
- [Path Model](path-model.md): logical path abstraction
