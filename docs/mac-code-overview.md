# Mac Side Code Overview

This document provides a quick orientation to the Mac-side codebase for developers joining the project.

## Directory Structure

```
mac/
├── Sources/
│   ├── DroidMatchCore/         # Core library (transport, protocol, clients)
│   │   ├── Generated/          # Protobuf generated files (do not edit manually)
│   │   │   └── v1/             # Protocol v1 messages (rpc, transfer, device, etc.)
│   │   ├── AdbClient.swift     # ADB command wrapper (devices, forward)
│   │   ├── DeviceDiscovery.swift # Async product discovery + serial isolation
│   │   ├── FrameCodec.swift    # Length-prefixed frame encoding/decoding
│   │   ├── FrameReader.swift   # Streaming frame reader
│   │   ├── AsyncFramedTcpSession.swift # Product-facing async transport actor
│   │   ├── TransportError.swift # Stable async transport errors
│   │   ├── RpcEnvelopeCodec.swift # Shared envelope construction/validation
│   │   ├── AsyncRpcControlClient.swift # Product-facing async RPC actor
│   │   ├── AsyncRpcMultiplexer.swift # Single-reader control/stream router
│   │   ├── AsyncRpcTransferControl.swift # Async cancel/pause control
│   │   ├── AsyncRpcRoutingState.swift # Route records + pure transfer validation
│   │   ├── AsyncRpcOneShot.swift # Callback/async response race boundary
│   │   ├── AsyncTransferHandles.swift # Public download/upload actors + bounded chunk queue
│   │   ├── TransferWireMetadata.swift # Opaque inactive-side upload labels
│   │   ├── AsyncAtomicDownloadWriter.swift # Non-blocking serial file-I/O adapter
│   │   ├── TransferResumeRecords.swift # Shared camelCase download/upload sidecars
│   │   ├── AsyncTransferResumeStore.swift # Serial durable checkpoint I/O
│   │   ├── AsyncDownloadCoordinator.swift # Product download reconnect/resume scheduler
│   │   ├── AsyncUploadFileSource.swift # Stable serial source-file reader
│   │   ├── AsyncUploadFileSender.swift # Shared bounded window file pump
│   │   ├── AsyncUploadCoordinator.swift # Product window refill/reconnect scheduler
│   │   ├── AsyncMixedTransferSmokeClient.swift # Async mixed-direction device probe
│   │   ├── AsyncTransferProgress.swift # Receiver-confirmed progress value
│   │   ├── AsyncTransferRateEstimator.swift # Monotonic rolling rate
│   │   ├── AsyncTransferScheduler.swift # Observable FIFO product job queue
│   │   ├── AsyncTransferSchedulerTypes.swift # Public queue contract + retry relay
│   │   ├── TransferQueuePersistence.swift # Versioned atomic queue manifest
│   │   ├── DirectoryListing.swift # Protobuf-free paged listing domain
│   │   ├── AsyncPairingClient.swift # One-shot first-pairing coordinator
│   │   ├── SessionAuthenticator.swift # Canonical auth transcript/HMAC/HKDF
│   │   ├── PairingAuthenticator.swift # P-256/SAS/identity verification
│   │   ├── PairingCredentialStore.swift # Non-sync Keychain records
│   │   ├── HandshakeSmokeClient.swift # ClientHello/ServerHello test
│   │   ├── M1SmokeClient.swift # Async baseline control-plane smoke
│   │   ├── TransferResults.swift # Shared async transfer result values
│   │   ├── RpcControlClientError.swift # Shared RPC validation errors
│   │   ├── AtomicDownloadWriter.swift # Download partial → final commit
│   │   ├── ProcessRunner.swift # Subprocess execution helper
│   │   ├── LockedValue.swift   # Thread-safe value wrapper
│   │   └── Crc32.swift         # CRC32 checksum
│   ├── DroidMatchPresentation/ # MainActor native product-state boundary
│   │   ├── DeviceDiscoveryModel.swift
│   │   ├── DirectoryBrowserModel.swift
│   │   ├── TransferQueueDataSource.swift
│   │   ├── TransferQueuePresentationItem.swift
│   │   └── TransferQueueModel.swift
│   ├── DroidMatchApp/          # Localized SwiftUI product shell
│   │   ├── DroidMatchDesktopApp.swift
│   │   ├── AppShellView.swift
│   │   ├── DeviceDashboardView.swift
│   │   ├── AppStrings.swift
│   │   └── Resources/          # English and Simplified Chinese strings
│   └── DroidMatchHarness/      # CLI tool for testing
│       ├── main.swift          # Dispatcher, control probes, shared parsing
│       └── HarnessTransferCommands.swift # Download/upload CLI probes
├── Tests/
│   ├── DroidMatchCoreTests/    # Unit tests for core library
│   └── DroidMatchPresentationTests/ # UI-state/lifecycle privacy tests
├── App/Info.plist              # Local bundle metadata
├── Package.swift               # SwiftPM manifest, including DroidMatch app product
└── README.md                   # Mac-side README
```

