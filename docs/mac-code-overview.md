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
│   │   ├── DeviceMarketingNameResolver.swift # Privacy-bounded retail-name catalog/cache
│   │   ├── FrameCodec.swift    # Length-prefixed frame encoding/decoding
│   │   ├── FrameReader.swift   # Streaming frame reader
│   │   ├── AsyncFramedTcpSession.swift # Product-facing async transport actor
│   │   ├── AsyncTimeoutPolicy.swift # Safe timeout conversion and saturation
│   │   ├── TransportError.swift # Stable async transport errors
│   │   ├── RpcEnvelopeCodec.swift # Shared envelope construction/validation
│   │   ├── AsyncRpcControlClient.swift # Product-facing async RPC actor
│   │   ├── AsyncRpcMultiplexer.swift # Single-reader lifecycle + send admission
│   │   ├── AsyncRpcMultiplexerInboundRouting.swift # Actor-isolated inbound routing
│   │   ├── AsyncRpcMultiplexerUploadWindow.swift # Actor-isolated upload-window sequencing
│   │   ├── AsyncRpcTransferFrames.swift # Pure transfer frame construction
│   │   ├── AsyncRpcDeadlines.swift # RPC/open/ACK deadline lifecycle
│   │   ├── AsyncRpcTransferControl.swift # Async cancel/pause control
│   │   ├── AsyncRpcRoutingState.swift # Route records + pure transfer validation
│   │   ├── AsyncRpcOneShot.swift # Single-consumer callback/async race boundary
│   │   ├── AsyncTransferHandles.swift # Public download/upload actors + bounded chunk queue
│   │   ├── TransferWireMetadata.swift # Opaque inactive-side upload labels
│   │   ├── AsyncAtomicDownloadWriter.swift # Non-blocking serial file-I/O adapter
│   │   ├── TransferResumeRecords.swift # Shared camelCase download/upload sidecars
│   │   ├── AsyncTransferResumeStore.swift # Serial durable checkpoint I/O
│   │   ├── AsyncDownloadCoordinator.swift # Product download reconnect/resume scheduler
│   │   ├── AsyncUploadFileSource.swift # Stable serial source-file reader
│   │   ├── AsyncUploadFileSender.swift # Shared bounded window file pump
│   │   ├── AsyncUploadCoordinator.swift # Product window refill/reconnect scheduler
│   │   ├── AsyncUploadPartialCleanup.swift # Exact persisted remote-partial identity
│   │   ├── AsyncMixedTransferSmokeClient.swift # Async mixed-direction device probe
│   │   ├── AsyncTransferProgress.swift # Receiver-confirmed progress value
│   │   ├── AsyncTransferRateEstimator.swift # Monotonic rolling rate
│   │   ├── AsyncTransferScheduler.swift # Observable FIFO product job queue
│   │   ├── AsyncTransferSchedulerCompletionPolicy.swift # Pure executor-unwind reconciliation
│   │   ├── AsyncTransferSchedulerConsumerState.swift # Actor-confined consumer delivery
│   │   ├── AsyncTransferSchedulerExecutionPolicy.swift # Pure retry/progress/rate transitions
│   │   ├── AsyncTransferSchedulerJobRunner.swift # Stateless execution event bridge
│   │   ├── AsyncTransferSchedulerPersistence.swift # Pure manifest conversion
│   │   ├── AsyncTransferSchedulerPersistenceState.swift # Actor-confined store health + I/O
│   │   ├── AsyncTransferSchedulerPolicy.swift # Pure restore/checkpoint policy
│   │   ├── AsyncTransferSchedulerRateExpiryState.swift # Actor-confined rate timers
│   │   ├── AsyncTransferSchedulerSessionEndPolicy.swift # Pure session-end transitions
│   │   ├── AsyncTransferSchedulerUploadCleanup.swift # Durable cleanup lifecycle
│   │   ├── AsyncTransferSchedulerTypes.swift # Public queue contract + executor wiring
│   │   ├── TransferQueuePersistence.swift # Versioned atomic queue manifest
│   │   ├── PrivateAtomicFileWriter.swift # Private-state transaction orchestration
│   │   ├── PrivateAtomicFileWriterInternals.swift # Pinned POSIX proof helpers
│   │   ├── DirectoryListing.swift # Protobuf-free paged listing domain
│   │   ├── ProductMimeType.swift # Bounded descriptive MIME metadata
│   │   ├── AsyncPairingClient.swift # One-shot first-pairing coordinator
│   │   ├── SessionAuthenticator.swift # Canonical auth transcript/HMAC/HKDF
│   │   ├── PairingAuthenticator.swift # P-256/SAS/identity verification
│   │   ├── PairingCredentialStore.swift # Non-sync Keychain records
│   │   ├── HandshakeSmokeClient.swift # ClientHello/ServerHello test
│   │   ├── ProductDeviceSessionContracts.swift # Product session public contract
│   │   ├── ProductDeviceSessionCoordinator.swift # Authenticated session lifecycle
│   │   ├── ProductDisplayText.swift # Bounded external-name UI projection
│   │   ├── ProductTransferSchedulerAssembly.swift # Credential/access/executor wiring
│   │   ├── ProductTransferSchedulerLifecycle.swift # Actor-confined scheduler/build state
│   │   ├── ProductDeviceSessionResources.swift # Ordered teardown + transfer gate
│   │   ├── ProductDeviceSessionEvent.swift # Buffered terminal session event
│   │   ├── M1SmokeClient.swift # Async baseline control-plane smoke
│   │   ├── TransferResults.swift # Shared async transfer result values
│   │   ├── RpcControlClientError.swift # Shared RPC validation errors
│   │   ├── AtomicDownloadWriter.swift # Download descriptor + transaction owner
│   │   ├── AtomicDownloadPartialFile.swift # Stateless partial-file POSIX boundary
│   │   ├── ProcessRunner.swift # Subprocess execution helper
│   │   ├── LockedValue.swift   # Thread-safe value wrapper
│   │   └── Crc32.swift         # CRC32 checksum
│   ├── DroidMatchPresentation/ # MainActor native product-state boundary
│   │   ├── DeviceDiscoveryModel.swift
│   │   ├── DirectoryBrowserPresentationTypes.swift # Stable UI values + safe names
│   │   ├── DirectoryBrowserPolicy.swift # Pure media/mutation/error decisions
│   │   ├── DirectoryBrowserModel.swift # MainActor presentation/list/media state
│   │   ├── DirectoryBrowserThumbnailState.swift # Pure FIFO/cache generations
│   │   ├── DirectoryBrowserMutationRunner.swift # Remote-mutation Task owner
│   │   ├── DirectoryBrowserSelectionState.swift # Pure browser selection invariants
│   │   ├── MediaLibraryModel.swift # Live roots + three independent browsers
│   │   ├── TransferQueueDataSource.swift
│   │   ├── TransferQueuePresentationItem.swift
│   │   └── TransferQueueModel.swift
│   ├── DroidMatchAppSupport/  # App-owned local authority + UI admission
│   │   ├── ProductUploadSelectionPolicy.swift # Native upload batch validation
│   │   └── ProductFileBrowserTransferPolicy.swift # Panel/snapshot/download preflight
│   ├── DroidMatchApp/          # Localized SwiftUI product shell
│   │   ├── DroidMatchDesktopApp.swift
│   │   ├── AppShellView.swift
│   │   ├── DeviceDashboardView.swift
│   │   ├── ProductFileBrowserView.swift # Browser state/action composition
│   │   ├── ProductFileBrowserContent.swift # Stateless list/grid rendering
│   │   ├── ProductMediaLibraryView.swift # Media sections + permission recovery
│   │   ├── ProductFileBrowserChrome.swift # Stateless browser visuals + sheets
│   │   ├── ProductFileBrowserToolbar.swift # Stateless toolbar state/actions
│   │   ├── AppStrings.swift
│   │   └── Resources/          # English and Simplified Chinese strings
│   └── DroidMatchHarness/      # CLI tool for testing
│       ├── main.swift          # Dispatcher and control-plane probes
│       ├── HarnessCLI.swift    # Shared option parser and typed CLI errors
│       ├── HarnessHelp.swift   # Stable command/help contract
│       ├── HarnessTransferCommands.swift # Download CLI probes
│       └── HarnessUploadCommands.swift   # Upload CLI probes
├── Tests/
│   ├── DroidMatchCoreTests/    # Unit tests for core library
│   └── DroidMatchPresentationTests/ # UI-state/lifecycle privacy tests
├── App/Info.plist              # Local bundle metadata + build/source provenance keys
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
- Races completion, timeout, and task cancellation through the same lock-backed one-shot used by RPC waiters, preserving first-completion semantics without a second continuation state machine or trapping missing-result branch; ambiguous sessions still close instead of being reused
- Rejects invalid durations before opening the connection and uses the shared timeout policy instead of converting user-controlled floating-point values directly to `DispatchTime`
- Powers every CLI and product RPC/transfer path; the former semaphore transport has been deleted
- Selects either FIFO round-trip or multiplexed mode for the connection lifetime; multiplexed mode keeps one independent reader and serialized writers

