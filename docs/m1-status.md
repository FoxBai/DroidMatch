# M1 Status Summary

Last updated: 2026-07-14

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
- SwiftUI `DroidMatch` product target with English/Chinese device dashboard, canonical-path localization for built-in provider roots, readable navigation titles instead of opaque paths, async ADB discovery, process-local opaque device IDs, stale-snapshot disclosure, generated native icon, and a verified ad-hoc local `.app` bundle. A nonce-only debug endpoint is surfaced as `secureEndpointRequired` with an actionable Secure USB instruction rather than a generic transport failure.
- Product session lifecycle with anonymous dynamic forward leases, stable-identity Keychain selection, visible SAS approval, paired reconnect proof, authenticated paginated file browsing, and privacy-bounded structured diagnostics with schema-v1 allowlisted JSON export including bounded product/macOS versions and snapshot freshness. Locally tested heartbeat transport failure and echo mismatch now tear down the current gate/scheduler/client/forward before a buffered stable event removes all ready-only UI; explicit disconnect remains failure-free and paired trust is retained.
- Shared Mac envelope validation (`frame_version`, optional payload CRC, response/error request correlation)
- Enforced handshake nonce correlation plus locally tested first-pairing/reconnect security state machines; Slot C runs now archive ordinary-App visible-SAS pairing, Keychain-backed reconnect, idle keepalive and native download, plus sandbox-App pairing, browsing, download, and upload.
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
  - Atomic download writer with a pinned destination directory, no-follow
    regular partial, and same-directory final commit
- CLI harness with commands: devices, forward, handshake-smoke, m1-smoke, dual-download-smoke, mixed-transfer-smoke, list-dir, download, upload, etc.
- Throughput measurement (elapsed_ms, throughput_mib_per_sec)
- Opt-in versioned transfer-queue manifest with atomic writes, stable job/FIFO identity, private file permissions, sidecar-gated scheduler reconstruction, and non-replayable `interrupted` state
- Protobuf-free product directory domain types plus paged `AsyncRpcControlClient` listing, embedded-error/row/token validation, and a MainActor `DirectoryBrowserModel` with atomic refresh, loaded-row select/clear plus stale-selection reconciliation, retryable load-more, stale-generation rejection, cross-page deduplication, UI-only bidi/control-safe names that preserve remote identity, and sanitized failure state
- Separate `DroidMatchPresentation` library with a MainActor `TransferQueueModel`: ordered full-snapshot observation, explicit idempotent start/stop/restart, non-optimistic pause/resume/cancel/remove forwarding, precise post-unwind removal capability, and local-basename-only row state
- Authenticated persistent bidirectional product queue: readable files use a native save panel; writable app-sandbox/SAF/MediaStore directories use a native single-file picker; manifests are private and isolated by authenticated device fingerprint; every attempt creates a fresh paired RPC client behind a session gate; app-sandbox/SAF retries resume while MediaStore remains fresh-only; disconnect pauses recoverable work and interrupts unsafe work before releasing the forward
- MainActor `DeviceDiscoveryModel` with atomic refresh, cancellation/generation guards, sanitized failures, and no ADB serial in presentation state

**Android Side:**
- Foreground connection service
- One-shot ADB endpoint (loopback only, with timeouts, atomic stop/admission, and a fixed four-session worker/socket bound)
- Framed I/O (uint32_be length + payload)
- Allocation-bounded transfer hot path: one exact provider chunk buffer with
  trimming only for the final short read, one bulk four-byte frame-header write,
  and direct upload `TransferChunk` parsing from the envelope `ByteString`; wire
  framing and the 4-chunk / 2 MiB window are unchanged
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
  - MediaStore image albums (API 26–34 bucket aggregation, strict opaque tokens, lazy latest-image covers, and canonical media paths inside filtered views)
  - SAF (tree URI permissions, directory listing)
  - App sandbox (private files/droidmatch-sandbox)
