# Android Side Code Overview

This document provides a quick orientation to the Android-side codebase for developers joining the project.

## Directory Structure

```
android/
├── app/
│   ├── src/
│   │   ├── main/
│   │   │   ├── java/app/droidmatch/m1/       # M1 implementation
│   │   │   │   ├── RpcDispatcher.java        # RPC request router
│   │   │   │   ├── DmFileProvider.java       # File system abstraction
│   │   │   │   ├── ProviderDownloadReaders.java # Offset/read/close state machines
│   │   │   │   ├── ProviderUploadWriters.java # Provider commit/cleanup state machines
│   │   │   │   ├── DiagnosticsReporter.java  # State tracking
│   │   │   │   ├── DiagnosticsActivity.java  # Launcher entry
│   │   │   │   ├── ForegroundConnectionService.java  # Service lifecycle
│   │   │   │   ├── AdbEndpoint.java          # TCP server
│   │   │   │   ├── FramedIo.java             # Frame codec
│   │   │   │   ├── AndroidDeviceInfoProvider.java  # Device info
│   │   │   │   ├── PermissionStateProvider.java  # Permission state
│   │   │   │   ├── SessionAuthenticator.java # Canonical auth transcript/HMAC/HKDF
│   │   │   │   ├── PairingAuthenticator.java # Pairing transcript/HKDF/SAS
│   │   │   │   ├── PairingApprovalController.java # Visible-window state
│   │   │   │   ├── AndroidDeviceIdentity.java # Keystore P-256 identity
│   │   │   │   ├── AndroidPairingCredentialStore.java # Wrapped records
│   │   │   │   ├── AuthenticationRateLimiter.java # Pairing/auth backoff
│   │   │   │   └── NotificationPermissionRequester.java
│   │   │   ├── proto/                        # Generated protobuf (do not edit)
│   │   │   │   └── app/droidmatch/proto/v1/  # Java lite classes
│   │   │   ├── res/                          # Resources
│   │   │   └── AndroidManifest.xml           # App manifest
│   │   ├── debug/
│   │   │   └── java/app/droidmatch/m1/
│   │   │       └── DebugHarnessActivity.java # Debug-only endpoint starter
│   │   └── test/
│   │       └── java/app/droidmatch/m1/       # Unit tests
│   │           ├── RpcDispatcherTest.java
│   │           ├── DmFileProviderTest.java
│   │           └── DiagnosticsReporterTest.java
│   ├── build.gradle                          # App build config
│   └── proguard-rules.pro                    # ProGuard rules
├── gradle/                                   # Gradle wrapper
├── build.gradle                              # Project build config
├── settings.gradle                           # Project settings
└── README.md                                 # Android-side README
```

## Key Components

### Service Layer

**ForegroundConnectionService** (`ForegroundConnectionService.java`)
- Foreground service that hosts the ADB endpoint
- Creates a localized persistent notification (required for foreground service)
- Handles service lifecycle: `onCreate()`, `onStartCommand()`, `onTimeout()`, `onDestroy()`
- Intent actions:
  - `START_ADB_ENDPOINT`: starts ADB listener on specified port
- Notification tap opens `DiagnosticsActivity` for SAF grants
- Service keeps running while ADB endpoint is active
- Returns `START_NOT_STICKY`, so process recreation cannot leave an idle foreground service without endpoint parameters
- Uses the API 26+ notification-channel path directly; no unreachable pre-O fallback remains
- Keeps the ADB path on `dataSync`: loopback-over-ADB does not satisfy Android 14's `connectedDevice` runtime prerequisites. On Android 15, `onTimeout()` closes the endpoint and stops the service when the background `dataSync` budget is exhausted. A future AOA path may use `connectedDevice` after it owns a real `UsbManager` accessory grant.

**AdbEndpoint** (`AdbEndpoint.java`)
- TCP server socket listening on localhost
- Only accepts connections from `127.0.0.1` (loopback)
- Configurable timeouts: handshake timeout, idle timeout
- One connection at a time (single-session model)
- Lifecycle:
  1. Bind to port (passed via intent)
  2. Accept connection
  3. Validate client is loopback
  4. Hand off to `RpcDispatcher`
  5. Close socket on session end
- Used by `DebugHarnessActivity` for testing