**AdbDeviceDiscovery / DeviceDiscoveryModel** (`DeviceDiscovery.swift`, `DroidMatchPresentation/DeviceDiscoveryModel.swift`)
- Runs the bounded blocking `adb devices -l` process on a private serial queue, never MainActor
- Keeps raw ADB serials inside the Core actor and emits process-local opaque UUIDs plus model/product/state only
- Passes only ADB model/device/product parameters to a UI-only retail-name resolver. Concrete aliases live in the signed, versioned `DroidMatchCore/Resources/device-marketing-name-aliases.json` table rather than Swift logic. The generic loader checks the file bound before reading, requires the exact root/record schema, rejects the whole table on any invalid identity, display text, language tag, or credential-bearing/non-HTTPS source, and then rejects duplicate matches. An assembled App reads only the signed main-bundle table and never SwiftPM’s generated absolute build-tree fallback; tests and command-line products retain the module-bundle fallback. It follows Mac preferred languages through exact-tag/region/script/base-language fallback while persisting only the canonical name. 704SH resolves offline to `シンプルスマホ4`; because Sharp publishes no reviewed Chinese or English alias in the catalog, those languages retain that canonical name instead of receiving an invented translation. Another cache miss schedules, but never awaits, an ephemeral no-cookie/no-redirect streaming request to one exact Google Play full-catalog URL. A dedicated catalog-loader actor enforces byte/encoding/row/field limits and builds the process-local unique-name index from non-truncating 512-scalar identifiers; the resolver actor caps pending tuples at 64 and retains at most 512 projected safe canonical names under full-tuple hashes rather than raw parameters
- Sorts devices first by connection-state rank and then by the same marketing/model/product fallback shown as the card title, so a resolved retail name cannot leave the visible list ordered by a hidden technical model
- Persists Google-derived names in a source-tagged v3 cache with a bounded verification timestamp. Fresh entries stay fully offline; only an expired, previously verified v3 value is returned immediately while the same complete catalog is revalidated in the background. A source-unknown v2 entry migrates as unverified and stays hidden until the current reviewed aliases or a complete catalog validates it; malformed v3 entries are scrubbed during resolver initialization. The in-memory index keeps its own verification time so a later query cannot mint false freshness from an old download. A valid refresh updates renamed matches and removes entries no longer present or unambiguous; a failed refresh retains only a previously verified stale safe value and remains throttled. Current reviewed aliases always win, and a cached alias whose reviewed record was removed cannot survive as an unverified fallback
- Prefers `Contents/Resources/platform-tools/adb` in an assembled product; explicit environment and SDK paths remain development fallbacks
- Normalizes missing/failed/timed-out ADB into stable error categories rather than forwarding process stderr
- Maps invalid configured timeouts to stable `timedOut` before launching an ADB subprocess
- Sorts ready devices first, deduplicates malformed repeated serial rows, and keeps one UUID stable only while the device remains visible
- Allows only one preparation per opaque device ID, rejects a device that disappears or loses readiness before forwarding, and removes a newly allocated forward if cancellation wins
- Resolves the same retail/technical fallback during preparation, applies the credential UTF-8 byte ceiling once, and carries that canonical safe display hint on the anonymous forward lease for the authenticated title, fresh record, and trusted row; the lease contains no serial or pairing identity, and the hint never participates in transport routing or authentication
- Validates a release capability before consuming private cleanup ownership, so a mismatched release cannot prevent the later exact lease from removing its forward
- Atomically replaces successful MainActor snapshots, marks retained rows stale after failure, and rejects late refresh generations
- Powers the first real SwiftUI product page and owns its dynamic loopback forward lease; it does not establish the authenticated RPC session or mutate the Android device

中文：发现 actor 独占匿名设备 ID 与动态 loopback forward；同设备并发 preparation、消失/未就绪设备和取消竞态均 fail closed，mismatch release 不会丢失后续精确清理所需的私有所有权。认证 RPC 会话仍由产品 session coordinator 建立。

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
- Publishes the provisional credential through an atomic add-only store operation; every duplicate pairing ID fails without reading or updating the existing key
- Returns that freshly persisted Core record to the immediate authenticated session, avoiding a post-save Keychain read
- Stores a credential-byte-bounded projection of the lease retail name for a fresh pairing while continuing to authenticate and present the Android-supplied server name in the unchanged pairing transcript
- Has loopback tests for success, invalid identity, user rejection, and rollback; the native Mac UI remains open

**KeychainPairingCredentialStore** (`PairingCredentialStore.swift`)
- Stores a versioned pairing record as a non-synchronizing generic-password item
- Stores and validates a versioned key-free selector/display envelope in `kSecAttrGeneric`
- Gives the trusted-device UI a display-only list that uses the envelope or legacy account/label/Keychain dates and never requests password data
- Adds a non-interactive `LAContext` to that passive display query, so an item that would require authentication fails the snapshot instead of opening UI; explicit connection remains the credential-reading boundary
- Keeps credential selection separate: a current selector loads only the fingerprint-matched record; legacy accounts use Security.framework-compatible `MatchLimitOne` reads under one shared `LAContext`, then backfill every validated selector so later connections use the current path
- Checks pairing-ID collisions through key-free metadata for current records; successful reconnect does not rewrite the secret-bearing item, while a legacy collision check keeps one exact compatibility read
- The explicit-connection card and credential-free local Help explain that a
  macOS Keychain prompt authorizes reading the saved device-pairing key rather
  than requesting Apple signing material. DroidMatch has no password field, and
  a failed read first offers system-dialog retry guidance before re-pairing
- Rejects pairing-ID/device-fingerprint collisions and malformed or account-mismatched metadata
- Uses an injected Keychain backend in tests so unit runs never touch the developer's real login Keychain
- Keeps the Security.framework round-trip as an explicit `DROIDMATCH_RUN_SYSTEM_KEYCHAIN_TEST=1` integration check, so ordinary gates cannot trigger a login-Keychain prompt

**TrustedDevicesModel** (`DroidMatchPresentation/TrustedDevicesModel.swift`)
- Bounds the visible Keychain-loading state to five seconds without cancelling the underlying Security.framework request
- Keeps at most one metadata load alive, preventing repeated view tasks or refresh actions from stacking blocked Keychain work
- Publishes the existing unavailable state at the deadline, then accepts a late success only if no intervening revoke invalidated that list generation
- Publishes a distinct outstanding-request state so the App can explain that the display-only check will not open authentication UI and suggest reopening DroidMatch; a real retry is admitted only after the prior Security.framework request retires
- Clears retry admission when an invalidated stale request finally retires without allowing that request to republish pre-revoke rows
- Invalidates pending-list publication before revocation; false/error retains the current row and marks the snapshot unavailable, while the App presents only fixed localized failure guidance
- Shares a Core process-local display cache with the session coordinator. After an explicit authenticated reconnect, pre-existing generic records can render the resolved retail name on the next display-only refresh without another Keychain read/write; mapping stays pairing-ID keyed inside Core/AppSupport, preserves the existing anonymous UI ID, and a confirmed-revoke tombstone both clears it and rejects any later reordered authentication write
- Has a deterministic suspended-data-source test covering timeout, duplicate suppression, late recovery, mutation invalidation, and a subsequent fresh refresh

**Generated Protobuf Files** (`Generated/v1/*.pb.swift`)
- `rpc.pb.swift`: `RpcEnvelope`, `RpcRequest`, `RpcResponse`, `RpcError`
- `session.pb.swift`: Hello/authentication/heartbeat messages and authentication state
- `device.pb.swift`: `DeviceInfoRequest`, `DeviceInfoResponse`
- `file.pb.swift`: `ListDirRequest`, `ListDirResponse`, `DmFileEntry`
- `transfer.pb.swift`: `OpenTransferRequest`, `OpenTransferResponse`, `TransferChunk`, `TransferChunkAck`, `CancelTransferRequest`, `PauseTransferRequest`
- `error.pb.swift`: `ErrorCode` enum
- Generated by `protoc` from `proto/v1/*.proto`
- Regenerate with: `bash tools/generate-swift-proto.sh`
- With no `PROTOC_GEN_SWIFT` override, regeneration first runs the
  lockfile-pinned, clean-checkout-verified bootstrap automatically

### Client Layer

**AsyncRpcControlClient** (`AsyncRpcControlClient.swift`)
- Product-facing actor layered on `AsyncFramedTcpSession`
- Enforces ClientHello/ServerHello before heartbeat, device info, listing, or diagnostics
- With `PairingCredentials`, sends the client proof, verifies the server proof, and rejects correlation-only downgrade before entering ready state
- Carries the successful negotiation as the associated value of its `ready` state, so ready-without-cache is unrepresentable and repeated `handshake()` calls do not write duplicate frames
- Starts `AsyncRpcMultiplexer`, which owns request IDs and the only frame reader on the connection
- Routes concurrent control responses by request ID instead of serializing complete round trips
- Opens at most two active download/upload handles after checking negotiated capabilities
- Keeps a valid remote application error recoverable, but closes the session after transport, decoding, checksum, request-correlation, or envelope-shape failure
- The product coordinator sends a 10-second heartbeat on the authenticated control/browser client; terminal heartbeat failure tears down the session-owned gate/scheduler/client/forward before publishing a cached stable invalidation, while transfer attempts still use fresh authenticated clients

**AsyncRpcMultiplexer / frames / deadlines / routing / transfer handles** (`AsyncRpcMultiplexer.swift`, `AsyncRpcMultiplexerInboundRouting.swift`, `AsyncRpcMultiplexerUploadWindow.swift`, `AsyncRpcTransferFrames.swift`, `AsyncRpcDeadlines.swift`, `AsyncRpcTransferControl.swift`, `AsyncRpcRoutingState.swift`, `AsyncTransferHandles.swift`)
- Uses one shared lock-backed one-shot primitive for response, open, ACK, queue,
  and readiness callbacks. Its first wait atomically claims the sole consumer;
  accidental reuse returns a typed state error rather than overwriting an active
  continuation, hanging the original task, or reaching a precondition crash.