- Provider features:
  - Download: seekable FD or stream with offset skip
  - App-sandbox download metadata and opaque source identity come from `fstat`
    on the already-open descriptor; same-size/same-mtime atomic replacement
    invalidates resume without a full-file pre-hash
  - Upload: hidden partial files and fail-closed durable atomic commit on final
    chunk; app-sandbox opens resume partials through one no-follow channel,
    forces that descriptor before close/replacement, and never downgrades a
    synchronization failure or unsupported atomic replacement
  - App-sandbox listing omits symbolic links; recursive delete unlinks a link
    entry without traversing or deleting through its target
  - MediaStore final commit requires an item-scoped pending-row publication to
    affect exactly one row; a missing/rejected row fails before final ACK and is
    cleaned up instead of being reported as a successful upload
  - Resume: source fingerprint validation (download), partial offset validation (upload)
  - ACK loss tolerance (app-sandbox upload truncate/replay)
- Permission state provider
- Diagnostics reporter (with concurrent test coverage)
- Debug harness Activity (separate nonce-only evidence path used by device scripts)
- Product launcher entry (`DroidMatchActivity`) with a tested next-step readiness summary, paired-required endpoint controls, pairing approval, secret-free paired-Mac list/revoke, notification permission, and SAF authorization list/add/revoke; trust revocation closes active USB sessions, while diagnostics harness naming remains confined to debug source
- Explicit no-backup/no-device-transfer rules for private app, pairing, SAF, transfer, and diagnostics state
- Original adaptive-vector launcher mark with Android 13+ monochrome themed-icon support

**Tooling:**
- `tools/check-source-size.py`: one 800-line ceiling for every handwritten production, unit-test, and instrumentation-test source file; no legacy exceptions remain
- `tools/run-m1-device-smoke.sh`: comprehensive device test script that builds/invokes the Mac harness in Swift release configuration, maps unreadable Git state to unknown provenance, validates a private staged log, and publishes without following or replacing an existing result path; it includes opt-in `--dual-download-check` and `--mixed-transfer-check` with a distinct fresh upload target
- `tools/run-m1-throughput-gate.sh`: fail-closed Slot A `m1-adb-throughput-v1` profile requiring command-error-aware clean full-SHA current-main provenance, API 26–29, exact fresh 100MiB download/upload, raw ADB baseline, requested/negotiated 1MiB chunks, both ≥20 MiB/s thresholds, privacy-bounded output, verified cleanup, staged single-log validation, and atomic no-clobber fixture publication
- `tools/run-product-usb-insertion-smoke.sh`: attended `m1-product-usb-insertion-v1` profile with a pre-signal absence check, monotonic-before-signal boundary, exact discovery-card AX identifier, verified running release bundle provenance, explicit physical-action attestation, and atomic validated fixture publication
- `tools/check-product-usb-insertion-logs.sh`: strict dedicated product-insertion fixture schema, provenance, privacy, timing, and count validation
- `tools/m1-fault-proxy.py`: local frame proxy for fault injection
- `tools/check-m1-skeleton.sh`: CI validation
- `tools/check-m1-run-logs.sh`: quiet privacy rejection plus directory or staged single-log profile validation
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
- The isolated AndroidX instrumentation runner passed on Slot C MEIZU M20 after the user manually approved the test-APK installation prompt: the stable P-256 identity and AES wrapping key remained non-exportable, while signing, encrypted-record reopen, and revoke round trips succeeded. This is attended evidence, not an unattended-install claim; the runner removed only its test package and preserved the product install/data boundary.
- Mac and Android both expose secret-free trust management. Mac revocation waits for active-session teardown before deleting the Keychain record; Android revocation closes active USB sessions. Slot C ordinary-App first pairing, paired reconnect, sandboxed product authentication, and attended real Android Keystore behavior are archived.