**DebugHarnessActivity** (`DebugHarnessActivity.java`, debug-only)
- Debug APK exclusive entry point
- Keeps screen awake during testing
- Starts `ForegroundConnectionService` with specified port
- Starts the non-exported service through an explicit in-app intent; only this debug Activity is shell-accessible
- Workaround for OEM device freezer: some devices freeze service accept() thread unless app has foreground Activity
- Not included in release APK

**DiagnosticsActivity / PairingApprovalController**
- Main launcher entry point (shows in app drawer)
- Requests notification permission (Android 13+)
- Opens a default-closed 120-second pairing window and shows one pending client's six-digit SAS with explicit approve/reject actions
- Opens the SAF directory picker from a separate action
- Persists `takePersistableUriPermission()` for selected directory
- Keeps cryptographic keys and proofs out of UI state

**Backup rules** (`res/xml/backup_rules.xml`, `res/xml/data_extraction_rules.xml`)
- Exclude every credential- or privacy-bearing app data domain from legacy backup, cloud backup, and device transfer
- Require a fresh device pairing after migration instead of restoring security state

**Launcher icon** (`res/mipmap-anydpi/ic_launcher.xml`)
- Uses one adaptive vector for every supported API level (minSdk 26), with a v33 monochrome override for themed icons
- Mirrors the original reusable mark at `assets/brand/droidmatch-mark.svg`; density-specific placeholder PNGs are removed

### Transport Layer

**FramedIo** (`FramedIo.java`)
- Length-prefixed frame I/O: `uint32_be length + payload`
- `readFrame()`: reads one frame from `InputStream`
- `writeFrame()`: writes one frame to `OutputStream`
- Max frame size: 4 MiB
- Throws `IOException` on oversized/truncated frames

### Protocol Layer

**SessionAuthenticator** (`SessionAuthenticator.java`)
- Mirrors the Mac canonical session-auth transcript byte-for-byte
- Uses platform SHA-256/HmacSHA256, role-separated proofs, constant-time comparison, and HKDF-SHA-256 expansion
- Loads the same checked-in fixed vector as Swift during JVM tests
- Is wired to the paired reconnect dispatcher state machine

**PairingAuthenticator / PairingKeyAgreement**
- Use platform P-256 ECDH with strict 65-byte X9.63 point validation
- Derive the confirmation key and stored pairing key with independent HKDF contexts
- Produce an unbiased six-digit SAS plus role-separated client/server/final confirmations
- Include the stable Android identity public key in the transcript and match Swift through `fixtures/crypto/pairing-v1.properties`

**AndroidDeviceIdentity / PairingApprovalController**
- Keep a stable non-exportable P-256 signing private key in Android Keystore and return only its X9.63 public key
- Sign the canonical first-pairing transcript with DER ECDSA for Mac verification
- Admit one pending attempt only during a user-opened window and expose no key material to the Activity

**AuthenticationRateLimiter**
- Applies exponential backoff independently to first pairing, each reconnect pairing ID, and aggregate reconnect failures
- Keeps unknown IDs and blocked valid proofs on the same challenge/generic-failure wire shape
- Expires idle state after five minutes and bounds identifier buckets to 256 entries

**AndroidPairingCredentialStore / PairingCredentialVault**
- Wrap each pairing key with AES-GCM under a non-exportable Android Keystore key
- Authenticate pairing ID, device fingerprint, display name, and timestamps as AAD
- Keep versioned ciphertext in private SharedPreferences excluded from backup/transfer
- Support save, metadata list, lookup, collision rejection, tamper failure, and revoke
- Are called by the dispatcher only after final confirmation; closed-window and rejection tests prove no record is written
- Expose package-private test-only alias/preferences injection so instrumentation never mutates product aliases
- Have an AndroidX instrumentation APK that verifies real non-exportable Keystore keys and record reopen/revoke; CI compiles it, while device execution remains manual

**Generated Protobuf Files** (`app/src/main/proto/app/droidmatch/proto/v1/`)
- `RpcProto`: `RpcEnvelope`, `RpcRequest`, `RpcResponse`, `RpcError`
- `SessionProto`: Hello/authentication/heartbeat messages and authentication state
- `DeviceProto`: `DeviceInfoRequest`, `DeviceInfoResponse`
- `FileProto`: `ListDirRequest`, `ListDirResponse`, `DmFileEntry`
- `TransferProto`: `OpenTransferRequest`, `OpenTransferResponse`, `TransferChunk`, `TransferChunkAck`, `CancelTransferRequest`, `PauseTransferRequest`
- `ErrorProto`: `ErrorCode` enum
- Generated by Gradle from `proto/v1/*.proto`
- Regenerate: `./gradlew :app:generateDebugProto`