- Permanently claims multiplexed transport mode; FIFO round-trip code cannot share that session
- Serializes frame writes while one independent reader routes response, error, download-chunk, and upload-ACK frames
- Groups inbound envelope parsing, waiter resolution, route mutation, and bounded download yield in a same-actor extension with no copied state, reader, or socket ownership
- Keeps route records, request-ID rotation, and pure open/window/offset validation in a value-only helper with no actor, task, socket, or waiter resolution
- Keeps upload-window producer/ACK sequencing in a focused same-actor extension; the extension owns no copied route, waiter, task, or socket state
- Builds and validates open-transfer, chunk, and acknowledgement protobuf frames in a pure namespace; request-ID allocation, route admission, sends, and waiter ownership remain actor-isolated
- Enforces 16 in-flight control requests, two active transfer IDs/streams, 1 MiB chunk size, and per-stream buffering of at most 4 chunks / 2 MiB
- Exposes ordered download `nextChunk` + ACK, single upload `sendChunk`, and deterministic preflighted upload `sendWindow` handles
- Adds `AsyncDownloadTransfer.receive(to:resume:)`, which owns chunk/write/ACK order and atomically commits only after the final ACK
- Runs blocking Foundation file operations on a private serial queue, leaving the session and other transfer actors responsive
- Rechecks the local partial length against the remote accepted offset, cancels on mismatch, and keeps partial data after protocol cancellation
- Validates an entire upload window before its first wire frame, submits it in offset order, and retires ACK waiters from the queue head
- Lets protocol cancellation end one upload window while preserving the session; direct Swift Task cancellation after admission of mutation or transfer-control work closes the ambiguous session
- Treats cancellation before send admission as request-local. For admitted read-only heartbeat, device-info, listing, diagnostics, and thumbnail work, caller cancellation leaves the request ID and original deadline installed so the sole reader validates and drains the late response; malformed or mismatched late payloads remain session-fatal
- 中文：发送准入前的取消只移除本地 waiter；已准入的 mutation/传输控制取消会关闭歧义会话，而 heartbeat、device-info、listing、diagnostics 与 thumbnail 等只读请求会在原 deadline 内校验并排空迟到响应；畸形响应仍会关闭会话
- Five focused real-TCP cancellation regressions cover pre-admission cancellation, read-only late-response drain/session reuse, malformed late response teardown, original-deadline enforcement after caller cancellation, and admitted-mutation session teardown
- 中文：五项真实本地 TCP 取消回归覆盖准入前取消、只读迟到响应排空/会话复用、畸形迟到响应 teardown、调用者取消后原 deadline 仍生效，以及已准入 mutation 的会话 teardown
- Keeps an idle reader alive without applying a request timeout; each actual request/open/ACK wait has its own deadline
- Keeps those RPC/open/ACK deadline tasks in a dedicated extension; expiry still terminates through the owning actor, while nanosecond conversion saturates before `Double` to `UInt64` conversion so the largest finite timeout cannot trap at the rounded 2^64 boundary
- Holds real local TCP control/open/ACK requests without replying to prove typed deadline failures close the ambiguous session; both download and upload open directions are covered
- Local TCP E2E interleaves a multi-chunk download, a full four-chunk upload window, and heartbeat, then proves cancel + post-cancel heartbeat reuse
- Keeps the framed test server split by ownership: the 367-line base owns the only listener plus echo/general request scenarios, while the 225-line Authentication extension owns Hello and paired proof; the 209-line Control, 181-line Download, and 356-line Upload extensions own their protocol-role response construction. Every file extends the same server type without copying listener, connection, or request-lifecycle state
- 中文：本地 framed test server 的 367 行基类唯一持有 listener 与 echo/通用请求场景，225 行 Authentication extension 持有 Hello 与配对证明；Control、Download、Upload extension 继续按协议角色构造响应，所有文件共享同一 server 类型且不复制 listener、连接或请求生命周期
- 中文：真实本地 TCP fixture 会分别保持 control、download/upload open 与 upload ACK 请求无响应，验证 deadline 返回 typed timeout 并关闭歧义会话；超大有限 timeout 的纳秒换算不会 trap

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
- Real local TCP coverage proves the exact Hello → heartbeat → device info → `dm://roots/` → diagnostics orchestration and verifies that the wrapper closes its owned session when a recoverable remote application error interrupts the sequence
- 中文：真实本地 TCP 测试覆盖完整 control-plane 顺序，并验证可恢复远端错误中断编排时由 M1SmokeClient 关闭其独占 session
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
- Powers `mixed-transfer-smoke` and the device script's opt-in `--mixed-transfer-check`; local TCP coverage and the archived Slot C MEIZU M20 physical-device result both cover the same-session heartbeat and stream completion contract
- Keeps the local mixed-transfer fixture on one server and one existing lock-protected state: the 386-line listener/control plus happy path, 246-line cancellation/reuse extension, and 109-line resume-failure extension share the same wire helpers without copying connection or request lifecycle state
- 中文：mixed-transfer 本地 fixture 仍只有一个 server 和一份既有锁保护状态；正常路径、取消/复用与恢复失败按场景拆分，但共享同一 wire helper，不复制连接或请求生命周期

**Control client entry points:**
- `M1SmokeClient.run()`: async baseline smoke (handshake → heartbeat → device info → roots → diagnostics)
- `AsyncRpcControlClient`: product control/listing and multiplexed transfer entry point

### File Handling

**PrivateAtomicFileWriter** (`PrivateAtomicFileWriter.swift`, `PrivateAtomicFileWriterInternals.swift`)
- Atomically reads, writes, or removes App-owned queue, bookmark, and transfer-state files beneath a pinned no-follow parent, with fixed discoverable recovery names and a per-destination cross-process lock
- Keeps the three transaction orchestrators in the primary file; a same-module extension owns pinned-location construction, exact descriptor/name snapshots, rollback proofs, tracked unlink, and directory synchronization without changing their call order or error mapping
- Fails closed on unsafe permissions, non-regular or multiply linked entries, parent rebinding, unexpected recovery nodes, and any publication/rollback state that cannot be proven; eight focused filesystem and cross-process lock tests cover the split

**AtomicDownloadWriter / AtomicDownloadPartialFile** (`AtomicDownloadWriter.swift`, `AtomicDownloadPartialFile.swift`)
- Keeps descriptor and transaction orchestration in the 480-line writer, while a 274-line stateless partial-file boundary owns no-follow directory opening, partial creation, single-link regular-file validation, non-blocking `flock`, descriptor/name inode reconciliation, and exact destination snapshot comparison without retaining any descriptor or writer state. All 18 focused atomic-download tests pass unchanged and the then-427-test Swift inventory was unchanged
- 中文：480 行 writer 保留 descriptor 与事务编排；274 行无状态 partial-file 边界负责 no-follow 目录打开、partial 创建、单链接普通文件校验、非阻塞 `flock`、descriptor/name inode 对账及精确目标快照比较，且不保留 descriptor 或 writer 状态。18 项原子下载专项测试原样通过，当时 427 项 Swift 库存不变
- Pins the authorized destination directory with a descriptor and opens all
  siblings relative to it. Fixed macOS `/var`, `/tmp`, and `/etc` aliases
  map to `/private` first; every other component is opened no-follow, so
  user/volume ancestor symlinks fail with path-free
  `unsafeDestinationDirectory`. Operator evidence still uses `/private/tmp`
  for canonical, comparable paths
- Requires both the pinned child entry and opened descriptor to be a single-link
  regular file before any truncate/write. A fresh open acquires the existing or
  newly created partial without truncation, locks it, and revalidates the name;
  `resetFresh` then uses `ftruncate` on that locked descriptor rather than
  unlinking and recreating the entry
- Takes a non-blocking exclusive `flock`, rechecks that the locked descriptor
  still matches the pinned directory entry, and retains the lock on a duplicate
  descriptor through output close and final publication. Cooperating aliases
  and writers therefore fail with a stable busy/unsafe result; advisory `flock`
  is not a defense against a malicious same-UID process that ignores the lock
- Product acquisition first reserves the seven derived entries in an in-process
  parent-inode/case-aware registry and sorted cross-process advisory locks. A
  verified parent-relative `0700` root, `0600` identity anchor, and persistent
  empty single-link `0600` SHA-256-named lock files bind cooperating processes
  to the same lock inodes; the hashes avoid direct path disclosure but are
  pseudonymous metadata rather than encryption
- Fresh sidecar removal remains a coordinator/store operation. It uses pinned-
  parent no-follow validation and exact non-recursive removal; unexpected
  directories, symlinks, FIFOs, and hard links remain untouched and fail closed
- On successful receive, synchronizes the partial, validates destination/partial
  snapshots, creates and synchronizes a fixed `0600` commit marker, then
  publishes with same-directory `RENAME_EXCL` or validated `RENAME_SWAP`.
  A displaced old destination moves to fixed `.droidmatch-replaced` and remains
  recoverable while the coordinator removes the sidecar. Finalization only then
  unlinks the verified old entry, synchronizes the directory, and removes the
  marker. Failure or cancellation before finalization restores the old target
  and moves the candidate back to partial while retaining the marker, restores
  the sidecar, and retires the marker only after that checkpoint is durable. A
  failed checkpoint restore therefore remains discoverably interrupted;
  unprovable restoration returns
  non-retryable `commitUncertain`. Crash-left marker/replaced entries block
  automatic resume and restore the job as `interrupted`. Directory `fsync`
  is required, though this is not a complete power-loss durability guarantee
- On error or cancel, leaves partial file for manual cleanup or resume
- Reports the non-mutating local resume offset used by the scheduler before open

**AsyncAtomicDownloadWriter** (`AsyncAtomicDownloadWriter.swift`)
- Serializes create/write/close/commit on a private Dispatch queue so blocking file calls do not occupy Swift's cooperative executor
- Is owned only by `AsyncDownloadTransfer.receive(to:resume:)`; callers cannot race the underlying `FileHandle`
- Sidecar persistence remains a scheduler/harness responsibility, not a writer responsibility

**AsyncDownloadCoordinator / AsyncTransferResumeStore** (`AsyncDownloadCoordinator.swift`, `AsyncTransferResumeStore.swift`)
- Injects an `AsyncRpcControlClient` factory so transport creation and pairing/authentication configuration stay outside transfer persistence policy
- For a fresh attempt, first creates the writer in deferred-reset mode and
  acquires the partial `flock`, then safely removes the old sidecar, calls
  `resetFresh` on that locked FD, snapshots the empty partial, and only afterward
  invokes the authenticated-client factory. An ancestor-symlink alias to a
  partial already held by a cooperating writer therefore returns busy before
  either checkpoint file is mutated
- Reloads the on-disk checkpoint before each attempt and reopens with the same transfer ID, the actual partial length, and the accepted source fingerprint
- Uses the cancellable async `RecoveryPolicy` executor for retry classification and backoff; a corrupt record or an orphaned non-empty partial fails visibly instead of silently restarting
- Holds the commit marker and any displaced old destination while removing the
  sidecar, checks cancellation again, and only then finalizes publication.
  Sidecar cleanup failure rolls publication back with the marker retained,
  republishes the exact checkpoint, and only then retires the marker; checkpoint
  restore failure leaves the marker, while inability to prove rollback becomes
  `commitUncertain`

**AsyncUploadCoordinator / AsyncUploadFileSource / partial cleanup** (`AsyncUploadCoordinator.swift`, `AsyncUploadFileSource.swift`, `AsyncUploadPartialCleanup.swift`)
- Opens one `O_NOFOLLOW` regular-file descriptor for the entire attempt and
  checks size, nanosecond mtime, nanosecond ctime, filesystem, and inode on both
  that descriptor and the current path before and after each private-queue read