**Transfer Features:**
- Transport-loss retry: configurable multi-attempt recovery queue now implemented
  via `RecoveryPolicy` (exponential backoff, attempt cap, sidecar-gated retry).
  - Default `--retry-on-transport-loss` still reproduces the legacy single retry
    for backward-compatible matrix scripts.
  - `--max-retry-attempts N` enables up to N additional reconnect attempts.
  - `--retry-backoff-ms M` overrides the base backoff (default 500 ms).
  - Unit + end-to-end tests cover backoff timing, attempt exhaustion, and
    multi-loss recovery on a local fault-injecting server.
  - Core has an opt-in on-disk queue manifest and restoration factory. The Mac App supplies a private per-device Application Support location, derives an opaque bookmark owner after authenticated proof, exposes its storage key only to AppSupport SPI, forces normal/debug/reflection output to remain redacted, and builds the persistent scheduler as a generation-bound single-flight. Concurrent callers share one restore; disconnect cancels the build and tears down its registered gate/scheduler before either can be revived by stale actor re-entry. Restoration stays behind an execution latch and verifies every non-terminal local endpoint against that owner's transactionally persisted App-owned bookmarks before activation. Archive v2 prevents another device's empty queue or same-path record from pruning or satisfying scoped authority. Version-1 path-only entries remain a separate legacy-unscoped fallback and are neither guessed into an owner nor cleaned in this phase. Corrupt/unreadable recovery state, or a bookmark archive empty, incomplete, or scoped only to another owner for those restored targets, stays `writeFailed` without replay; one explicit retry reloads bookmarks, reloads the manifest without execution, verifies the resulting owner coverage, then unlocks the scheduler. Session teardown irreversibly invalidates the old scheduler after its conservative suspension write, so delayed UI actions cannot resume work or overwrite a replacement manifest.
- Concurrency: both the stable M1 probe and product async core have bounded two-stream paths
  - Open responses and chunks are routed by request/stream ID and serviced fairly
  - Android enforces a two-active-transfer limit per session across both directions
  - The shared Android provider rejects a second concurrent upload to the same canonical app-sandbox, SAF, or MediaStore destination across sessions; distinct destinations remain independent, and JVM tests cover release after commit, abort, cancel, failed open, and session teardown
  - Local TCP end-to-end coverage proves interleaving and a responsive heartbeat before first-chunk ACKs
  - Duplicate transfer IDs are rejected before the stream limit, keeping transfer-level controls deterministic
  - The product async router locally interleaves a refilling download, a preflighted four-chunk upload window, and heartbeat with one reader
  - Every multiplexed write passes one FIFO admission gate. Download ACKs and upload chunks re-read their route and handle-shared first terminal error after acquiring the gate, so a queued write cannot outlive route teardown and recovery still receives the original retryable transport error or typed remote error instead of a secondary inactive-route failure.
  - Protocol cancellation wakes the pending upload window without closing the session; a following heartbeat proves reuse
  - Product async download writes on a private serial file queue, keeps the old destination until final ACK, preserves partial data on cancel, and rejects a changed resume offset before accepting bytes
  - `AsyncDownloadCoordinator` now reloads shared Core sidecars, reconnects through an injected authenticated-client factory, and resumes with the same transfer ID, actual partial offset, and accepted source fingerprint; local TCP coverage drops the first session and verifies atomic completion on the second
  - `AsyncUploadCoordinator` now performs serial stable-source reads, four-chunk/two-MiB refill, per-ACK sidecar commits, and app-sandbox/SAF reconnect; local TCP coverage proves replay from the last ACK and cancellation checkpoint retention
  - `AsyncTransferScheduler` provides FIFO admission, a two-job cap, buffering-newest queued/running/retrying/pausing/paused/interrupted/terminal snapshots, monotonic receiver-confirmed bytes/total across retries, a two-second time-weighted recent-throughput sample, retry visibility, completion waiting, cancellation, and checkpoint pause/resume. It remains process-local by default; `restoring(...)` opts into a versioned atomic manifest, writes queued-to-active intent before starting an executor, and can hold every start path behind product authorization readiness. It restores only matching download/app-sandbox/SAF sidecars and keeps unsafe active work (including MediaStore) visible as non-replayable `interrupted`. Queued pause is a hold; running checkpoint pause closes only that coordinator session and requeues the same job/transfer identity. This local policy does not claim Android wire upload pause.
  - Dual/mixed probes are both script-invocable; download and provider-aware upload scheduling are wired into the authenticated visual target with device-isolated persistence, App-owned security-scoped bookmark leases, and lifecycle-ordered suspension. Slot C archives ordinary-App pairing/reconnect/download and sandbox-App pairing/browsing/download/upload. Sandbox uploads keep checkpoints in the App-owned device queue directory rather than beside a read-only-authorized source.