**RpcDispatcher** (`RpcDispatcher.java`)
- **Main RPC request handler**
- Runs on single TCP connection (one session)
- Session lifecycle:
  1. Read `ClientHello`, validate/echo its nonce, and select explicit correlation-only or paired-required policy
  2. In paired mode issue a server nonce, accept only `AuthenticateSessionRequest`, verify the client proof, then grant final capabilities
  3. Dispatch normal requests only after the state reaches ready
  4. Handle transfer chunks on the same connection
  5. Clear provisional key material and close on authentication/order error, timeout, or disconnect
- Supported requests:
  - `HeartbeatRequest`
  - `DeviceInfoRequest`
  - `ListDirRequest`
  - `OpenTransferRequest` (download/upload)
  - `TransferChunk` (upload data)
  - `TransferChunkAck` (download acknowledgment)
  - `CancelTransferRequest`
  - `PauseTransferRequest`
  - `DiagnosticsRequest`
- Error handling: catches exceptions, returns typed `RpcError`
- Transfer state management:
  - At most two active transfers per session across download and upload directions
  - Requires active transfer IDs to be unique across both directions
  - Keys independent readers/writers by session and stream ID so two downloads can advance separately
  - Validates transfer direction and granted capability before applying the concurrency limit
  - Tracks transfer_id, stream_id, offset, total_size
  - Keeps provider readers/writers open across chunks

**Key Methods in RpcDispatcher:**
- `run()`: main session loop (handshake → request loop)
- `handleRequest()`: dispatch by request type
- `handleOpenTransfer()`: open download/upload
- `handleTransferChunk()`: receive upload chunk
- `handleTransferChunkAck()`: send next download chunk
- `handleCancelTransfer()`: release an active download reader or upload writer
- `handlePauseTransfer()`: pause an active download at its last acknowledged offset

### File Provider Layer

**DmFileProvider** (`DmFileProvider.java`, 2568 lines)
- **Main file system abstraction**
- Implements DroidMatch logical path model (`dm://...`)
- Provider types:
  - **roots**: virtual root listing (`dm://roots/`)
  - **media-images**: MediaStore images (`dm://media-images/`)
  - **media-videos**: MediaStore videos (`dm://media-videos/`)
  - **app-sandbox**: app private files (`dm://app-sandbox/`)
  - **saf**: Storage Access Framework (`dm://saf-<stable-id>/`)

**ProviderUploadWriters** (`ProviderUploadWriters.java`)
- Owns ordered offset/size/final-chunk validation after `DmFileProvider` has routed and authorized a logical destination
- Preserves app-sandbox hidden partial files on non-final close and commits with atomic-move fallback
- Renames a completed SAF temporary document and applies provider-specific deletion policy on failed/non-final close
- Publishes a completed MediaStore pending row and deletes an uncommitted row on close
- Contains no path routing, permission inference, or RPC behavior

**ProviderDownloadReaders** (`ProviderDownloadReaders.java`)
- Owns one-shot and reusable stream reader state, bounded reads, EOF/final-chunk detection, and deterministic close behavior
- Opens seekable provider file descriptors at the accepted resume offset and closes both stream and descriptor on every failed open path
- Provides the sequential `skipFully` fallback for non-seekable provider streams, including explicit offset-past-EOF rejection
- Preserves provider metadata on every chunk and contains no path routing, authorization, or RPC behavior

**Provider Operations:**
- `listRoots()`: returns available provider roots
- `listDirectory()`: lists entries in a path (with pagination)
- `openDownloadReader()`: opens file for reading
- `openUploadWriter()`: opens file for writing
- `readChunk()`: reads next chunk from download reader
- `writeChunk()`: writes chunk to upload writer
- `closeReader()`: closes download reader
- `closeWriter()`: commits or aborts upload
- `resumeValidation()`: validates source fingerprint for resume

**Download Flow:**
1. `openDownloadReader(path)`: opens provider-specific reader
   - MediaStore: opens `InputStream` via `ContentResolver.openInputStream()`
   - SAF: opens `InputStream` via `ContentResolver.openInputStream()`
   - App-sandbox: opens `FileInputStream`