## Key Components

### Transport Layer

**FrameCodec** (`FrameCodec.swift`)
- Encodes/decodes length-prefixed frames: `uint32_be length + payload`
- Max frame size: 4 MiB
- Used for all ADB M1 communication

**FrameReader** (`FrameReader.swift`)
- Streaming frame parser
- Handles partial reads from TCP socket
- Accumulates bytes until full frame is available

**AsyncFramedTcpSession** (`AsyncFramedTcpSession.swift`)
- Product-facing, non-blocking `NWConnection` boundary; the callback API is bridged with checked continuations rather than semaphores
- Serializes each complete request/response round-trip with a cancellation-aware FIFO operation lock; actor isolation alone is not treated as a cross-`await` mutex
- Races completion, timeout, and task cancellation through a one-shot result gate, then closes ambiguous sessions instead of reusing them
- Powers every CLI and product RPC/transfer path; the former semaphore transport has been deleted
- Selects either FIFO round-trip or multiplexed mode for the connection lifetime; multiplexed mode keeps one independent reader and serialized writers

**AdbDeviceDiscovery / DeviceDiscoveryModel** (`DeviceDiscovery.swift`, `DroidMatchPresentation/DeviceDiscoveryModel.swift`)
- Runs the bounded blocking `adb devices -l` process on a private serial queue, never MainActor
- Keeps raw ADB serials inside the Core actor and emits process-local opaque UUIDs plus model/product/state only
- Prefers `Contents/Resources/platform-tools/adb` in an assembled product; explicit environment and SDK paths remain development fallbacks
- Normalizes missing/failed/timed-out ADB into stable error categories rather than forwarding process stderr
- Sorts ready devices first, deduplicates malformed repeated serial rows, and keeps one UUID stable only while the device remains visible
- Atomically replaces successful MainActor snapshots, marks retained rows stale after failure, and rejects late refresh generations
- Powers the first real SwiftUI product page; it does not create a transport/session or mutate a device

### Protocol Layer

**RpcEnvelopeCodec** (`RpcEnvelopeCodec.swift`)
- Shares request construction and response validation across async harness and product clients
- Requires M1 `frame_version = 1` and validates `payload_crc32` when flag bit 0 is present
- Correlates response and error envelopes by request ID before parsing remote errors
- Validates frame kind and payload type without owning any transport state

**SessionAuthenticator** (`SessionAuthenticator.swift`)
- Builds the canonical big-endian session-auth transcript without serializing protobuf
- Uses CryptoKit SHA-256, role-separated HMAC-SHA-256, constant-time HMAC verification, and HKDF-SHA-256
- Matches Android byte-for-byte through `fixtures/crypto/session-auth-v1.properties`
- Is wired into `AsyncRpcControlClient` for paired reconnect

**PairingAuthenticator** (`PairingAuthenticator.swift`)
- Uses CryptoKit P-256 ECDH and rejects malformed X9.63 peer keys
- Verifies the stable Android P-256 identity signature before approval
- Matches Android transcript, identity fingerprint, HKDF outputs, unbiased six-digit SAS, and three role-separated confirmations through one fixed vector