**Testing Coverage:**
- Slot D device (NIO N2301, API 34): extensive coverage
- Slot A (SHARP 704SH, API 26): required-slot handshake/list evidence is archived; the two functional 100MiB resume probes used the old debug/Onone Mac harness and predate the current transfer optimizations, so their sub-20 MiB/s results are historical diagnostics rather than current-tip gate evidence
- Slot C (MEIZU M20, API 34): handshake/list, app-sandbox 100MiB download/upload resume throughput, permission revocation, expected errors, MediaStore fresh-only upload, sidecar/ACK-loss recovery, writable SAF resume/recovery, and real-device source-mutation/deletion rejection coverage
- Unclassified: Pixel 9 Pro Fold (API 37) has a 20/20 two-device ADB routing smoke, but it does not satisfy Slot A's API 26-29 requirement
- Handshake stability: Slot A, Slot C, and Slot D all have 20/20 runs
- Throughput: Slot D and Slot C download/upload have archived passing 100MiB probes; Slot A still needs current-tip release-configured download and upload evidence at or above 20 MiB/s

### Deferred Transport and Release Work (not current ADB M1 blockers)

The only open ADB M1 blockers are Slot A current-candidate release throughput and
attended product USB insertion evidence on Slot A/C/D. They are listed with their
exact runners under **High Priority (M1 Blockers)** below.

**Experimental transport (after the ADB M1 path):**
- AOA transport implementation and its separate two-device promotion gate