- Persists that exact identity in format-v2 checkpoints; same-size/same-millisecond
  replacement is rejected, while a non-zero legacy v1 record fails before the
  authenticated-client factory is called
- Scheduler restoration checks only durable v2 shape and path binding because
  it does not yet hold the product bookmark lease. Once AppSupport grants that
  lease, the coordinator snapshots the exact source and compares the checkpoint
  before invoking the authenticated-client factory; stale source state therefore
  never opens a transport
- Fills deterministic windows of at most four chunks / 2 MiB and persists each ordered ACK rather than treating sent bytes as durable
- Reopens app-sandbox/SAF uploads with the same transfer ID and last ACKed offset after a retryable disconnect; a local TCP test sends 8 bytes, persists only offset 2, then resumes from 2
- Keeps the three coordinator behavior tests in a 220-line suite, while one 445-line test-only support boundary owns the recovery TCP server, wire sequencing, and synchronization probes; production visibility and protocol behavior are unchanged
- 中文：三项 coordinator 行为测试保留在 220 行套件中；445 行测试 support 统一持有恢复 TCP 服务器、wire 顺序与同步 probe，生产可见性和协议行为均不变
- Keeps MediaStore fresh-only, rejects resume/retry policy for non-resumable destinations, and retains the last sidecar checkpoint on task cancellation
- Creates a resumable sidecar before the first client factory call, publishes the
  exact destination/transfer/expected-size tuple to the scheduler, and removes a
  newly created sidecar if that write-ahead observer rejects persistence
- Discards that tuple through a fresh authenticated client with the normal
  recovery classifier; remote idempotent success precedes local sidecar removal

**AsyncTransferScheduler / execution, completion, control, cleanup, consumer state, rate timers, runner, and persistence** (`AsyncTransferScheduler.swift`, `AsyncTransferSchedulerExecutionPolicy.swift`, `AsyncTransferSchedulerCompletionPolicy.swift`, `AsyncTransferSchedulerConsumerState.swift`, `AsyncTransferSchedulerControlPolicy.swift`, `AsyncTransferSchedulerRateExpiryState.swift`, `AsyncTransferSchedulerJobRunner.swift`, `AsyncTransferSchedulerPersistence.swift`, `AsyncTransferSchedulerPersistenceState.swift`, `AsyncTransferSchedulerPolicy.swift`, `AsyncTransferSchedulerSessionEndPolicy.swift`, `AsyncTransferSchedulerUploadCleanup.swift`, `TransferQueuePersistence.swift`)
- Admits download/upload coordinator requests in FIFO order with a default global limit of two running jobs
- Treats final, partial, sidecar, sidecar `.pending`/`.removing`, fixed commit
  marker, and fixed replaced entry as one lexical namespace. Any intersection
  rejects a second non-terminal download; the compatibility API publishes a
  failed row, the validated API throws a stable duplicate error, and restoration
  interrupts every conflicting row rather than selecting a winner. Product
  execution additionally holds an in-process reservation keyed by parent
  device/inode and volume case semantics plus sorted cross-process advisory
  locks for all seven derived names, the security-scope lease, and directory FD.
  A verified private parent-relative root/anchor and persistent empty hashed lock
  files keep cooperating providers/schedulers/processes on the same lock inodes
  without directly storing destination paths
- Keeps the immutable public job/snapshot contract and coordinator/executor wiring in `AsyncTransferSchedulerTypes.swift`, leaving queue/runtime transitions in the actor implementation
- Separates the 247-line queued/running/backoff pause suite from the 471-line retry/progress/terminal suite; both reuse the 212-line test-support boundary, preserving all 275 Swift tests that existed at the time without changing assertions or production code
- Separates the 128-line queue-store format/permission contract from the 494-line scheduler restoration/fail-closed persistence suite; both reuse a 126-line deterministic persistence fixture boundary without changing test names or behavior
- Runs executor dispatch and serializes synchronous retry callbacks ahead of later progress and terminal events in one stateless runner; its short-lived relay owns no scheduler lifecycle task registry, queue, persistence, or job state
- Keeps sidecar validity, persisted-state mapping, request metadata, and resume-request rewriting in a pure policy namespace with no tasks, waiters, timers, or sockets
- Converts shutdown/suspension records and queue membership in a pure session-end policy that returns explicit actor effects; the scheduler still owns and applies executor cancellation, requests rate-timer cancellation, delivers completion, persists, broadcasts, and waits for unwind
- Persists prepared resumable-upload cancellation as schema-v2 `cleanupPending`.
  The cleanup extension prioritizes restored disposal, waits for exact remote
  confirmation before settling cancellation, keeps failure retryable, and makes
  failed/interrupted history removal asynchronous until cleanup succeeds. Closing
  sessions start no new cleanup executor; AppSupport retains the source bookmark
  until the deferred row actually disappears
- Converts pause/resume/cancel record and FIFO mutations in a 152-line pure control policy. Its reversible action preserves the exact pre-write record/queue and returns the existing ordered settle/start/rate-expiry/executor effects; the actor applies them only after manifest persistence succeeds. Four direct policy tests cover rollback, retry attempt accounting, stable resume identity/FIFO tail admission, and immediate versus active cancellation order, raising the then-current Swift inventory to 297
- 中文：152 行纯控制策略只修改 pause/resume/cancel 的记录与 FIFO；可回滚 action 保留写盘前状态并返回既有有序副作用，actor 仅在 manifest 写入成功后应用。四项直接测试覆盖回滚、重试 attempt、稳定 resume 身份/FIFO 尾部以及两类取消顺序，使当时的 Swift 测试总数升至 297
- Applies retry, monotonic stable-total progress, and rate-expiry generation transitions in a 120-line pure execution policy. A retry returns either fail-stop or an exact pre-write rollback value, while four direct tests cover valid retry persistence, persistence failure, invalid attempt accounting, retry recovery progress, regression rejection, and stale/current rate expiry. It owns no task, timer, store, queue, continuation, socket, or broadcast; the scheduler actor is now 699 lines and the Swift inventory is 431
- 中文：120 行纯 execution policy 负责 retry、总量稳定的单调进度及 rate-expiry generation transition；retry 返回 fail-stop 或精确写盘前回滚值。四项直接测试覆盖有效 retry 写盘、写盘失败、非法 attempt、retry 后进度恢复、回退拒绝及新旧 rate 过期。它不持有 task、timer、store、queue、continuation、socket 或 broadcast；scheduler actor 现为 699 行，Swift 库存为 431 项
- Reconciles executor unwind in a 68-line pure completion policy that mutates only one supplied record and returns an explicit paused/interrupted/terminal resolution. It owns no Task, queue, store, timer, continuation, or broadcast; one direct test covers ordinary pause unwind, conservative session interruption, and an irreversible committed download, bringing the then-current Swift inventory to 427
- 中文：68 行纯 completion policy 只修改传入的单条 record，并返回明确的 paused/interrupted/terminal resolution；它不持有 Task、queue、store、timer、continuation 或 broadcast。一项直接测试覆盖普通暂停退场、保守会话中断与已不可回滚的下载提交，使当时 Swift 测试库存增至 427
- Keeps terminal outcomes, completion waiters, and buffering-newest snapshot observers in one actor-confined consumer-state value that starts no tasks, performs no persistence, and mutates no jobs
- Keeps rate-expiry Task replacement/cancellation in a 49-line actor-confined value; runtime-effect application, live task/job ownership, and snapshot publication remain exclusively in the 699-line scheduler actor, while the pure execution policy validates the supplied record generation
- 中文：49 行 actor-confined 值只管理速率过期 Task 的替换/取消；运行时副作用应用、存活 task/job 所有权和快照发布仍由 699 行 scheduler actor 独占，纯 execution policy 只校验传入 record 的 generation
- Converts manifests to canonical runtime records and back in a separate pure boundary; a 73-line actor-confined persistence state owns store I/O, coarse health, and the reload latch, returns stable `ioFailure` instead of trapping if a process-local instance is asked to reload, and lets the actor apply only a fully canonicalized immutable result
- 中文：73 行 actor-confined persistence state 统一持有 store I/O、粗粒度健康状态和 reload 闩锁；process-local 实例若被误用来 reload 会返回稳定 `ioFailure` 而非 trap，scheduler actor 只应用完成 canonical write 后的不可变恢复结果
- Declares scheduler admission with Swift typed throws, making the compatibility `submit()` projection exhaustive at compile time instead of retaining an unreachable fallback process trap
- Bounds untrusted manifests to 10,000 jobs/retries, one-day delays, and cumulative attempt 1,000,000. State-specific validation reserves the complete configured retry policy, permits a paused resume base only at the consumed attempt or a genuinely announced retry, and interrupts active recovery without headroom. Retry, resume, and terminal arithmetic use the same checked helper; retry persistence failure rolls back the attempted mutation, cancels its executor, and disables persistent execution
- 中文：不可信 manifest 限制为 10,000 个 job/重试、一天退避和累计 1,000,000 次 attempt；状态化校验为完整恢复策略预留空间，paused 只能从已消费 attempt 或真实发布的 retry 继续，active 无余量则 interrupted。retry/resume/terminal 共用 checked helper；retry 写盘失败会回滚 attempt mutation、取消 executor 并关闭持久执行
- Publishes buffering-newest full snapshots for queued/running/retrying/pausing/paused/completed/failed/cancelled/interrupted states, including retry attempt, backoff, confirmed bytes, total bytes, completion fraction, and UI-ready pause/resume/cancel/remove capability flags
- Accepts only monotonic absolute progress with one stable total across retries; synchronous retry notifications are serialized ahead of immediate reconnect progress and terminal state
- Derives progress from receiver-confirmed checkpoints rather than bytes merely placed on the wire: download write + ACK and upload ACK + resumable sidecar commit
- Computes `recentBytesPerSecond` with a two-second time-weighted monotonic window; retry clears it, an active stall automatically publishes nil, and a terminal transition freezes any still-valid sample
- Cancels queued work without invoking an executor and propagates running cancellation into the owning coordinator task
- Holds queued jobs directly; for checkpointed, incomplete downloads and app-sandbox/SAF uploads, cancels the coordinator's exclusive session, preserves partial/sidecar state, then requeues the same job/transfer identity at the FIFO tail with `resume = true`
- Rejects running pause before a trusted checkpoint, after 100% confirmation, and for fresh-only MediaStore uploads; this local checkpoint policy does not claim wire-level upload pause support
- Keeps terminal outcomes waitable/removable while preventing a cancelling-but-still-unwinding task from being removed early
- During session suspension, unsafe active work is published as interrupted but
  remains unsettled until its executor unwinds. Ordinary unwind preserves that
  result; only a download explicitly beyond its local rollback boundary may
  complete, while upload success cannot override cancellation or suspension
