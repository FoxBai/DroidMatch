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
│   │   ├── FrameCodec.swift    # Length-prefixed frame encoding/decoding
│   │   ├── FrameReader.swift   # Streaming frame reader
│   │   ├── FramedTcpClient.swift # Network.framework TCP client
│   │   ├── AsyncFramedTcpSession.swift # Product-facing async transport actor
│   │   ├── RpcEnvelopeCodec.swift # Shared envelope construction/validation
│   │   ├── AsyncRpcControlClient.swift # Product-facing async RPC actor
│   │   ├── AsyncRpcMultiplexer.swift # Single-reader control/stream router + transfer handles
│   │   ├── AsyncTransferHandles.swift # Public download/upload actors + bounded chunk queue
│   │   ├── AsyncAtomicDownloadWriter.swift # Non-blocking serial file-I/O adapter
│   │   ├── TransferResumeRecords.swift # Shared camelCase download/upload sidecars
│   │   ├── AsyncTransferResumeStore.swift # Serial durable checkpoint I/O
│   │   ├── AsyncDownloadCoordinator.swift # Product download reconnect/resume scheduler
│   │   ├── AsyncUploadFileSource.swift # Stable serial source-file reader
│   │   ├── AsyncUploadCoordinator.swift # Product window refill/reconnect scheduler
│   │   ├── AsyncPairingClient.swift # One-shot first-pairing coordinator
│   │   ├── SessionAuthenticator.swift # Canonical auth transcript/HMAC/HKDF
│   │   ├── PairingAuthenticator.swift # P-256/SAS/identity verification
│   │   ├── PairingCredentialStore.swift # Non-sync Keychain records
│   │   ├── HandshakeSmokeClient.swift # ClientHello/ServerHello test
│   │   ├── M1SmokeClient.swift # Full M1 control-plane client
│   │   ├── AtomicDownloadWriter.swift # Download partial → final commit
│   │   ├── ProcessRunner.swift # Subprocess execution helper
│   │   ├── LockedValue.swift   # Thread-safe value wrapper
│   │   └── Crc32.swift         # CRC32 checksum
│   └── DroidMatchHarness/      # CLI tool for testing
│       └── main.swift          # Command dispatcher (devices, m1-smoke, download, etc.)
├── Tests/
│   └── DroidMatchCoreTests/    # Unit tests for core library
├── Package.swift               # SwiftPM manifest
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

**FramedTcpClient** (`FramedTcpClient.swift`)
- Network.framework-based TCP client
- Single round-trip: connect → send frame → receive frame → close
- Used by `framed-echo` command for basic connectivity tests

**FramedTcpSession** (in `FramedTcpClient.swift`)
- Persistent TCP connection for multiple round-trips
- Used by `M1SmokeClient` for handshake → heartbeat → requests on same connection
- Maintains connection state, handles timeouts

**AsyncFramedTcpSession** (`AsyncFramedTcpSession.swift`)
- Product-facing, non-blocking `NWConnection` boundary; the callback API is bridged with checked continuations rather than semaphores
- Serializes each complete request/response round-trip with a cancellation-aware FIFO operation lock; actor isolation alone is not treated as a cross-`await` mutex
- Races completion, timeout, and task cancellation through a one-shot result gate, then closes ambiguous sessions instead of reusing them
- Keeps the synchronous M1 harness unchanged while the async RPC and transfer layers are introduced incrementally
- Selects either FIFO round-trip or multiplexed mode for the connection lifetime; multiplexed mode keeps one independent reader and serialized writers

### Protocol Layer

**RpcEnvelopeCodec** (`RpcEnvelopeCodec.swift`)
- Shares request construction and response validation between synchronous harness and async product clients
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

**AsyncRpcMultiplexer / AsyncDownloadTransfer / AsyncUploadTransfer** (`AsyncRpcMultiplexer.swift`, `AsyncTransferHandles.swift`)
- Permanently claims multiplexed transport mode; FIFO round-trip code cannot share that session
- Serializes frame writes while one independent reader routes response, error, download-chunk, and upload-ACK frames
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
- Constructs `ClientHello` with platform/version info and a fresh 32-byte session-correlation nonce
- Validates `ServerHello` response metadata and requires an exact nonce echo
- Validates explicit authentication state and the presence/absence of the 32-byte server challenge
- Treats correlation-only state as non-authentication; paired proof handling stays in `AsyncRpcControlClient`
- Used by `handshake-smoke` command

**M1SmokeClient** (`M1SmokeClient.swift`)
- **Main M1 control-plane client**
- Runs on persistent `FramedTcpSession`
- Implements:
  - Handshake (ClientHello/ServerHello)
  - Heartbeat
  - Device info request
  - Root listing (`dm://roots/`)
  - Directory listing (media, SAF, app-sandbox)
  - Download (single stream, windowed receiver-paced, with CRC32 validation)
  - Upload (single stream, receiver-paced, app-sandbox/MediaStore/SAF)
  - Transfer cancel and pause
  - Download resume (with source fingerprint validation)
  - Upload resume (app-sandbox and SAF)
  - Sidecar-backed transport-loss retry (default one retry, configurable queue via `--max-retry-attempts`)
  - Diagnostics request