**AsyncPairingClient** (`AsyncPairingClient.swift`)
- Runs one ordered start/confirm/finalize exchange over `AsyncFramedTcpSession`
- Presents only Android name, six-digit SAS, and identity fingerprint to an async product approval boundary
- Writes the credential provisionally after mutual confirmation and revokes it if finalize fails
- Has loopback tests for success, invalid identity, user rejection, and rollback; the native Mac UI remains open

**KeychainPairingCredentialStore** (`PairingCredentialStore.swift`)
- Stores a versioned pairing record as a non-synchronizing generic-password item
- Exposes key-free metadata for list/rename/revoke UI and rejects pairing-ID/device-fingerprint collisions
- Uses an injected Keychain backend in tests so unit runs never touch the developer's real login Keychain

**Generated Protobuf Files** (`Generated/v1/*.pb.swift`)
- `rpc.pb.swift`: `RpcEnvelope`, `RpcRequest`, `RpcResponse`, `RpcError`
- `session.pb.swift`: Hello/authentication/heartbeat messages and authentication state
- `device.pb.swift`: `DeviceInfoRequest`, `DeviceInfoResponse`
- `file.pb.swift`: `ListDirRequest`, `ListDirResponse`, `DmFileEntry`
- `transfer.pb.swift`: `OpenTransferRequest`, `OpenTransferResponse`, `TransferChunk`, `TransferChunkAck`, `CancelTransferRequest`, `PauseTransferRequest`
- `error.pb.swift`: `ErrorCode` enum
- Generated by `protoc` from `proto/v1/*.proto`
- Regenerate with: `bash tools/generate-swift-proto.sh`

### Client Layer

**AsyncRpcControlClient** (`AsyncRpcControlClient.swift`)
- Product-facing actor layered on `AsyncFramedTcpSession`
- Enforces ClientHello/ServerHello before heartbeat, device info, listing, or diagnostics
- With `PairingCredentials`, sends the client proof, verifies the server proof, and rejects correlation-only downgrade before entering ready state
- Caches the successful negotiation so repeated `handshake()` calls do not write duplicate frames
- Starts `AsyncRpcMultiplexer`, which owns request IDs and the only frame reader on the connection
- Routes concurrent control responses by request ID instead of serializing complete round trips
- Opens at most two active download/upload handles after checking negotiated capabilities
- Keeps a valid remote application error recoverable, but closes the session after transport, decoding, checksum, request-correlation, or envelope-shape failure

**AsyncRpcMultiplexer / AsyncRpcRoutingState / transfer handles** (`AsyncRpcMultiplexer.swift`, `AsyncRpcTransferControl.swift`, `AsyncRpcRoutingState.swift`, `AsyncTransferHandles.swift`)
- Permanently claims multiplexed transport mode; FIFO round-trip code cannot share that session
- Serializes frame writes while one independent reader routes response, error, download-chunk, and upload-ACK frames
- Keeps route records, request-ID rotation, and pure open/window/offset validation in a value-only helper with no actor, task, socket, or waiter resolution
- Enforces 16 in-flight control requests, two active transfer IDs/streams, 1 MiB chunk size, and per-stream buffering of at most 4 chunks / 2 MiB
- Exposes ordered download `nextChunk` + ACK, single upload `sendChunk`, and deterministic preflighted upload `sendWindow` handles
- Adds `AsyncDownloadTransfer.receive(to:resume:)`, which owns chunk/write/ACK order and atomically commits only after the final ACK
- Runs blocking Foundation file operations on a private serial queue, leaving the session and other transfer actors responsive
- Rechecks the local partial length against the remote accepted offset, cancels on mismatch, and keeps partial data after protocol cancellation
- Validates an entire upload window before its first wire frame, submits it in offset order, and retires ACK waiters from the queue head
- Lets protocol cancellation end one upload window while preserving the session; direct Swift Task cancellation after admission closes the ambiguous session
- Keeps an idle reader alive without applying a request timeout; each actual request/open/ACK wait has its own deadline
- Local TCP E2E interleaves a multi-chunk download, a full four-chunk upload window, and heartbeat, then proves cancel + post-cancel heartbeat reuse