**Verified product status and remaining release gap:**
- Slot C ordinary and sandbox authenticated App pairing/reconnect, browsing, bidirectional transfer, trust revocation, and forced-relaunch upload recovery are archived
- Bundle structure/ad-hoc signing, embedded adb discovery, bookmark lifecycle, private queue storage, and disconnect handling are locally verified; Developer ID signing and notarization remain explicitly deferred release work, not an ADB M1 blocker
- Native Settings and privacy-bounded opt-in transfer notifications are implemented; security and destructive-operation safeguards intentionally remain non-configurable

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
| USB insertion ≤5s | ⚠️ Fail-closed product/AX evidence path implemented; needs physical measurement | The foreground-active Mac App performs non-overlapping one-second discovery refreshes. The runner requires a unique verified current-main release App, stable discovery-card AX identifier, pre-signal absence, explicit `INSERT NOW` monotonic boundary, and post-run physical-action attestation; zero attended fixtures are archived so far |
| First list ≤1s (warm) | ✅ Slot A/C/D passing | SHARP 704SH Slot A measured `elapsed_ms=165`; NIO N2301 Slot D measured `elapsed_ms=98`; MEIZU M20 Slot C measured `elapsed_ms=84`; command wall time is logged separately |
| 100MB download ≥20 MiB/s | ❌ Slot A current-tip evidence missing | Slot C/D have archived passes. SHARP 704SH's 16.64/16.63 MiB/s runs used the old debug/Onone harness and predate the current transfer optimizations, so they are diagnostics rather than a current-tip failure or pass |
| 100MB upload ≥20 MiB/s | ❌ Slot A current-tip evidence missing | Slot C/D have archived passes. SHARP 704SH's 15.20/15.70 MiB/s runs used the same stale execution path and must be repeated with the release-configured runner |
| Download resume | ✅ Slot C real-device interruption/change/deletion/same-metadata replacement passing | Attended 10GiB physical unplug preserved a 3,626,762,240-byte durable partial, reconnected the same device, and resumed to the exact final size. MEIZU M20 also rejected a one-byte source change and a same-size/same-full-mtime atomic replacement with stable `invalidArgument`, and a deleted source with stable `notFound`; the replacement probe passed on exact main `0b4d858`, with provider detail and raw filesystem identity omitted. |
| App-sandbox upload resume | ✅ Implemented | Partial + resume with truncate/replay tolerance |
| Sidecar transport retry | ✅ Slot C/D passing | Fault injection passes with `recovered=true`; Slot C and Slot D logs record non-default retry policy where used |
| Fresh MediaStore upload | ✅ Slot C/D passing | Pictures/Movies collections; MEIZU M20 records fresh upload plus non-zero-offset resume rejection |
| Fresh SAF upload | ✅ Slot C passing | User-selected writable root; disposable grant and files removed after evidence |
| SAF upload resume | ✅ Slot C passing | Transfer-id hidden partial documents; 10MiB resume measured 27.36 MiB/s |
| Permission-denied mapping | ✅ Slot C/D passing | Media listing revoke returns `permissionRequired`. Chunk-time `SecurityException` is normalized to `permissionRequired` for MediaStore/SAF and `internal` for app-sandbox, but an OS permission change may still tear down the endpoint before a typed error reaches Mac. Slot C and Slot D both archive that valid transport-loss outcome; grants are restored. |
| Diagnostics attribution | ✅ Implemented | Service/permission/transfer state |
| Three-device coverage | ❌ Throughput and insertion gates incomplete | Required Slot A/C/D devices are represented, but Slot A lacks current-tip release-configured download/upload throughput evidence and every required device still needs archived attended product USB insertion ≤5s evidence |
| AOA viability (2 devices) | ❌ Blocked | Waiting for ADB path completion |

## Immediate Next Steps

### High Priority (M1 Blockers)

1. **Re-establish current-tip Slot A throughput on SHARP 704SH (API 26):** the archived 16.63 MiB/s download and 15.70 MiB/s upload rerun used the old debug/Onone Mac harness and predates the current transfer optimizations. Re-run through a direct host port/cable with `tools/run-m1-throughput-gate.sh --serial <serial> --expected-main-sha <40-hex>` so one versioned profile records the raw ADB baseline, exact fresh 100MiB download/upload, actual negotiated chunks, thresholds, provenance, privacy boundary, and cleanup verification. A second API 26-29 device is a recommended non-gating cross-check before changing protocol assumptions or the threshold. Do not claim failure or success from the stale numbers.

2. **Archive attended product USB insertion ≤5s on every required device:** run
   `tools/run-product-usb-insertion-smoke.sh` with `--device-slot`, the exact
   clean `--expected-main-sha`, the running release `--app-bundle`, and a new
   `--result-log` on Slot A, Slot C, and Slot D. ADB visibility alone is not
   product evidence, and no slot passes until its validated physical-insertion
   fixture is archived.

**Evidence maintenance (not an open M1 blocker):** Slot C archives attended
physical USB unplug/reconnect/resume for both download and upload, plus source
mutation, deletion, and same-metadata replacement rejection. The replacement
probe passed on exact main `0b4d858` with privacy-bounded output and verified
cleanup. Re-run these dedicated cases only when regression evidence is needed.

### Medium Priority (M1 Enhancements)