- Error handling: typed `M1SmokeError` cases
- Used by `m1-smoke`, `list-dir`, `download`, `upload` commands

**DualDownloadSmokeClient** (`DualDownloadSmokeClient.swift`)
- Dedicated M1 multiplexing probe layered on one synchronous `FramedTcpSession`
- Opens two download transfers before consuming either stream
- Routes responses and chunks by request ID and validates stream ID, transfer ID, offset, size, CRC32, and final byte count
- Services one buffered chunk per stream in turn and ACKs progress independently
- Sends a heartbeat after both opens and before either first-chunk ACK, making control-plane starvation a test failure
- Used by `dual-download-smoke` and the device script's opt-in `--dual-download-check`

**Key Methods in M1SmokeClient:**
- `run()`: full smoke test (handshake → heartbeat → device info → roots → diagnostics)
- `handshake()`: ClientHello/ServerHello exchange
- `heartbeat()`: keep-alive request
- `deviceInfo()`: query device model, Android version, battery, etc.
- `listDir()`: list entries in a DroidMatch logical path
- `downloadTransfer()`: open download, receive chunks, validate CRC32, write to file
- `uploadTransfer()`: open upload, send chunks, wait for ACKs
- `cancelTransfer()`: send cancel request for active transfer
- `pauseTransfer()`: send pause request for active transfer

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

**main.swift** (`DroidMatchHarness/main.swift`)
- Command-line tool dispatcher
- Commands:
  - `adb-path`: print default adb path
  - `devices`: list adb devices
  - `forward`: create adb forward
  - `framed-echo`: send/receive raw frame (basic connectivity test)
  - `handshake-smoke`: handshake-only test
  - `m1-smoke`: full control-plane smoke test
  - `list-dir`: list directory entries
  - `list-dir-expect-error`: list directory and require typed error
  - `download-open-expect-error`: open download and require typed error
  - `download-once`: download with one chunk validation
  - `download-cancel`: download first chunk, then cancel
  - `download-pause`: download first chunk, then pause
  - `download`: full download with optional resume and retry
  - `upload`: full upload with optional resume and retry
  - `upload-open-expect-error`: open upload and require typed error
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

- **Two async scopes:** ordinary CLI download/upload commands remain single-transfer and `DualDownloadSmokeClient` remains the physical-device probe; the product async client locally supports two mixed-direction handles, atomic file receive, and download reconnect/resume coordination, but has no UI queue or physical-device mixed-stream evidence yet
- **Windowed download:** Android may keep up to 4 chunks or 2 MiB in flight per download stream after the first ACK
- **Windowed upload:** both the synchronous M1 client and product async path enforce 4 chunks / 2 MiB. `AsyncUploadCoordinator` now owns serial file reads, continuous refill, and per-ACK checkpoints; SAF still requires exact remote partial length because portable rollback is unavailable.
- **Process-local retry queue:** CLI and both product coordinators can run multiple reconnect attempts, but queue intent is not persisted across app/harness restarts and is not bound to product UI yet.

## Next Steps for Developers

1. **Read this document** to understand code structure
2. **Read `docs/protocol.md`** for wire protocol details
3. **Read `docs/m1-testing-guide.md`** for test scenarios
4. **Run `m1-smoke`** on a real device to see protocol in action
5. **Explore `M1SmokeClient.swift`** (main client logic)
6. **Check `docs/m1-status.md`** for implementation gaps

## Adding New Features

### Adding a New RPC Request

1. Define protobuf message in `proto/v1/*.proto`
2. Regenerate Swift code: `bash tools/generate-swift-proto.sh`
3. Add handler method to `M1SmokeClient` (or new client class)
4. Add CLI command to `DroidMatchHarness/main.swift`
5. Update Android `RpcDispatcher` to handle request
6. Add test to `tools/run-m1-device-smoke.sh`

### Extending Multi-Stream Support

1. Start from `AsyncRpcMultiplexer` and `AsyncRpcMultiplexerTests`; keep `DualDownloadSmokeClient` as the stable device-evidence path
2. Keep a bounded `stream_id` → transfer-state map and reject unknown/crossed IDs
3. Preserve control-plane service while multiple data streams have buffered chunks
4. Add physical-device mixed upload/download and per-stream failure-isolation scenarios before raising the two-stream limit
5. Bind the completed download/upload coordinators to the future UI queue without moving protocol parsing or file checkpoints into UI code

## References

- [Mac README](../mac/README.md): build and run instructions
- [Protocol Documentation](../docs/protocol.md): wire format and semantics
- [M1 Status](../docs/m1-status.md): implementation checklist
- [M1 Testing Guide](../docs/m1-testing-guide.md): test scenarios
- [SwiftProtobuf](https://github.com/apple/swift-protobuf): protobuf Swift library