2. `readChunk(reader, offset, size)`: seeks to offset, reads chunk
   - If provider exposes seekable `FileDescriptor`, use `lseek()`
   - Otherwise, open stream and skip to offset
3. `closeReader(reader)`: closes stream

**Upload Flow:**
1. `openUploadWriter(path, offset)`: opens provider-specific writer
   - **App-sandbox fresh**: delete old partial, create new partial `.droidmatch-upload-part`
   - **App-sandbox resume**: open existing partial, validate/truncate to offset
   - **MediaStore fresh**: insert pending row in `Pictures/DroidMatch/` or `Movies/DroidMatch/`
   - **SAF fresh**: create hidden partial document (`_dm_partial_<transfer-id>`)
   - **SAF resume**: validate hidden partial document length matches offset
2. `writeChunk(writer, chunk)`: append chunk to writer
3. `closeWriter(writer, isFinal)`:
   - **Final**: rename partial to destination (app-sandbox/SAF), clear pending flag (MediaStore)
   - **Non-final**: keep partial, or delete (MediaStore/SAF fresh-only)

**Resume Support:**
- **Download**: validates source fingerprint (size, mtime, etag, sha256)
- **App-sandbox upload**: validates partial file exists, truncates if ahead of requested offset (ACK-loss tolerance)
- **SAF upload**: validates hidden partial document exists and length equals requested offset
- **MediaStore upload**: fresh-only, resume returns `ERROR_CODE_UNSUPPORTED_CAPABILITY`

**SAF Integration:**
- Persisted tree URI permissions stored in shared preferences
- Stable IDs derived from tree URI hash
- Directory listings use `DocumentsContract.buildChildDocumentsUriUsingTree()`
- Upload creates hidden partial documents with transfer-id suffix
- Resume validates partial document before accepting chunks

**MediaStore Integration:**
- API 29+ uses `IS_PENDING` flag for atomic insert
- API 26-28 inserts directly (no pending support)
- Collections: `Pictures/DroidMatch/` for images, `Movies/DroidMatch/` for videos
- Display name from logical path, MIME type from extension

### Device Info & Diagnostics

**AndroidDeviceInfoProvider** (`AndroidDeviceInfoProvider.java`, 81 lines)
- Provides device information for `DeviceInfoRequest`
- Returns:
  - Manufacturer (e.g., "NIO")
  - Model (e.g., "N2301")
  - Android version string (e.g., "14")
  - SDK int (e.g., 34)
  - Data partition capacity (bytes)
  - Battery percent
  - M1 permission state (notification, media, storage)

**PermissionStateProvider** (`PermissionStateProvider.java`, 54 lines)
- Checks runtime permission state
- Permissions:
  - `POST_NOTIFICATIONS` (Android 13+)
  - `READ_EXTERNAL_STORAGE` (Android 12-)
  - `READ_MEDIA_IMAGES` (Android 13+)
  - `READ_MEDIA_VIDEO` (Android 13+)
  - `READ_MEDIA_VISUAL_USER_SELECTED` (Android 14+)
- Returns granted/denied/not-applicable

**DiagnosticsReporter** (`DiagnosticsReporter.java`, 148 lines)
- Tracks service state, events, errors
- Thread-safe (uses `AtomicReference` and synchronized blocks)
- Events: service started, endpoint ready, session opened, transfer started, etc.
- Errors: connection failed, permission denied, transfer error, etc.
- Returned by `DiagnosticsRequest`
- Has JVM concurrent test coverage

## Build and Test

**Build:**
```bash
cd android
./gradlew :app:assembleDebug
```

**Test:**
```bash
cd android
./gradlew :app:testDebugUnitTest
```

**Install:**
```bash
cd android
./gradlew :app:installDebug
# or
adb install app/build/outputs/apk/debug/app-debug.apk
```

**Lint:**
```bash
cd android
./gradlew :app:lintDebug
```

**Regenerate protobuf:**
```bash
cd android
./gradlew :app:generateDebugProto
```

## Protocol Flow Example

### Download Flow (Android Side)

1. **Receive OpenTransferRequest:**
   - `RpcDispatcher.handleOpenTransfer()`
   - Validate direction is DOWNLOAD
   - Call `DmFileProvider.openDownloadReader(source_path)`
   - Provider opens stream, returns reader with total_size
   - Send `OpenTransferResponse(transfer_id, stream_id, chunk_size, total_size)`