3. **Generalize the archived multi-stream device evidence:**
   - ✅ Slot C MEIZU M20 `--dual-download-check` and
     `--mixed-transfer-check --mixed-upload-destination-path <fresh-target>`
     passed on one async session with responsive heartbeats and are archived
   - Extend the same probes to Slot A/D only when they are needed to distinguish
     device-specific behavior; Slot C evidence is no longer an open gate
   - ✅ Ordinary ad-hoc App product-authenticated download is archived on disposable Slot C data
   - ✅ Archive product-authenticated 1MiB download and upload under the sandboxed bundle
   - ✅ Forced sandbox-App termination restored the upload as paused, reacquired its bookmark, and completed attempt 2 from the durable checkpoint

4. **Expand SAF upload testing:**
   - Test writable SAF directories on multiple OEMs
   - ✅ Smoke cleanup now removes direct-root single-file SAF targets through a
     fresh protocol `delete-path` session; nested process-local document
     tokens and recursive directory cleanup remain explicit/manual
   - ✅ Local writer coverage verifies that non-final non-resumable uploads
     delete their incomplete document, resumable uploads retain their hidden
     partial, and a completed resumable upload renames without deleting the
     committed document
   - Repeat the same cleanup/preservation cases on writable SAF providers from
     multiple OEMs
   - Document SAF provider quirks by vendor

5. **Exercise persistent queue recovery in the signed sandbox App (post-M1 evidence):**
   - Archive a restart with a resumable queued transfer and the same authenticated device
   - Archive stale bookmark refresh plus balanced security-scope release
   - Confirm `interrupted` and the implemented persistence-health retry UI on deliberately disposable physical state

### Low Priority (Post-M1)

6. **Large directory stress tests:**
   - ✅ Local correctness baseline: a real app-sandbox catalog paginates 1,005
     files as 1,000 + 5, and the product model preserves order/uniqueness across
     1,205 entries in three pages
   - 1000+ entry MediaStore listings
   - Product pager performance across repeated 1,000-entry pages
   - ✅ Slot C end-to-end app-sandbox provider pagination: a disposable 1,005
     entry directory returned 1,000 + 5 rows in 833 ms with aggregate-only
     evidence and verified cleanup
   - ✅ Local Java memory shape: app-sandbox streams directory entries and both
     app-sandbox/SAF retain at most the leading `offset + pageSize` candidates;
     MediaStore pushes limit/offset/sort to `ContentResolver`
   - ✅ Slot C process-level diagnostic: paging 1,005 app-sandbox entries while
     sampling aggregate PSS observed 31,664 KiB at baseline and 38,313 KiB peak
     (6,649 KiB delta); this is device evidence, not a heap-allocation proof or
     a portable memory ceiling

7. **AOA path exploration:**
   - After ADB passes M1 on 3 devices
   - Requires at least 2 AOA-capable devices
   - Throughput target: ≥30 MB/s

## Known Limitations

- **Authenticated persistent bidirectional App path, not a complete manager:** the localized SwiftUI target discovers devices through a serial-redacted async boundary, owns dynamic forward cleanup, performs SAS pairing or Keychain-backed proof, and activates browsing, diagnostics, native file panels, a device-isolated queue, and App-owned bookmark leases after authentication. The sandbox-entitled bundle has archived MEIZU M20 pairing, browsing, 1MiB bidirectional transfer, and a 4GiB upload resumed after forced termination. A compressed local DMG with Applications link, SHA-256 sidecar, read-only mount verification, and mounted-App revalidation is implemented; Developer ID signing and notarization remain unverified.
- **Structural debt remains outside file size:** all handwritten production and test files fit the default 800-line budget with no exceptions, and every product/CLI network path uses the async transport. The file-browser toolbar, transfer persistence mapping, transfer-frame construction, scheduler test support, and framed-server state/readers/response values have explicit boundaries; contribution and PR handoff evidence is CI-enforced, but single-owner release authority remains concentrated; see [Structural Debt Baseline](technical-debt.md)
- **Scoped multi-stream support:** ordinary CLI download/upload commands remain single-transfer; `dual-download-smoke` and `mixed-transfer-smoke` are explicit probes. The mixed path and its preflighted 4 chunk / 2 MiB upload windows have local TCP evidence, a device-script entry, and archived Slot C physical-device results.
- **Default single retry:** `--retry-on-transport-loss` keeps the legacy single retry unless `--max-retry-attempts N` is supplied
- **Resumable SAF partial lifecycle:** Non-final non-resumable uploads are
  deleted, while transfer-ID uploads deliberately retain their hidden partial.
  The smoke runner now cleans direct-root single-file SAF destinations through
  the protocol delete mutation; abandoned resumable partials and nested
  process-local document-token targets still require explicit cleanup.