**HandshakeSmokeClient** (`HandshakeSmokeClient.swift`)
- Simple handshake-only test client
- Runs its one Hello round trip through async FIFO transport and closes on every result
- Constructs `ClientHello` with platform/version info and a fresh 32-byte session-correlation nonce
- Validates `ServerHello` response metadata and requires an exact nonce echo
- Validates explicit authentication state and the presence/absence of the 32-byte server challenge
- Treats correlation-only state as non-authentication; paired proof handling stays in `AsyncRpcControlClient`
- Used by `handshake-smoke` command

**M1SmokeClient** (`M1SmokeClient.swift`)
- Baseline async control-plane probe used by `m1-smoke`
- Opens `AsyncFramedTcpSession`, then delegates single-reader RPC routing to `AsyncRpcControlClient`
- Preserves the legacy requested capability set and success result shape
- Runs handshake → heartbeat → device info → `dm://roots/` → diagnostics, then closes the client on success or failure

**AsyncDualDownloadSmokeClient** (`DualDownloadSmokeClient.swift`)
- Dedicated M1 multiplexing probe layered on the production `AsyncRpcControlClient` and its single-reader router
- Opens two download transfers before consuming either stream
- Relies on the shared multiplexer to route and validate request, stream, transfer, offset, size, and CRC32 boundaries
- Services one buffered chunk per stream in turn and ACKs progress independently
- Sends a heartbeat after both opens and before either first-chunk ACK, making control-plane starvation a test failure
- Used by `dual-download-smoke` and the device script's opt-in `--dual-download-check`

**AsyncMixedTransferSmokeClient** (`AsyncMixedTransferSmokeClient.swift`)
- Owns a fresh `AsyncFramedTcpSession` and requests file-read, file-write, and diagnostics capabilities
- Opens one download and one upload, requires heartbeat before either can finish, then concurrently runs atomic receive and the shared `AsyncUploadFileSender`
- Requires both transfers to finish, the upload source to remain stable, and the heartbeat value to round-trip
- Uses `mac-local-upload` for the inactive-side upload source field so remote diagnostics never receive a Mac path or personal file name
- Powers `mixed-transfer-smoke` and the device script's opt-in `--mixed-transfer-check`; local TCP coverage exists, but no physical-device result is claimed yet

**Control client entry points:**
- `M1SmokeClient.run()`: async baseline smoke (handshake → heartbeat → device info → roots → diagnostics)
- `AsyncRpcControlClient`: product control/listing and multiplexed transfer entry point

### File Handling

**AtomicDownloadWriter** (`AtomicDownloadWriter.swift`)
- Writes download chunks to `.droidmatch-part` (partial file)
- On successful completion, renames to final destination atomically
- On error or cancel, leaves partial file for manual cleanup or resume
- Reports the non-mutating local resume offset used by the scheduler before open

**AsyncAtomicDownloadWriter** (`AsyncAtomicDownloadWriter.swift`)
- Serializes create/write/close/commit on a private Dispatch queue so blocking file calls do not occupy Swift's cooperative executor
- Is owned only by `AsyncDownloadTransfer.receive(to:resume:)`; callers cannot race the underlying `FileHandle`
- Sidecar persistence remains a scheduler/harness responsibility, not a writer responsibility

**AsyncDownloadCoordinator / AsyncTransferResumeStore** (`AsyncDownloadCoordinator.swift`, `AsyncTransferResumeStore.swift`)
- Injects an `AsyncRpcControlClient` factory so transport creation and pairing/authentication configuration stay outside transfer persistence policy
- Reloads the on-disk checkpoint before each attempt and reopens with the same transfer ID, the actual partial length, and the accepted source fingerprint
- Uses the cancellable async `RecoveryPolicy` executor for retry classification and backoff; a corrupt record or an orphaned non-empty partial fails visibly instead of silently restarting
- Removes the sidecar only after the atomic receiver commits successfully