2. **Send chunks:**
   - `RpcDispatcher` reads chunk from provider: `DmFileProvider.readChunk(reader, offset, chunk_size)`
   - Compute CRC32
   - Send `TransferChunk(stream_id, offset, data, crc32, is_final)`
   - Wait for `TransferChunkAck` from Mac
   - Repeat until all bytes sent

3. **Close:**
   - Call `DmFileProvider.closeReader(reader)`
   - Remove transfer state from dispatcher

### Upload Flow (Android Side)

1. **Receive OpenTransferRequest:**
   - `RpcDispatcher.handleOpenTransfer()`
   - Validate direction is UPLOAD
   - Call `DmFileProvider.openUploadWriter(destination_path, offset, transfer_id)`
   - Provider creates partial file/document
   - Send `OpenTransferResponse(transfer_id, stream_id, chunk_size)`

2. **Receive chunks:**
   - Mac sends `TransferChunk(stream_id, offset, data, crc32, is_final)`
   - `RpcDispatcher.handleTransferChunk()` validates CRC32
   - Call `DmFileProvider.writeChunk(writer, chunk)`
   - Send `TransferChunkAck(stream_id, next_offset)`
   - Repeat until final chunk

3. **Commit:**
   - Call `DmFileProvider.closeWriter(writer, is_final=true)`
   - Provider renames partial to destination (app-sandbox/SAF)
   - Or clears pending flag (MediaStore)
   - Remove transfer state from dispatcher

### Resume Flow (Android Side)

**Download resume:**
1. Receive `OpenTransferRequest` with `requested_offset_bytes` and `source_fingerprint`
2. Call `DmFileProvider.resumeValidation(source_path, fingerprint)`
3. Provider checks size, mtime, etag, sha256
4. If valid, open reader and seek to offset
5. Send chunks starting from requested offset

**Upload resume:**
1. Receive `OpenTransferRequest` with same `transfer_id` and `requested_offset_bytes > 0`
2. Call `DmFileProvider.openUploadWriter(destination_path, offset, transfer_id)`
3. Provider validates partial file/document exists
4. If app-sandbox and partial is ahead: truncate to requested offset (ACK-loss tolerance)
5. If SAF: validate partial length equals requested offset
6. Accept chunks starting from requested offset

## Current Limitations

- **Single session:** only one ADB connection at a time
- **Single transfer per direction:** one active download + one active upload per session
- **MediaStore fresh-only:** upload resume not supported
- **No automatic partial cleanup:** SAF partial documents remain if upload is abandoned
- **Loopback only:** endpoint rejects non-127.0.0.1 clients

## Testing Notes

- **Unit tests:** run in JVM, no Android emulator needed
- **RpcDispatcherTest:** tests request dispatch and error handling
- **DmFileProviderTest:** tests file provider operations (mocked Android APIs)
- **DiagnosticsReporterTest:** tests concurrent event/error recording
- **Real-device tests:** use `tools/run-m1-device-smoke.sh`

## Next Steps for Developers

1. **Read this document** to understand Android code structure
2. **Read `docs/protocol.md`** for wire protocol details
3. **Read `android/README.md`** for build instructions
4. **Run `m1-smoke`** on a real device to see protocol in action
5. **Explore `RpcDispatcher.java`** (main request handler)
6. **Explore `DmFileProvider.java`** (file system abstraction)
7. **Check `docs/m1-status.md`** for implementation gaps

## Adding New Features

### Adding a New RPC Request

1. Define protobuf message in `proto/v1/*.proto`
2. Regenerate Java code: `./gradlew :app:generateDebugProto`
3. Add handler method to `RpcDispatcher`
4. Update request dispatch switch case
5. Add unit test to `RpcDispatcherTest`
6. Update Mac harness to send request

### Adding a New Provider

1. Add new root type to `DmFileProvider.listRoots()`
2. Implement `listDirectory()` for new provider
3. Implement `openDownloadReader()` if provider supports download
4. Implement `openUploadWriter()` if provider supports upload
5. Add path validation and error handling
6. Add unit tests to `DmFileProviderTest`

## References

- [Android README](../android/README.md): build and run instructions
- [Protocol Documentation](../docs/protocol.md): wire format and semantics
- [Path Model](../docs/path-model.md): logical path abstraction
- [Android Permissions](../docs/android-permissions.md): permission model
- [M1 Status](../docs/m1-status.md): implementation checklist
- [M1 Testing Guide](../docs/m1-testing-guide.md): test scenarios