- **MediaStore fresh-only:** Upload resume not supported (returns unsupportedCapability)
- **Initial album index cost:** Consistent API 26–34 behavior requires one streaming scan of MediaStore bucket columns while memory grows only with album count. A bounded LRU prevents per-cover rescans; resolving an old token after service restart may perform one fallback scan.
- **ADB loopback only:** Android endpoint rejects non-127.0.0.1 clients
- **Debug harness Activity required by legacy device evidence scripts:** Some OEM devices freeze the service `accept()` thread without a foreground Activity. This limitation describes the nonce-only smoke workflow, not the Android product launcher's paired-required policy.
- **Android 15 background service budget:** the ADB loopback endpoint uses the `dataSync` foreground-service type and is limited to six background hours per 24-hour window. Timeout closes the endpoint and stops the non-sticky service; a future AOA path can use `connectedDevice` only after obtaining a real USB accessory grant.

## Test Result Summary

As of 2026-07-14, `fixtures/m1-runs/` contains:
- 87 test result logs
- SHARP 704SH (Slot A, API 26) handshake/list and historical 100MiB throughput diagnostics, NIO N2301 (Slot D, API 34) broad matrix coverage, MEIZU M20 (Slot C, API 34) handshake/list, app-sandbox throughput/resume, permission, expected-error, MediaStore, and recovery evidence, and an unclassified Pixel 9 Pro Fold (API 37) two-device ADB routing smoke
- Coverage: app-sandbox upload (fresh/resume/100MB), app-sandbox download resume/100MB, real-device app-sandbox source mutation, deletion, and same-metadata atomic replacement before resume, MediaStore upload, media permission revocation during listing and download, expected error boundaries, cancel, pause, Slot D handshake stability (20/20), Slot C handshake stability (20/20), Slot D/Slot C throughput assertions, ADB baseline download diagnostics, configurable recovery policy fault smoke, and app-sandbox ACK-loss replay
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
- Passing: after the send-admission and permission-read fixes, MEIZU M20 Slot C repeated a 10MiB MediaStore fresh upload at 25.38 MiB/s, then separately reran revoke-during-download against a prepared 10MiB MediaStore item. The rerun observed `transport_lost_after_revoke` and restored prior grants. A subsequent archived cleanup check found zero rows for the exact disposable upload name and zero default local download/partial/sidecar artifacts; the archived pre-fix run remains failed because a secondary inactive-route error masked the original failure.
- Passing: MEIZU M20 Slot C app-sandbox upload ACK-loss replay recovered with `recovered=true`
- Passing: MEIZU M20 Slot C app-sandbox 100MiB download fault retry recovered with `recovered=true`
- Passing: an earlier MEIZU M20 Slot C media permission revocation during `dm://media-images/media/1000000054` download completed after revoke and restored prior grants; the later 10MiB regression above exercised the mid-stream failure path and observed transport loss
- Passing: MEIZU M20 Slot C changed a script-created 1MiB app-sandbox source to 1048577 bytes after a 262144-byte partial download; resume correctly returned stable `invalidArgument` with fingerprint detail redacted, and device/Mac temporary artifacts were cleaned
- Passing: MEIZU M20 Slot C deleted a script-created 1MiB app-sandbox source after a 262144-byte partial download; resume correctly returned stable `notFound` with provider detail redacted, and device/Mac temporary artifacts were cleaned
- Passing: MEIZU M20 Slot C on exact main `0b4d858` atomically replaced a
  script-created 1MiB App Sandbox source after a 262144-byte partial download;
  size/full mtime remained equal, inode/content changed, resume returned stable
  `invalidArgument`, raw metadata remained omitted, and device/Mac temporary
  artifacts were cleaned