**AsyncUploadCoordinator / AsyncUploadFileSource** (`AsyncUploadCoordinator.swift`, `AsyncUploadFileSource.swift`)
- Reads source bytes through one private serial queue and checks size, nanosecond mtime, filesystem, and inode before and after each read
- Fills deterministic windows of at most four chunks / 2 MiB and persists each ordered ACK rather than treating sent bytes as durable
- Reopens app-sandbox/SAF uploads with the same transfer ID and last ACKed offset after a retryable disconnect; a local TCP test sends 8 bytes, persists only offset 2, then resumes from 2
- Keeps MediaStore fresh-only, rejects resume/retry policy for non-resumable destinations, and retains the last sidecar checkpoint on task cancellation

**AsyncTransferScheduler / TransferQueuePersistenceStore** (`AsyncTransferScheduler.swift`, `TransferQueuePersistence.swift`)
- Admits download/upload coordinator requests in FIFO order with a default global limit of two running jobs
- Keeps the immutable public job/snapshot contract and synchronous retry relay in `AsyncTransferSchedulerTypes.swift`, leaving queue/runtime transitions in the actor implementation
- Publishes buffering-newest full snapshots for queued/running/retrying/pausing/paused/completed/failed/cancelled/interrupted states, including retry attempt, backoff, confirmed bytes, total bytes, completion fraction, and UI-ready pause/resume/cancel/remove capability flags
- Accepts only monotonic absolute progress with one stable total across retries; synchronous retry notifications are serialized ahead of immediate reconnect progress and terminal state
- Derives progress from receiver-confirmed checkpoints rather than bytes merely placed on the wire: download write + ACK and upload ACK + resumable sidecar commit
- Computes `recentBytesPerSecond` with a two-second time-weighted monotonic window; retry clears it, an active stall automatically publishes nil, and a terminal transition freezes any still-valid sample
- Cancels queued work without invoking an executor and propagates running cancellation into the owning coordinator task
- Holds queued jobs directly; for checkpointed, incomplete downloads and app-sandbox/SAF uploads, cancels the coordinator's exclusive session, preserves partial/sidecar state, then requeues the same job/transfer identity at the FIFO tail with `resume = true`
- Rejects running pause before a trusted checkpoint, after 100% confirmation, and for fresh-only MediaStore uploads; this local checkpoint policy does not claim wire-level upload pause support
- Keeps terminal outcomes waitable/removable while preventing a cancelling-but-still-unwinding task from being removed early
- Remains process-local through its ordinary initializer; `restoring(...)` opts into a versioned, atomic app-owned manifest with stable UUID/FIFO identity
- Writes queued-to-active intent before executor start, exposes only coarse persistence health, and rejects pause/cancel side effects when their manifest transition cannot be written
- Restores active download/app-sandbox/SAF work only with a matching valid sidecar; corrupt/missing checkpoints and MediaStore active uploads become persistent, non-resumable `interrupted` rows rather than silent replays

**TransferQueueModel** (`DroidMatchPresentation/TransferQueueModel.swift`)
- Uses a small `TransferQueueDataSource` seam and a concrete scheduler adapter, so native state tests do not need transport or file I/O
- Starts one explicit, idempotent MainActor subscription; stop retains the last value, restart obtains the scheduler's fresh full snapshot, and a generation guard rejects late values from an old stream
- Preserves scheduler order and forwards pause/resume/cancel/remove without optimistic row mutation
- Publishes the scheduler's `disabled`/`healthy`/`writeFailed` persistence status without exposing filesystem paths or raw I/O errors
- Maps Core paths into a local basename plus an optional scheme-checked `dm://` path; invalid remote values and raw failure descriptions are omitted because either may contain POSIX paths
- Submits only scheme-checked `dm://` downloads to a local file URL; the authenticated App session now starts/stops its observation and uses scheduler-authoritative state rather than synthetic rows