- Remains process-local through its ordinary initializer; `restoring(...)` opts into a versioned, atomic app-owned manifest with stable UUID/FIFO identity
- Writes queued-to-active intent before executor start, exposes only coarse persistence health, and rejects pause/cancel side effects when their manifest transition cannot be written
- Supports a persistent execution latch for product restoration; every scheduler path that could admit work honors it, while a private local-endpoint projection lets AppSupport validate non-terminal authorization without exposing those paths to Presentation or logs
- On startup load/validation/canonical-write failure, publishes an empty `writeFailed` queue without starting executors or overwriting the archive. Product retry keeps execution held while AppSupport reloads bookmarks, acquires every checkpoint lease and pinned download context, reloads/canonicalizes the immutable restore plan, validates all required targets, reconciles authority, and only then activates. Any failure reasserts reload-required, so repair can be retried without process restart or partial publication
- Treats product session suspension as idempotent irreversible invalidation: internal executor unwind may finish its one conservative manifest write, but repeated suspension/shutdown are no-ops and stale callers cannot pause, resume, cancel, remove, retry persistence, reactivate execution, or prune from an authoritative endpoint projection
- Shares a package-scoped private atomic writer with AppSupport bookmarks so
  recovery data is created at fixed `.<name>.pending` with mode `0600`, file
  synchronization, and required parent-directory synchronization. A missing
  target is published with `RENAME_EXCL`; an existing target uses `RENAME_SWAP`,
  complete-stat two-way identity validation, and proven rollback on anomaly
- Uses that helper for bounded pinned-parent, no-follow, single-link regular-file
  reads and exact non-recursive removal as well as writes. Removal moves the
  expected entry to fixed `.<name>.removing`, validates complete stat, then
  unlinks. Every mutation rechecks parent-path binding and requires directory
  `fsync`; failure must prove rollback or return `commitUncertain` with the marker
  preserved. One permanent fixed `.droidmatch-private-atomic-lock` per used parent
  is a zero-byte, euid-owned, single-link `0600` regular inode; no-follow open,
  exclusive `flock`, and named-entry/FD identity checks serialize read/save/remove
  across cooperating processes and separate same-process opens. Unsafe lock or
  crash-left recovery nodes remain discoverable and fail closed. Unexpected
  directories, links, FIFOs, hard links, and entry-replacement
  races remain untouched; this remains a process-crash, not power-loss, contract
- Restores active download/app-sandbox/SAF work as paused only with structurally
  and path-valid state whose total is known/non-conflicting and whose offset is
  strictly below that total. `offset == total`, `0 / 0`, unknown/conflicting total,
  legacy non-zero v1, corrupt/missing checkpoint, and active MediaStore upload all
  become persistent, non-resumable `interrupted` rows rather than silent replays

**LocalFileAccessOwnerID / BookmarkingTransferQueueFactory / SecurityScopedBookmarkStore** (`LocalFileAccessOwnerID.swift`, `BookmarkingTransferQueueFactory.swift`, `SecurityScopedBookmarkStore.swift`)
- Derives one opaque, domain-separated owner only after authenticated device proof; only the AppSupport SPI can read its storage key, and normal/debug/reflection descriptions are forced redacted so it stays absent from public session info, scheduler snapshots, UI, diagnostics, and logs
- Keeps one AppSupport store actor and one process-wide FIFO gate for every owner-bound provider and queue data source. The coordinator holds that same gate across scheduler restoration, manifest reload, new-target coverage, and activation
- Builds the persistent product scheduler through a generation-bound single-flight; concurrent callers share one restore, disconnect cancels and tears down the in-flight resources, and build-ID cleanup cannot erase a newer session
- Persists v2 records as validated `(owner, canonical endpoint, bookmark)` entries, so one offline device cannot be pruned by another device's empty queue and another owner's same-path record cannot satisfy readiness
- Loads v1 path-only records into a separate legacy-unscoped compartment without guessing ownership. Owner-scoped authority wins; only a missing scoped record may fall back to legacy, and phase 1 does not prune legacy
- Rejects corrupt/unknown archives, invalid owner keys, duplicate records, and non-canonical scoped paths without overwriting the durable file; stale refresh updates only the selected scoped or legacy compartment

**TransferQueueModel** (`DroidMatchPresentation/TransferQueueModel.swift`)
- Uses a small `TransferQueueDataSource` seam and a concrete scheduler adapter, so native state tests do not need transport or file I/O
- Mirrors those ownership seams in tests: pure presentation/notification policy, MainActor observation/submission behavior, and concrete scheduler-adapter integration live in separate suites, while one test-only support file owns the shared probe, snapshots, and bounded polling helpers
- 中文：测试按同一职责边界拆分为纯展示/通知策略、MainActor 观察与提交、真实 scheduler adapter 三组；共享 probe、snapshot 与有界轮询只由一个测试 support 文件持有
- Starts one explicit, idempotent MainActor subscription; stop retains the last value, restart obtains the scheduler's fresh full snapshot, and a generation guard rejects late values from an old stream
- Preserves scheduler order and forwards pause/resume/cancel/remove without optimistic row mutation; a per-job pending set prevents duplicate UI actions while the authoritative call is outstanding
- Requires an authoritative non-failed persistence read before queue mutations, blocks them while recovery is being repaired, renders that pending state distinctly from healthy storage, and maps a late Boolean rejection to fixed localized UI feedback rather than raw storage detail
- Owns one MainActor submission lease across single and batch download/upload admission. Concurrent file or media calls return before the data-source boundary, while accepted queue jobs retain scheduler concurrency
- Clears only settled successful (`completed && canRemove`) history in stable queue order through independent existing removals. Failed, cancelled, interrupted, pending, and still-unwinding rows remain visible; unhealthy persistence blocks the operation and partial removal returns exact counts for bounded UI disclosure
- Publishes combined bookmark-registry/manifest `disabled`/`healthy`/`writeFailed` health without exposing filesystem paths or raw I/O errors, reloads authoritative health after submissions or queue mutations whose bookmark work may happen outside a scheduler snapshot, and requires current-owner or explicit legacy coverage for every non-terminal local endpoint
- Keeps a corrupt, empty, or incomplete startup bookmark archive from activating restored work; Retry reloads bookmarks, acquires all checkpoint scopes plus download directory contexts, reloads/canonicalizes the complete manifest with execution still latched, validates the newly authoritative targets, reconciles authority, and only then activates. Any failed product-restore phase remains reload-required. Resume uses the same consistency gate and is disabled in the UI during `writeFailed`
- Maps Core local paths into a bounded, spoofing-safe `ProductDisplayText` basename used by both rows and opt-in notifications; unused remote logical paths and raw failure descriptions remain below Presentation. An exact-label Core parser exposes only a coarse typed category, unknown or extended labels map to nil, and retrying/failed/interrupted rows use fixed localized guidance rather than platform text
- Submits only scheme-checked `dm://` downloads to a local file URL; the authenticated App session now starts/stops its observation and uses scheduler-authoritative state rather than synthetic rows