- Passing: MEIZU M20 Slot C combined source-deletion, cancel, pause, and app-sandbox ACK-loss recovery smoke on commit `a897e70`; deletion returned stable `notFound`, the disposable source was recreated before cancel/pause, 20/20 handshakes and dual download passed, and the 10MiB ACK-loss upload recovered at 27.03 MiB/s
- Passing: MEIZU M20 Slot C isolated Android Keystore instrumentation on current main commit `aaf332a8`; both non-exportable identity/signing and AES wrapping/reopen/revoke tests passed (`OK (2 tests)`), the test package was removed, and the product package/data boundary was preserved
- Passing: SHARP 704SH Slot A handshake stability passed 20/20 attempts and warm `dm://media-images/` listing measured `elapsed_ms=165`
- Historical diagnostic only: SHARP 704SH Slot A app-sandbox 100MiB download resume completed at 16.64 and 16.63 MiB/s, with raw ADB baselines of 7.19 and 11.21 MiB/s
- Historical diagnostic only: SHARP 704SH Slot A app-sandbox 100MiB upload resume completed at 15.20 and 15.70 MiB/s
- Those Slot A runs used the old debug/Onone Mac harness and predate the current transfer optimizations; they neither pass nor fail current-tip throughput and must be rerun with the release-configured runner
- Passing: Pixel 9 Pro Fold API 37 unclassified smoke passed 20/20 attempts with explicit serial routing while two ADB devices were connected
- Unit-covered abnormal paths: stale download resume source fingerprints, invalid page tokens, oversized envelopes, and bad transfer-chunk CRC32
- Passing: Slot C ordinary ad-hoc product App visible-SAS pairing, fresh authentication, Keychain-backed reconnect, four idle heartbeats across the old 30-second boundary, authenticated app-sandbox listing, and native-queue 1MiB download with cleanup
- Passing: Slot C sandboxed product App visible-SAS authentication, app-sandbox listing, directory-authorized 1MiB download, App-owned-checkpoint 1MiB upload, matching hashes, and cleanup
- Passing: the current ordinary product App paired with MEIZU M20 through paired-required secure USB after a local equality-only SAS comparison, persisted trust on both platforms, reconnected without another SAS prompt, browsed live roots after reconnect, exposed a healthy empty queue and privacy-bounded paired-proof diagnostics, then released all ADB forwards and stopped secure USB while retaining trust
- Passing: Slot C sandbox App restored a 4GiB upload after `SIGKILL` as an explicit paused job, reacquired its source bookmark, resumed attempt 2 from 598,999,040 bytes, matched the final hash, and cleaned managed recovery state
- Passing: MEIZU M20 Slot C physically disconnected during a 10GiB app-sandbox download after a 3,626,762,240-byte durable partial; the same serial reconnected with a new transport identity and resumed the remaining 7,110,656,000 bytes at 28.35 MiB/s to the exact final size
- Missing: current-tip release-configured Slot A ≥20 MiB/s download and upload evidence through a direct physical USB path; a second API 26-29 device remains a recommended non-gating cross-check
- Missing: attended product USB insertion ≤5s evidence on each required Slot A/C/D device

`fixtures/product-usb-insertion/` contains:
- 0 product USB insertion evidence logs

## References

- [M1 Testing Guide](m1-testing-guide.md): step-by-step test instructions
- [M1 Device Matrix](m1-device-matrix.md): required devices and pass criteria
- [M0 Closeout](m0-closeout.md): specification decisions
- [Protocol Runtime](protocol-runtime.md): concurrency limits and backpressure
- [Protocol](protocol.md): message schemas and semantics
- [Path Model](path-model.md): logical path abstraction