**DirectoryListing / DirectoryBrowserModel** (`DirectoryListing.swift`, `DroidMatchPresentation/DirectoryBrowserModel.swift`)
- Sends the complete path/page-size/sort/direction query while returning Android's opaque token unchanged; Presentation never imports generated protobuf types
- Maps embedded provider errors into stable categories without retaining message/details, and validates logical row identity, supported kind, page-local uniqueness, and immediate token repetition
- Represents provider-unknown size/time as nil, including virtual roots and SAF/provider metadata gaps
- Serializes load/refresh/load-more on MainActor, rejects stale non-cooperative responses by generation, atomically replaces a successful refresh, and retains rows/token after a failed next page so the user can retry
- Filters duplicate logical paths across offset-backed page boundaries and stops a cross-page token cycle before appending its suspect page
- Is now consumed by the authenticated SwiftUI file page; file names are deliberate row display data but never enter failure state/logs

**ProductDeviceSessionCoordinator / DeviceSessionModel**
- Resolves an opaque discovery UUID back to a private ADB serial only inside the discovery actor, creates a dynamic forward lease, and removes it exactly once on teardown
- Uses a Hello-only connection solely to select Keychain metadata by the 32-byte device fingerprint; the fingerprint remains untrusted until the fresh authenticated connection proves the stored key
- Runs first pairing on its own fresh session with visible six-digit Mac approval, rejects an identity change between preflight and pairing, and never exposes pairing keys, ports, serials, or raw transport errors to Presentation
- Builds one device-isolated persistent scheduler only after file-read/resume capabilities are authenticated; every transfer attempt receives a fresh paired client from an invalidatable private gate
- Serializes disconnect-before-reconnect, cancels pending approval continuations, generation-gates non-cooperative stale results, and tears down in the order gate invalidation → queue settlement → browsing client close → forward release

**ProductDeviceDiagnostics / DeviceDiagnosticsModel**
- Fetches device-info and diagnostics concurrently only after the paired session is ready
- Drops Android device ID, raw events/errors, thread names, arbitrary counter keys, and invalid numeric ranges before creating product state
- Exposes three known permissions, coarse service health, recent error count, fixed counters, and bounded device/system metadata; refresh failure keeps the last snapshot explicitly stale

### SwiftUI Product Shell

**DroidMatchApp** (`DroidMatchApp/`)
- Uses a macOS 13 `NavigationSplitView` with localized device, file, transfer, and diagnostics sections
- Activates device selection, secure connection state, visible SAS confirmation, live authenticated directory navigation, structured device health, native download/upload file panels, and a persistent device-isolated bidirectional queue with progress/actions
- Displays model/product labels and coarse readiness without serials, raw ADB output, protobuf, or harness text
- Shows a stale badge and warning when refresh fails after a successful snapshot
- Reuses the Android mark through a code-generated multi-resolution Mac `.icns`

**Local app assembler** (`tools/build-mac-app.sh`, `tools/render-mac-icon.swift`)
- Builds the `DroidMatch` SwiftPM product and localized resource bundle
- Creates a standard `.app`, renders all icon sizes, applies an ad-hoc signature, and runs strict `codesign` verification
- Is a developer artifact only; Developer ID signing, notarization, sandbox entitlements, and DMG require a configured release environment

**Transfer Sidecar Format (download):**
```json
{
  "transferID": "UUID",
  "sourcePath": "dm://media-images/media/12345",
  "totalSizeBytes": 104857600,
  "fingerprint": {
    "sizeBytes": 104857600,
    "modifiedUnixMillis": 1234567890000,
    "providerEtag": "optional-provider-etag",
    "sha256": "optional-sha256-hex"
  }
}
```

The download sidecar is `<destination>.droidmatch-transfer.json`; the destination
path is therefore encoded by its location rather than repeated in JSON. Coding
keys intentionally retain the existing CLI camelCase format.