**DirectoryListing / DirectoryBrowserPolicy / DirectoryBrowserModel / MediaLibraryModel** (`DirectoryListing.swift`, `DroidMatchPresentation/DirectoryBrowser*.swift`, `MediaLibraryModel.swift`)
- Sends the complete path/page-size/sort/direction query while returning Android's opaque token unchanged; Presentation never imports generated protobuf types
- Maps embedded provider errors into stable categories without retaining message/details, and validates logical row identity, supported kind, page-local uniqueness, and immediate token repetition
- Canonicalizes optional provider MIME through `ProductMimeType`: restricted ASCII values are lowercased and capped at 127 bytes, the two product-owned virtual labels are allowlisted, and malformed metadata becomes nil without affecting row identity, capabilities, or authorization
- Mirrors browser ownership in separate pagination/navigation/lifecycle and mutation/media/presentation suites, with one test-only support boundary owning their shared actor probe and fixtures
- 中文：浏览测试按职责拆为分页/导航/生命周期与 mutation/media/展示两组证据；共享 actor probe 与 fixture 只由一个测试 support 边界持有
- Represents provider-unknown size/time as nil, including virtual roots and SAF/provider metadata gaps
- Keeps stable phase/failure/item values, independent `canBrowse` / `canAcceptUpload` projections, UI-only bidi/control-safe display names, and pure operation-specific mutation guidance in a 167-line declaration boundary; the raw name and canonical identity remain unchanged for explicit operations
- Maps create, rename, single-delete, and batch-delete failures to distinct fixed localized guidance. A synchronous create/rename admission rejection stays inside its still-visible edit sheet; admitted asynchronous failures return to the browser alert. Neither surface receives a path, item name, or raw exception
- 中文：创建、重命名、单删与批删使用各自固定的脱敏失败说明；同步准入拒绝留在仍可见的编辑 sheet 内，已准入后的异步失败回到浏览器提示，两者都不接收路径、条目名或原始异常
- Keeps direct-child name/path validation, loaded-item mutation admission, stable batch ordering, read-gated media thumbnail/preview eligibility, and Core-to-UI error mapping in a 153-line pure policy that owns no client, task, generation, token, cache, or published state
- Serializes load/refresh/load-more on MainActor, rejects stale non-cooperative responses by generation, atomically replaces a successful refresh, and retains rows/token after a failed next page so the user can retry
- Filters duplicate logical paths across offset-backed page boundaries and stops a cross-page token cycle before appending its suspect page
- Keeps published state, listing generations, navigation, pagination, derivative Tasks/previews/permission decisions, and path-gated mutation outcome application in the 628-line MainActor model. A separate 157-line MainActor runner uniquely owns the active remote-mutation Task and operation identity without owning presentation or refresh policy. Navigation cancels the old listing and clears queued old-generation thumbnails without cancelling an admitted mutation; same-path completion refreshes the current search/sort query, while a different path suppresses the stale result/error
- Bounds each browser's background 96-pixel row thumbnails through a 132-line pure state value that owns generation, FIFO, active keys, failure deduplication, and a path-keyed cache capped at 64 entries and 8 MiB. It deliberately retains draining old-generation keys against the four-active limit while denying stale publication; it owns no client, Task, permission decision, or Published value. Three direct tests cover that concurrency invariant, visible/failure admission, and dual cache bounds. Hiding a browser clears queued work, preview, and cached derivatives while preserving its listing/query/navigation; the user-driven 512-pixel preview is outside that queue and can be a fifth control request. Listing pagination preserves preview/thumbnail completion, so load-more cannot strand an open preview in its loading state
- Keeps admitted thumbnail/preview awaits alive until their real response or deadline instead of cancelling only the caller while Core still drains the wire request. A late permission failure remains fail-closed within the shared Images/Albums or Videos authorization domain, but cannot erase a browser that has since moved to an unrelated provider path
- 中文：已准入的缩略图/预览会等待真实响应或 deadline，不会只取消 caller 而让 Core 在后台继续排空却提前释放名额；迟到权限错误只在 Images/Albums 共享域或 Videos 域内 fail closed，不会清除已经切换到无关 provider 的浏览器
- 中文：目录导航只取消旧 listing 并清空旧 generation 尚未准入的行缩略图，不取消已准入 mutation；同 path 完成会刷新当前 search/sort query，不同 path 丢弃旧结果/错误。每个浏览器的 96 px 后台缩略图严格 FIFO 最多四项活跃，缓存同时限制为 64 项和 8 MiB；浏览器隐藏时清理排队、预览和缓存但保留 listing/query/导航。512 px 预览不在该队列中，可作为第五个 control request。listing 分页保留预览/缩略图完成的有效性，load-more 不会把已打开预览留在 loading
- Unreadable containers are rejected before navigation/listing, while an independently writable root remains a direct upload target for the authenticated SwiftUI file page
- Keeps media information architecture in a separate session-owned coordinator: one authenticated root-catalog refresh supplies live read/write metadata, and three independent browser models retain Images/Albums/Videos pagination and navigation queries. Explicit refresh first invalidates loaded display/derivative state, then reloads prior queries even when a selected-media root remains readable; a child permission error blocks only its captured section until explicit retry, preventing cross-section races and catalog/list loops. Three direct tests cover section independence, selected-scope/revocation clearing, stable permission failure, and bounded catalog recovery
- Exercises create/rename/delete plus item/album thumbnail RPCs through the real async client and a local TCP server, including capability gates, bounded embedded errors, malformed responses, pre-wire path validation, and post-error session reuse
- Rejects bare `dm://` mutation endpoints and media thumbnail paths without a non-negative decimal signed 64-bit item ID before allocating a request ID or writing to the socket

中文：浏览 mutation 与缩略图现有真实本地 TCP/RPC 边界测试；能力不足、provider 失败或畸形响应不会污染后续会话，裸 `dm://` 与非法 MediaStore item ID 会在发包前被拒绝。

**ProductDeviceSessionContracts / ProductDeviceSessionCoordinator / ProductTransferPersistenceLocation / ProductTransferSchedulerAssembly / ProductTransferSchedulerLifecycle / ProductDeviceSessionResources / DeviceSessionModel**
- Keeps product-facing values, coordinator/client protocols, and concrete client conformances in a declaration-only contract file; the actor remains the sole owner of session lifecycle state
- Keeps exact fingerprint revalidation, opaque local-access owner derivation, persistence-store construction, invalidatable retry gate, and access-leased download/upload executors in one immutable 136-line assembly. It accepts the Core credential already proven by the current session instead of rereading Keychain; after lifecycle ownership is installed, the coordinator clears its temporary reference. The assembly owns no generation, build task, published scheduler, or teardown decision
- 中文：136 行不可变 assembly 复核当前会话刚完成证明的 Core 凭据，并负责匿名本地授权 owner、持久化 store、不可复活 gate 与带 lease 的双向执行器；它不再二次读取 Keychain，生命周期接管后 coordinator 清除临时引用，且 assembly 不持有 generation、build Task、已发布 scheduler 或 teardown 决策
- Keeps the 140-line persistence-location boundary limited to a domain-separated private route plus atomic no-clobber migration from the pre-M1 raw-fingerprint filename; it preserves and rejects collisions, symlinks, and non-regular nodes rather than guessing
- 中文：140 行持久队列位置边界只负责域分离的私有路由与旧原始指纹文件名的原子无覆盖迁移；冲突、符号链接和非普通文件会原样保留并拒绝继续
- Covers invalid selected identity, authenticated-credential fingerprint mismatch, persistence validation before local-authority construction, authenticated-owner transient/persistent modes, and assembly-level legacy restoration with five direct assembly tests; the coordinator behavior regression proves scheduler creation leaves the store's secret-read count at one. Four location tests cover byte/mode-preserving migration plus collision and symlink rejection; the then-current inventory remained 460
- Keeps the retry gate, current scheduler, and generation-bound single-flight build in one 118-line actor-confined lifecycle value; only matching build IDs and object identities may clear published resources, while the coordinator alone validates authentication generation and performs async cleanup
- 中文：118 行 actor-confined 生命周期值原子管理 retry gate、当前 scheduler 与单飞 build；旧 build 只有在 ID 和对象身份仍匹配时才能清理，认证 generation 与异步释放仍由 coordinator 独占
- Detaches one generation's clients, scheduler, tasks, and forward into a value that preserves the audited teardown order without retaining or mutating the coordinator; the same file owns the invalidatable transfer-client gate captured by retry coordinators
- Keeps the coordinator's ten behavior tests in a 359-line narrative file and its connection, credential, pairing, diagnostics, and local-access probes in a 347-line test-support boundary; the split changes only test-target visibility and leaves production access unchanged
- 中文：coordinator 的 10 项行为测试与连接、凭据、配对、诊断和本地授权 probe 分文件维护；拆分只调整测试 target 内部可见性，不扩大生产访问边界
- Resolves an opaque discovery UUID back to a private ADB serial only inside the discovery actor, creates a dynamic forward lease, and removes it exactly once on teardown
- Uses a Hello-only connection solely to select Keychain metadata by the 32-byte device fingerprint; the fingerprint remains untrusted until the fresh authenticated connection proves the stored key
- Runs first pairing on its own fresh session with visible six-digit Mac approval, rejects an identity change between preflight and pairing, and never exposes pairing keys, ports, serials, or raw transport errors to Presentation
- Projects every platform/peer-controlled ADB, pairing, trusted-device, ready-session, diagnostics, and remote-entry label through `ProductDisplayText`; its default 120-scalar limit (240 for remote entries) marks real truncation with an in-bound ellipsis while action identity stays separate. `DevicePairingPresentation` publishes only the safe Android name and six-digit SAS, never Core's device-identity fingerprint
- 中文：平台或对端可控的 ADB、配对、可信设备、ready 会话、诊断与远端条目名称统一经过 `ProductDisplayText`；默认 120 个标量、远端条目 240 个，真实截断会在上限内显示省略号，动作身份保持独立。`DevicePairingPresentation` 只发布安全 Android 名称和六位 SAS，不发布 Core 设备身份指纹
- Builds one device-isolated persistent scheduler only after file-read/resume capabilities are authenticated; every transfer attempt receives a fresh paired client from an invalidatable private gate
- Covers lifecycle generation lookup, guarded publication, stale-build cleanup, and complete detach with four direct state-transition tests; the two coordinator concurrency tests continue to prove single-flight restore and no old-session revival
- Exercises that gate at the real TCP/authentication boundary and deterministically covers rejection before connection plus closure when invalidation races a completed connection; the injected connector remains internal and the product default still opens the lease endpoint with the fixed 10-second timeout
- Serializes disconnect-before-reconnect, cancels pending approval continuations, generation-gates non-cooperative stale results, and tears down in the order gate invalidation → queue settlement → browsing client close → forward release
- Treats post-auth event/browser/scheduler assembly as a transaction: ready-only surfaces publish only after every dependency succeeds, while a current-generation failure registers one awaitable teardown shared with explicit disconnect; replacement connects wait for that teardown, caller cancellation stays silent, and an internal `CancellationError` becomes a stable connection failure only after cleanup
- 中文：认证后的 event/browser/scheduler 组装是全有或全无事务；当前 generation 失败与显式断开复用同一可等待 teardown，新连接先等旧清理完成，调用方取消保持静默，内部 `CancellationError` 则在完整断开后映射为稳定连接失败
- Buffers one terminal liveness event per authenticated session so Presentation cannot miss a failure between ready and observer setup; only the matching generation leaves ready, clears ready-only surfaces, preserves trust/device selection, and waits for explicit reconnect

中文：transfer retry-client gate 现以真实 TCP/配对认证覆盖正常建连，并用无 sleep 的确定性竞态覆盖失效前拒绝和建连完成后关闭，旧队列不能复活到后续会话。

**ProductDeviceDiagnostics / DeviceDiagnosticsModel**
- Fetches device-info and diagnostics concurrently only after the paired session is ready
- Drops Android device ID, raw events/errors, thread names, arbitrary counter keys, and invalid numeric ranges before creating product state
- Exposes three known permissions, coarse service health, recent error count, fixed counters, and bounded device/system metadata; refresh failure keeps the last snapshot explicitly stale
- Uses the authenticated session's safe retail name as the diagnostics primary label while preserving de-duplicated manufacturer/model values as secondary technical context; the pure Presentation policy re-projects every input and cannot change protocol or storage identity
- 中文：诊断概览以认证会话中的安全商品名为主标题，并保留去重后的厂商/原始型号作为次级技术信息；纯 Presentation 策略会重新投影所有输入，且不能改变协议或存储身份
- Reuses one normalization boundary in the schema-v1 exporter, so a separately constructed public snapshot still cannot emit unbounded/control-bearing device text, invalid SDK/storage/battery values, an out-of-range error count, or negative counters

### SwiftUI Product Shell

**DroidMatchApp** (`DroidMatchApp/`)
- Uses a macOS 13 `NavigationSplitView` with localized device, file, media, transfer, and diagnostics sections
- Owns one process-lifetime AppSupport monitor that captures the vnode already mapped for dyld image zero through `proc_pidinfo` and checks its published path every two seconds even with no window. If transactional publication replaces/removes it or changes it to a non-regular node, one callback irreversibly invalidates discovery, trusted-device, and session model entry points, cancels/rejects late publication, enters the existing safe session disconnect, removes every old window hierarchy, and disables the global refresh command. A process-owned window lease set keeps shared discovery alive until the last active window leaves and rejects every future lease after invalidation. A bilingual Quit-and-reopen banner remains; the monitor does not read Keychain or auto-launch another process. One monitor lifecycle/replacement/removal/non-regular test, one multi-window lease test, three direct model-gate tests, and a tested M0 source contract cover the boundary
- Exposes a native Settings scene whose AppStorage-backed media-layout preference is shared with the authenticated file browser
- Replaces the empty system Help Book action with one local, bilingual SwiftUI Help window covering connection, pairing, transfers, recovery, and privacy; the Help source has no URL, session, or Keychain dependency, and a dedicated source contract plus offline negative regressions keep that boundary in the M0 gate
- Keeps optional transfer notifications in an App-owned coordinator; a pure Presentation transition policy suppresses initial history, cancellation, and duplicate terminal snapshots before the App requests macOS delivery
- Reconciles the notification opt-in with live macOS authorization when Settings appears or returns to the foreground. Explicit enable requests stay busy until they resolve, denial keeps the stored preference off with fixed localized guidance, and generation checks prevent an older permission callback from overwriting newer state. A terminal event must first observe the preference enabled; immediately before enqueue, delivery compares that event snapshot with the current MainActor-owned preference generation and live authorization, so an opt-out cannot leave one late notification and an off/on cycle cannot revive an older candidate
- 中文：通知设置页出现或回到前台时会以实时 macOS 授权对账 opt-in；主动开启会保持忙状态直到权限请求结束，拒绝后持久开关保持关闭并显示固定本地化指引，generation 防止旧权限回调覆盖新状态。终态事件必须先观察到开关已开启；实际入队前还会比较该事件快照、MainActor 持有的当前偏好代次与实时授权，因此关闭设置不会遗留一次迟到通知，关后再开也不会复活旧候选
- Activates device selection, secure connection state, visible SAS confirmation, live authenticated file/media navigation, structured device health, native download/upload file panels, and a persistent device-isolated bidirectional queue with progress/actions
- Keeps file-browser search, native panels, mutations, and queue submission in the 682-line parent view; a 93-line pure `DirectoryBrowserSelectionState` owns selection-mode/path invariants, capability-gated select-all, model-row-order projection, visible-row reconciliation, and accepted-only batch subtraction without a model, task, panel, or queue. Three direct tests cover that state. The Media view composes only the section picker, live-access recovery, fresh-only disclosure, upload-only state, and selected session-owned browser. Both surfaces observe the same transfer-admission busy state, revalidate panel completions against it, and disable the whole interactive surface—search, selection, rows/context menus, navigation, and section switching—while another submission is crossing the durable boundary. A delayed search task rechecks busy before loading, and batch reconciliation subtracts only accepted request indices from the current selection rather than clearing unrelated state. Unhealthy/retrying persistence and bulk cleanup also close every row, grid, preview, toolbar, drop, and upload-only transfer entry before a native panel opens; shared chrome shows an in-place recovery action without disabling browsing or remote mutations. Stateless chrome owns the authenticated file/media header, matching empty/error/drop visuals, edit sheets, persistence warning, and bounded submission-failure copy, while the toolbar remains a separate state/actions component and omits unsupported folder creation in MediaStore views. Native panels allow the same 1–100 file batches as Finder drop. Both upload paths cross `ProductUploadSelectionPolicy`, which preserves order while requiring non-symlink regular files, canonical/case/width-unique names, a valid provider destination, and the exact media extension allowlist; AppSupport/Core still own bookmark authority and no-follow source identity. Multi-download preflight rejects normalized duplicate names and existing local targets as one batch, while its subsequent per-item queue submissions distinguish zero accepted, partially accepted, and complete outcomes. Presentation returns only accepted request indices and job IDs, so accepted jobs remain in Transfers while the parent view leaves only unaccepted files selected for retry instead of claiming rollback. Android remains authoritative before MediaStore insertion. List and grid rows show a locked permission hint for unreadable containers and retain a direct upload action only when the same root is independently writable
- `ProductFileBrowserContent` receives one immutable rendering snapshot plus bounded actions and owns no query, selection, panel, model, or queue state. `ProductFileBrowserTransferPolicy` is the AppSupport-owned pure admission boundary for delayed native-panel completions: it requires the exact captured query and row values, rejects duplicate current paths instead of constructing a trapping dictionary, rechecks permission and persistence readiness, and gives single/batch downloads one local-file-URL, existing-target, and canonical/case/width duplicate plan before bookmark or scheduler effects. Five direct tests cover these fail-closed decisions. The current inventory is 490 Swift tests.
- Holds native transfer affordances and transfer-page queue mutations closed until `TransferQueueModel` has completed its first authoritative persistence-status read; the enum's initial `.disabled` placeholder never acts as verified product readiness, and unknown/retrying storage is not rendered as healthy
- Displays the resolved retail name as the primary label and deduplicated raw model/product values as secondary technical context, without serials, raw ADB output, protobuf, or harness text. Accessibility retains each exact safe component so formal insertion evidence can still match a model even when a retail name is present
- Presents Files, Media, Transfers, and Diagnostics without a ready session as current connection/authentication requirements; no inactive surface claims that its already-implemented product wiring is future work
- Hides decorative symbols and named thumbnails/previews across session-required/empty states, headers, banners, summary/diagnostic cards, and file/media rows; device metrics become one value-plus-label accessibility element, selection and sort controls publish localized selected/not-selected values, icon-only row actions have explicit localized labels, and the transfer direction remains a meaningful localized image label
- Shows a stale badge and warning when refresh fails after a successful snapshot
- Reuses the Android mark through a code-generated multi-resolution Mac `.icns`

**Local app/DMG assembler** (`tools/build-mac-app.sh`, `tools/build-mac-icon.sh`, `tools/package-mac-icon.py`, `tools/swift-build-compat.sh`, `tools/build-mac-dmg.sh`, `tools/render-mac-icon.swift`)
- Embeds the full Git source revision, source-dirty boolean, and debug/release configuration before signing; source state is rechecked after assembly and after signing so an attended gate cannot accept a stale clean marker
- Builds the `DroidMatch` SwiftPM product and localized resource bundle
- Gives product builds and Swift tests the same writable module-cache, nested-sandbox, and probe-gated arm64e compatibility decision
- Creates a standard `.app`, renders ten exact RGBA icon sizes, strictly packages modern ICNS chunks with no overwrite, asks the platform decoder to reopen the result, preserves a valid embedded adb vendor signature, signs only a genuinely unsigned custom adb locally, and rejects an invalid existing signature. It then ad-hoc signs the outer App and runs strict deep `codesign` verification. This avoids creating a needless fresh macOS execution-policy identity for official platform-tools without blessing damaged signed bytes. The repository does not depend on the macOS 26.5 `iconutil` encoding path that rejects even a valid extracted iconset
- Builds and verifies the App in a same-filesystem private candidate. First
  publication uses `RENAME_EXCL`; replacement of an existing App uses
  `RENAME_SWAP`, with identity checks before and after each transition recorded
  in a stable `0700` transaction. Its owner marker binds PID, boot session, and
  process start time so a reused live PID cannot pin stale state. The next
  invocation recovers an offline
  `SIGKILL` between swap and state update; active, legacy, inconsistent, or
  unsafe transactions fail closed, and the old App is restored when publication
  cannot complete
- Can package the sandbox App into a compressed DMG with Applications link and checksum, mount it read-only, and revalidate the contained App
- Builds and validates a same-filesystem private candidate before publishing the DMG/checksum; verify, attach, or mounted-bundle failure preserves the previous pair and leaves no candidate behind
- Rolls back a partial pair publication from hard-linked private backups; if publication and rollback both fail, it reports uncertainty and preserves the remaining old bytes instead of deleting the transaction directory
- Initializes the DMG transaction in a private process-instance-scoped sibling:
  PID plus boot/start owner identity, bound marker, and `building` state are
  individually synchronized before the complete
  directory is atomically published at the stable name with `RENAME_EXCL`.
  Dead strictly allowlisted initializers and legacy empty/owner/marker-only
  fragments are recoverable; active, forged, or unknown layouts fail closed
- Keeps the DMG/checksum candidate, previous hard links, owner, and state in that
  stable private transaction. Each absent canonical node publishes with
  `RENAME_EXCL`; each existing node publishes with `RENAME_SWAP`, followed by
  two-way identity checks. Rollback likewise uses no-clobber EXCL or SWAP according
  to the recorded prior state. Recovery binds previous, candidate, and canonical
  nodes before and after each transition by device, inode, size, and SHA-256; a
  concurrent insertion or later replacement is preserved and fails closed.
  Offline tests cover both race classes, all initialization boundaries, an active
  initializer, live-PID/stale-start recovery, a real building-phase hard kill,
  recovery after the DMG replacement,
  recognition of a complete pair, and interrupted first publication. These are
  process-kill recovery tests, not power-loss durability evidence
- Retries `hdiutil verify` at most twice after the exact macOS `Resource temporarily unavailable` condition. Candidate validation covers the complete static tree, resources, signatures, and entitlements while deferring only the private-transaction-path `adb version` launch; immediately after atomic publication, the final path receives the complete verifier before the transaction can be marked complete, with replacement rollback or first-publication withdrawal on failure. Sandbox end-to-end mocks bind both verifier calls and all three adb signature outcomes; hard-kill recovery spans first install, verification, both sides of verified-state persistence, `rollback-required`, the rollback swap, and `rolled-back`. Published and mounted-App checks retry at most twice only for the exact `embedded adb is not runnable` result; all three attempts still validate the full bundle, signature, entitlement, and adb boundary. Malformed images and every other bundle or tool error fail immediately, and checksum publication remains after successful mount validation only
- Remains a developer artifact; Developer ID signing and notarization require a configured release environment