**Transfer Sidecar Format (upload):**
```json
{
  "transferID": "UUID",
  "sourcePath": "/tmp/upload.bin",
  "destinationPath": "dm://app-sandbox/file.bin",
  "totalSizeBytes": 104857600,
  "sourceModifiedUnixMillis": 1234567890000,
  "nextOffsetBytes": 1048576
}
```

### Utilities

**AdbClient** (`AdbClient.swift`)
- Wraps `adb` command-line tool
- `devices()`: parse `adb devices -l` output
- `forward()`: create TCP forward (local port → remote port)
- `removeForward()`: remove TCP forward
- `listForwards()`: list active forwards
- Uses `ProcessRunner` for subprocess execution

**ProcessRunner** (`ProcessRunner.swift`)
- Spawns subprocess, captures stdout/stderr
- Returns exit code + combined output
- Used by `AdbClient`

**LockedValue** (`LockedValue.swift`)
- Thread-safe value wrapper using `NSLock`
- Used for concurrent access to mutable state

**Crc32** (`Crc32.swift`)
- CRC32 checksum calculation
- Used to validate transfer chunks

## CLI Harness

**Harness command files** (`DroidMatchHarness/main.swift`, `DroidMatchHarness/HarnessTransferCommands.swift`)
- `main.swift` owns command dispatch, ADB/control probes, help, and shared parsing
- `HarnessTransferCommands.swift` owns download/upload/error-boundary probes while remaining a Core consumer
- Commands:
  - `adb-path`: print default adb path
  - `devices`: list adb devices
  - `forward`: create adb forward
  - `framed-echo`: send/receive one raw frame through an async FIFO session
  - `handshake-smoke`: async handshake-only test without product authentication
  - `m1-smoke`: full control-plane smoke test
  - `list-dir`: list directory entries through the async product transport
  - `list-dir-expect-error`: list directory through the async product transport and require typed error
  - `download-open-expect-error`: asynchronously open download and require typed routed error
  - `download-once`: async download with one routed chunk validation and ACK
  - `download-cancel`: async download first chunk, then validated cancel response
  - `download-pause`: async download first chunk without ACK, then verify the resume-safe pause offset
  - `download`: full download with optional resume and retry
  - `upload`: full upload with optional resume and retry
  - `upload-open-expect-error`: asynchronously open upload and require typed routed error
  - `frame-self-test`: codec self-test
- Parses command-line arguments via `CommandOptions` helper
- Outputs structured results for script parsing

## Build and Test

**Build:**
```bash
swift build --package-path mac
```

**Test:**
```bash
bash tools/run-swift-tests.sh
```

**Run harness:**
```bash
swift run --package-path mac droidmatch-harness <command> <args>
```

**Regenerate protobuf:**
```bash
brew install protobuf
bash tools/generate-swift-proto.sh
```

## Protocol Flow Example

### Download Flow

1. **Open transfer:**
   - Mac sends `OpenTransferRequest(direction=DOWNLOAD, source_path="dm://...")`
   - Android replies `OpenTransferResponse(transfer_id, stream_id, chunk_size, total_size)`
   - Scheduler persists the accepted source fingerprint in its resume sidecar

2. **Receive chunks:**
   - Android sends `TransferChunk(stream_id, offset, data, crc32, is_final)`
   - Mac validates CRC32, writes data, sends `TransferChunkAck(stream_id, offset)`
   - Repeat until `is_final=true`

3. **Commit:**
   - Mac renames `.droidmatch-part` to final destination
   - Scheduler removes the now-unneeded resume sidecar

### Upload Flow

1. **Open transfer:**
   - Mac sends `OpenTransferRequest(direction=UPLOAD, destination_path="dm://...")`
   - Android replies `OpenTransferResponse(transfer_id, stream_id, chunk_size)`

2. **Send chunks:**
   - Mac sends `TransferChunk(stream_id, offset, data, crc32, is_final)`
   - Android writes to hidden partial, replies `TransferChunkAck(stream_id, offset)`
   - Repeat until all chunks sent

3. **Commit:**
   - Android renames partial to final destination (app-sandbox)
   - Or clears pending flag (MediaStore)
   - Or renames hidden document (SAF)