中文：App 会在同文件系统私有事务中完成候选组装/验证；首次发布走 `RENAME_EXCL`，已有 App 替换走带前后身份复核的 `RENAME_SWAP`；owner 会绑定 PID、boot session 与进程启动时刻，PID 复用不会钉死 stale 事务。离线测试覆盖 swap/state 更新之间 `SIGKILL` 后恢复，活动、旧版、不一致或不安全事务会 fail closed。DMG 校验只会对 macOS 明确返回的 `Resource temporarily unavailable` 最多额外重试两次；只读挂载后的完整生产 bundle 检查也仅在 ad-hoc App 精确返回 `embedded adb is not runnable` 时最多额外重试两次，三次均保留 bundle、签名、entitlement 和 adb 的全部检查。坏镜像和其他错误仍立即失败。DMG 事务会先在私有 sibling 写齐并同步 owner PID、boot/start 身份、bound marker 与 `building` state，再以 `RENAME_EXCL` 原子发布稳定目录；死亡且严格 allowlist 的 initializer 与旧版空/仅 owner/marker 无 state 残片可恢复，活动、伪造或未知布局继续 fail closed。DMG 与 SHA-256 随后在该稳定事务中完成镜像、只读挂载、bundle 复核与成对发布：canonical 缺失走 EXCL、已有目标走 SWAP 并双向复核，回滚按原状态走 EXCL/SWAP；恢复以 dev/inode/size/SHA-256 绑定 previous、candidate、canonical 的前后身份，并发插入或后续替换都会保留现场并 fail closed。失败保留上一对产物，若发布与回滚同时失败则保留私有事务中的旧字节。离线脚本测试覆盖初始化边界、活跃 initializer、live PID/stale start 恢复、真实 building hard-kill、两类并发竞态、瞬时恢复、非瞬时立即拒绝、重试耗尽、verify/attach/bundle 失败原子性、checksum 发布回滚与双重失败保留；不声称电源故障耐久性。

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
  "formatVersion": 2,
  "transferID": "UUID",
  "sourcePath": "/tmp/upload.bin",
  "destinationPath": "dm://app-sandbox/file.bin",
  "totalSizeBytes": 104857600,
  "sourceModifiedUnixMillis": 1234567890000,
  "sourceIdentity": {
    "sizeBytes": 104857600,
    "modifiedUnixNanoseconds": 1234567890000000000,
    "changedUnixNanoseconds": 1234567891000000000,
    "fileSystemNumber": 16777234,
    "fileNumber": 424242
  },
  "nextOffsetBytes": 1048576
}
```

New checkpoints are format v2. A v1 record without `formatVersion` or
`sourceIdentity` remains decodable only so offset zero can migrate safely;
non-zero v1 state is never resumed.

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
- Rejects invalid timeout/grace values before process launch and uses saturating `DispatchTime` deadlines for huge finite values
- Used by `AdbClient`

**LockedValue** (`LockedValue.swift`)
- Thread-safe value wrapper using `NSLock`
- Used for concurrent access to mutable state

**Crc32** (`Crc32.swift`)
- CRC32 checksum calculation
- Used to validate transfer chunks

## CLI Harness

**Harness command files** (`DroidMatchHarness/main.swift`, `DroidMatchHarness/HarnessCLI.swift`, `DroidMatchHarness/HarnessHelp.swift`, `DroidMatchHarness/HarnessDirectoryCommands.swift`, `DroidMatchHarness/HarnessTransferCommands.swift`, `DroidMatchHarness/HarnessUploadCommands.swift`)
- `main.swift` owns only command dispatch and ADB/control probes
- `HarnessCLI.swift` owns option parsing and stable user-facing failure descriptions
- `HarnessHelp.swift` owns the help/examples contract checked by device scripts
- `HarnessDirectoryCommands.swift` owns ordinary, aggregate-paginated, and expected-error listing probes; aggregate traversal never prints provider cursors or entry identity
- `HarnessTransferCommands.swift` owns download/error-boundary probes and `HarnessUploadCommands.swift` owns upload/error-boundary probes; both remain Core consumers
- Completed harness transfers report both requested and server-negotiated chunk sizes. The strict `m1-adb-throughput-v2` evidence wrapper uses those fields to reject a run unless both directions requested and negotiated exactly 1 MiB chunks; after each timed transfer it also requires the fixed managed payload, committed download, and committed remote upload SHA-256 digests to match. Its validator binds the generic producer's full source revision, fixed check plan, and overlapping metrics to the specialized record. No archived v1 fixture exists, so only v2 is accepted.
- Commands:
  - `adb-path`: print default adb path
  - `devices`: list adb devices
  - `forward`: create adb forward
  - `framed-echo`: send/receive one raw frame through an async FIFO session
  - `handshake-smoke`: async handshake-only test without product authentication
  - `m1-smoke`: full control-plane smoke test
  - `list-dir`: list directory entries through the async product transport
  - `list-dir-all`: exhaust opaque provider pagination, reject cross-page identity/cursor cycles, and print aggregate counts only
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
bash tools/run-swift-tests.sh --filter 'lockedValueUnlocksAfterThrowingUpdate'
```

The filter form is an iteration aid that retains the repository runner's Swift
Testing fallback. Final verification still uses the unfiltered command.

**Run harness:**
```bash
swift run --package-path mac droidmatch-harness <command> <args>
```

**Regenerate protobuf:**
```bash
brew install protobuf
bash tools/generate-swift-proto.sh
```

With `PROTOC_GEN_SWIFT` unset, this command first runs the hardened bootstrap:
it binds the SwiftProtobuf checkout to the full `Package.resolved` revision,
requires the checkout and lockfile snapshot to remain clean and unchanged, and
atomically installs a single-link executable after inode/hash/mode validation.
An explicit executable override bypasses bootstrap; an explicitly empty value
fails before publication. The generator then writes into a private sibling transaction, requires the exact
non-symlink `v1/*.pb.swift` file set, and synchronizes that candidate before
publication. First publication uses `RENAME_EXCL`; replacement uses
identity-checked `RENAME_SWAP`, so a concurrent insertion or replacement is
preserved and fails closed instead of becoming a nested tree. Recovery accepts
only the recorded pre/post rename mapping, while an unknown transaction or
canonical output layout is preserved for inspection. A failed `protoc` or
plugin run leaves the previous generated tree unchanged. 中文：生成器先在私有
sibling 事务目录中生成，要求精确且无符号链接的 `v1/*.pb.swift` 文件集并同步
候选；首次发布使用 `RENAME_EXCL`，替换使用带身份复核的 `RENAME_SWAP`，并发
插入/替换会被保留并 fail closed，不会形成嵌套目录。恢复只接受已记录的 rename
前后映射，未知事务或 canonical 输出布局一律保留检查；`protoc`/plugin 失败不会
破坏原生成树。未设置 `PROTOC_GEN_SWIFT` 时会先自动执行加固 bootstrap：它把
SwiftProtobuf checkout 绑定到 `Package.resolved` 的完整 revision，要求 checkout
与 lockfile 快照在构建前后保持干净且不变，并在 inode/hash/mode 复核后原子安装
单链接可执行插件；显式 executable override 会绕过 bootstrap，显式空值则在发布前失败。

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
3. Android requires the provider partial to reach that durable ACK; an ahead
   app-sandbox or seekable SAF partial is truncated back before replay
4. If valid, Android accepts chunks from the requested offset
5. A short partial or SAF provider without safe truncate support returns an error

## Current Limitations

- **Two async scopes:** ordinary CLI download/upload commands remain single-transfer; `dual-download-smoke` and `mixed-transfer-smoke` are explicit evidence probes. The product async client supports two mixed-direction handles, both recovery coordinators, a bounded observable persistent queue, and authenticated App download/upload paths. Slot C archives dual/mixed harness behavior plus ordinary and sandbox product authentication and transfer evidence; this does not raise the two-stream limit or complete Slot A throughput.
- **Windowed download:** Android may keep up to 4 chunks or 2 MiB in flight per download stream after the first ACK
- **Windowed upload:** the async path enforces 4 chunks / 2 MiB for both product and harness. `AsyncUploadCoordinator` and the harness share `AsyncUploadFileSender` for serial file reads, continuous refill, optional partial-send limits, and per-ACK checkpoints; SAF rollback requires a seekable writable provider descriptor and otherwise fails with `unsupportedCapability` instead of duplicating bytes.
- **Sandbox recovery boundary:** `DroidMatchAppSupport` owns private bookmark capture, stale refresh, access leases, and orphan pruning alongside the App's per-device manifest and disconnect suspension. Slot C archives sandbox-entitled authentication, browsing, bidirectional transfer, and forced-relaunch upload recovery; `interrupted` recovery UX remains intentionally conservative, and Developer ID signing/notarization remain deferred.

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
4. Add CLI dispatch to `DroidMatchHarness/main.swift`, implementation to the control or transfer command file, and user-facing usage to `HarnessHelp.swift`
5. Update Android `RpcDispatcher` to handle request
6. Add test to `tools/run-m1-device-smoke.sh`

### Extending Multi-Stream Support

1. Start from `AsyncRpcMultiplexer` and `AsyncRpcMultiplexerTests`; keep `AsyncDualDownloadSmokeClient` as the stable device-evidence path
2. Keep a bounded `stream_id` → transfer-state map and reject unknown/crossed IDs
3. Preserve control-plane service while multiple data streams have buffered chunks
4. When changing the mixed-transfer contract, rerun and archive `--mixed-transfer-check`; add per-stream physical-device failure-isolation scenarios before raising the two-stream limit
5. Verify the bookmark-backed transfer path under an App Sandbox entitlement; keep manifest/bookmark ownership, provider path validation, retry policy, protocol parsing, and file checkpoints outside view code

## References

- [Mac README](../mac/README.md): build and run instructions
- [Protocol Documentation](../docs/protocol.md): wire format and semantics
- [M1 Status](../docs/m1-status.md): implementation checklist
- [M1 Testing Guide](../docs/m1-testing-guide.md): test scenarios
- [SwiftProtobuf](https://github.com/apple/swift-protobuf): protobuf Swift library