### Resume Flow

**Download resume:**
1. Mac reads sidecar with source fingerprint
2. Sends `OpenTransferRequest` with `requested_offset_bytes` and `source_fingerprint`
3. Android validates fingerprint (size, mtime, etag, sha256)
4. If valid, sends chunks from requested offset
5. If invalid, returns `ERROR_CODE_INVALID_ARGUMENT`

**Upload resume:**
1. Mac reads sidecar with transfer_id and next_offset_bytes
2. Sends `OpenTransferRequest` with same `transfer_id` and `requested_offset_bytes`
3. Android checks partial file exists and length matches
4. If valid, accepts chunks from requested offset
5. If invalid, returns error

## Current Limitations

- **Two async scopes:** ordinary CLI download/upload commands remain single-transfer; `dual-download-smoke` and `mixed-transfer-smoke` are explicit evidence probes. The product async client supports two mixed-direction handles, both recovery coordinators, a bounded observable process queue, and authenticated App download/upload paths. Product authentication/transfers and mixed-stream behavior still lack archived physical-device App evidence.
- **Windowed download:** Android may keep up to 4 chunks or 2 MiB in flight per download stream after the first ACK
- **Windowed upload:** the async path enforces 4 chunks / 2 MiB for both product and harness. `AsyncUploadCoordinator` and the harness share `AsyncUploadFileSender` for serial file reads, continuous refill, optional partial-send limits, and per-ACK checkpoints; SAF still requires exact remote partial length because portable rollback is unavailable.
- **Sandbox recovery boundary:** `DroidMatchAppSupport` owns private bookmark capture, stale refresh, access leases, and orphan pruning alongside the App's per-device manifest and disconnect suspension. A sandbox-entitled bundle still needs end-to-end verification, and `interrupted` recovery UX remains intentionally conservative.

## Next Steps for Developers

1. **Read this document** to understand code structure
2. **Read `docs/protocol.md`** for wire protocol details
3. **Read `docs/m1-testing-guide.md`** for test scenarios
4. **Run `m1-smoke`** on a real device to see protocol in action
5. **Explore `M1SmokeClient.swift` and `AsyncRpcControlClient.swift`** (async baseline and product RPC logic)
6. **Build `tools/build-mac-app.sh`** and inspect the read-only product discovery surface
7. **Check `docs/m1-status.md`** for implementation gaps

## Adding New Features

### Adding a New RPC Request

1. Define protobuf message in `proto/v1/*.proto`
2. Regenerate Swift code: `bash tools/generate-swift-proto.sh`
3. Add product behavior to `AsyncRpcControlClient` or a higher Core abstraction; do not add new calls to the deletion-bound `RpcControlClient`
4. Add CLI dispatch to `DroidMatchHarness/main.swift` and its implementation to the control or transfer command file
5. Update Android `RpcDispatcher` to handle request
6. Add test to `tools/run-m1-device-smoke.sh`

### Extending Multi-Stream Support

1. Start from `AsyncRpcMultiplexer` and `AsyncRpcMultiplexerTests`; keep `AsyncDualDownloadSmokeClient` as the stable device-evidence path
2. Keep a bounded `stream_id` → transfer-state map and reject unknown/crossed IDs
3. Preserve control-plane service while multiple data streams have buffered chunks
4. Run and archive `--mixed-transfer-check`, then add per-stream physical-device failure-isolation scenarios before raising the two-stream limit
5. Verify the bookmark-backed transfer path under an App Sandbox entitlement; keep manifest/bookmark ownership, provider path validation, retry policy, protocol parsing, and file checkpoints outside view code

## References

- [Mac README](../mac/README.md): build and run instructions
- [Protocol Documentation](../docs/protocol.md): wire format and semantics
- [M1 Status](../docs/m1-status.md): implementation checklist
- [M1 Testing Guide](../docs/m1-testing-guide.md): test scenarios
- [SwiftProtobuf](https://github.com/apple/swift-protobuf): protobuf Swift library
