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
│   │   ├── AsyncRpcMultiplexer.swift # Single-reader lifecycle + send admission
│   │   ├── AsyncRpcMultiplexerInboundRouting.swift # Actor-isolated inbound routing
│   │   ├── AsyncRpcMultiplexerUploadWindow.swift # Actor-isolated upload-window sequencing
│   │   ├── AsyncRpcTransferFrames.swift # Pure transfer frame construction
│   │   ├── AsyncRpcDeadlines.swift # RPC/open/ACK deadline lifecycle
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
│   │   ├── AsyncTransferSchedulerConsumerState.swift # Actor-confined consumer delivery
│   │   ├── AsyncTransferSchedulerJobRunner.swift # Stateless execution event bridge
│   │   ├── AsyncTransferSchedulerPersistence.swift # Pure manifest conversion
│   │   ├── AsyncTransferSchedulerPersistenceState.swift # Actor-confined store health + I/O
│   │   ├── AsyncTransferSchedulerPolicy.swift # Pure restore/checkpoint policy
│   │   ├── AsyncTransferSchedulerRateExpiryState.swift # Actor-confined rate timers
│   │   ├── AsyncTransferSchedulerSessionEndPolicy.swift # Pure session-end transitions
│   │   ├── AsyncTransferSchedulerTypes.swift # Public queue contract + executor wiring
│   │   ├── TransferQueuePersistence.swift # Versioned atomic queue manifest
│   │   ├── DirectoryListing.swift # Protobuf-free paged listing domain
│   │   ├── AsyncPairingClient.swift # One-shot first-pairing coordinator
│   │   ├── SessionAuthenticator.swift # Canonical auth transcript/HMAC/HKDF
│   │   ├── PairingAuthenticator.swift # P-256/SAS/identity verification
│   │   ├── PairingCredentialStore.swift # Non-sync Keychain records
│   │   ├── HandshakeSmokeClient.swift # ClientHello/ServerHello test
│   │   ├── ProductDeviceSessionContracts.swift # Product session public contract
│   │   ├── ProductDeviceSessionCoordinator.swift # Authenticated session lifecycle
│   │   ├── ProductTransferSchedulerAssembly.swift # Credential/access/executor wiring
│   │   ├── ProductTransferSchedulerLifecycle.swift # Actor-confined scheduler/build state
│   │   ├── ProductDeviceSessionResources.swift # Ordered teardown + transfer gate
│   │   ├── ProductDeviceSessionEvent.swift # Buffered terminal session event
│   │   ├── M1SmokeClient.swift # Async baseline control-plane smoke
│   │   ├── TransferResults.swift # Shared async transfer result values
│   │   ├── RpcControlClientError.swift # Shared RPC validation errors
│   │   ├── AtomicDownloadWriter.swift # Download partial → final commit
│   │   ├── ProcessRunner.swift # Subprocess execution helper
│   │   ├── LockedValue.swift   # Thread-safe value wrapper
│   │   └── Crc32.swift         # CRC32 checksum
│   ├── DroidMatchPresentation/ # MainActor native product-state boundary
│   │   ├── DeviceDiscoveryModel.swift
│   │   ├── DirectoryBrowserPresentationTypes.swift # Stable UI values + safe names
│   │   ├── DirectoryBrowserPolicy.swift # Pure media/mutation/error decisions
│   │   ├── DirectoryBrowserModel.swift # MainActor tasks + published state
│   │   ├── TransferQueueDataSource.swift
│   │   ├── TransferQueuePresentationItem.swift
│   │   └── TransferQueueModel.swift
│   ├── DroidMatchApp/          # Localized SwiftUI product shell
│   │   ├── DroidMatchDesktopApp.swift
│   │   ├── AppShellView.swift
│   │   ├── DeviceDashboardView.swift
│   │   ├── ProductFileBrowserView.swift # Browser state/action composition
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
- Races completion, timeout, and task cancellation through a one-shot result gate, then closes ambiguous sessions instead of reusing them
- Powers every CLI and product RPC/transfer path; the former semaphore transport has been deleted
- Selects either FIFO round-trip or multiplexed mode for the connection lifetime; multiplexed mode keeps one independent reader and serialized writers

**AdbDeviceDiscovery / DeviceDiscoveryModel** (`DeviceDiscovery.swift`, `DroidMatchPresentation/DeviceDiscoveryModel.swift`)
- Runs the bounded blocking `adb devices -l` process on a private serial queue, never MainActor
- Keeps raw ADB serials inside the Core actor and emits process-local opaque UUIDs plus model/product/state only
- Prefers `Contents/Resources/platform-tools/adb` in an assembled product; explicit environment and SDK paths remain development fallbacks
- Normalizes missing/failed/timed-out ADB into stable error categories rather than forwarding process stderr
- Sorts ready devices first, deduplicates malformed repeated serial rows, and keeps one UUID stable only while the device remains visible
- Allows only one preparation per opaque device ID, rejects a device that disappears or loses readiness before forwarding, and removes a newly allocated forward if cancellation wins
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
- The product coordinator sends a 10-second heartbeat on the authenticated control/browser client; terminal heartbeat failure tears down the session-owned gate/scheduler/client/forward before publishing a cached stable invalidation, while transfer attempts still use fresh authenticated clients

**AsyncRpcMultiplexer / frames / deadlines / routing / transfer handles** (`AsyncRpcMultiplexer.swift`, `AsyncRpcMultiplexerInboundRouting.swift`, `AsyncRpcMultiplexerUploadWindow.swift`, `AsyncRpcTransferFrames.swift`, `AsyncRpcDeadlines.swift`, `AsyncRpcTransferControl.swift`, `AsyncRpcRoutingState.swift`, `AsyncTransferHandles.swift`)
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
- Lets protocol cancellation end one upload window while preserving the session; direct Swift Task cancellation after admission closes the ambiguous session
- Keeps an idle reader alive without applying a request timeout; each actual request/open/ACK wait has its own deadline
- Keeps those RPC/open/ACK deadline tasks in a dedicated extension; expiry still terminates through the owning actor, while nanosecond conversion saturates before `Double` to `UInt64` conversion so the largest finite timeout cannot trap at the rounded 2^64 boundary
- Holds real local TCP control/open/ACK requests without replying to prove typed deadline failures close the ambiguous session; both download and upload open directions are covered
- Local TCP E2E interleaves a multi-chunk download, a full four-chunk upload window, and heartbeat, then proves cancel + post-cancel heartbeat reuse
- Keeps the framed test server split by protocol role: the 209-line Control extension owns shared send/handshake/smoke responses, the 181-line Download extension owns resume/ACK/cancel/pause/error responses, and the 356-line Upload extension owns receive/open/chunk/ACK/error handling; all extend the same server type without copying live state
- 中文：本地 framed test server 按 Control、Download、Upload 协议角色拆分；三个 extension 共享同一 server 状态，不复制连接或请求生命周期
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

**AtomicDownloadWriter** (`AtomicDownloadWriter.swift`)
- Pins the authorized destination directory with a descriptor and opens the
  sibling `.droidmatch-part` through `openat(..., O_NOFOLLOW)`
- Requires the opened partial to be a regular file, so resume cannot follow a
  symbolic link to another local file
- On successful completion, synchronizes the partial and uses same-directory
  `renameat` for an atomic commit; an existing destination symlink is replaced
  as a directory entry rather than followed
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
- Keeps the three coordinator behavior tests in a 220-line suite, while one 445-line test-only support boundary owns the recovery TCP server, wire sequencing, and synchronization probes; production visibility and protocol behavior are unchanged
- 中文：三项 coordinator 行为测试保留在 220 行套件中；445 行测试 support 统一持有恢复 TCP 服务器、wire 顺序与同步 probe，生产可见性和协议行为均不变
- Keeps MediaStore fresh-only, rejects resume/retry policy for non-resumable destinations, and retains the last sidecar checkpoint on task cancellation

**AsyncTransferScheduler / consumer state / rate timers / runner / policies / persistence** (`AsyncTransferScheduler.swift`, `AsyncTransferSchedulerConsumerState.swift`, `AsyncTransferSchedulerControlPolicy.swift`, `AsyncTransferSchedulerRateExpiryState.swift`, `AsyncTransferSchedulerJobRunner.swift`, `AsyncTransferSchedulerPersistence.swift`, `AsyncTransferSchedulerPersistenceState.swift`, `AsyncTransferSchedulerPolicy.swift`, `AsyncTransferSchedulerSessionEndPolicy.swift`, `TransferQueuePersistence.swift`)
- Admits download/upload coordinator requests in FIFO order with a default global limit of two running jobs
- Keeps the immutable public job/snapshot contract and coordinator/executor wiring in `AsyncTransferSchedulerTypes.swift`, leaving queue/runtime transitions in the actor implementation
- Separates the 247-line queued/running/backoff pause suite from the 471-line retry/progress/terminal suite; both reuse the 212-line test-support boundary, preserving all 275 Swift tests that existed at the time without changing assertions or production code
- Separates the 128-line queue-store format/permission contract from the 494-line scheduler restoration/fail-closed persistence suite; both reuse a 126-line deterministic persistence fixture boundary without changing test names or behavior
- Runs executor dispatch and serializes synchronous retry callbacks ahead of later progress and terminal events in one stateless runner; its short-lived relay owns no scheduler lifecycle task registry, queue, persistence, or job state
- Keeps sidecar validity, persisted-state mapping, request metadata, and resume-request rewriting in a pure policy namespace with no tasks, waiters, timers, or sockets
- Converts shutdown/suspension records and queue membership in a pure session-end policy that returns explicit actor effects; the scheduler still owns and applies executor cancellation, requests rate-timer cancellation, delivers completion, persists, broadcasts, and waits for unwind
- Converts pause/resume/cancel record and FIFO mutations in a 152-line pure control policy. Its reversible action preserves the exact pre-write record/queue and returns the existing ordered settle/start/rate-expiry/executor effects; the actor applies them only after manifest persistence succeeds. Four direct policy tests cover rollback, retry attempt accounting, stable resume identity/FIFO tail admission, and immediate versus active cancellation order, raising the then-current Swift inventory to 297
- 中文：152 行纯控制策略只修改 pause/resume/cancel 的记录与 FIFO；可回滚 action 保留写盘前状态并返回既有有序副作用，actor 仅在 manifest 写入成功后应用。四项直接测试覆盖回滚、重试 attempt、稳定 resume 身份/FIFO 尾部以及两类取消顺序，使当时的 Swift 测试总数升至 297
- Keeps terminal outcomes, completion waiters, and buffering-newest snapshot observers in one actor-confined consumer-state value that starts no tasks, performs no persistence, and mutates no jobs
- Keeps rate-expiry Task replacement/cancellation in a 49-line actor-confined value; generation validation, runtime-effect application, job ownership, and snapshot publication remain exclusively in the 631-line scheduler actor
- 中文：49 行 actor-confined 值只管理速率过期 Task 的替换/取消；generation 校验、运行时副作用应用、job 所有权和快照发布仍由 631 行 scheduler actor 独占
- Converts manifests to canonical runtime records and back in a separate pure boundary; a 73-line actor-confined persistence state owns store I/O, coarse health, and the reload latch, while the actor applies only a fully canonicalized immutable result
- 中文：73 行 actor-confined persistence state 统一持有 store I/O、粗粒度健康状态和 reload 闩锁；scheduler actor 只应用完成 canonical write 后的不可变恢复结果
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
- Supports a persistent execution latch for product restoration; every scheduler path that could admit work honors it, while a private local-endpoint projection lets AppSupport validate non-terminal authorization without exposing those paths to Presentation or logs
- On startup load/validation/canonical-write failure, publishes an empty `writeFailed` queue without starting executors or overwriting the archive; explicit retry reloads repaired durable state before publishing or admitting work
- Treats product session suspension as idempotent irreversible invalidation: internal executor unwind may finish its one conservative manifest write, but repeated suspension/shutdown are no-ops and stale callers cannot pause, resume, cancel, remove, retry persistence, reactivate execution, or prune from an authoritative endpoint projection
- Shares a package-scoped private atomic writer with AppSupport bookmarks so recovery data is created at 0600, synchronized, and only then atomically replaces its destination
- Restores active download/app-sandbox/SAF work only with a matching valid sidecar; corrupt/missing checkpoints and MediaStore active uploads become persistent, non-resumable `interrupted` rows rather than silent replays

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
- Preserves scheduler order and forwards pause/resume/cancel/remove without optimistic row mutation
- Publishes combined bookmark-registry/manifest `disabled`/`healthy`/`writeFailed` health without exposing filesystem paths or raw I/O errors, reloads authoritative health after submissions or queue mutations whose bookmark work may happen outside a scheduler snapshot, and requires current-owner or explicit legacy coverage for every non-terminal local endpoint
- Keeps a corrupt, empty, or incomplete startup bookmark archive from activating restored work; Retry reloads bookmarks, reloads the manifest with execution still latched, validates the newly authoritative targets, reconciles authority, and only then activates. Resume uses the same consistency gate and is disabled in the UI during `writeFailed`
- Maps Core paths into a local basename plus an optional scheme-checked `dm://` path; invalid remote values and raw failure descriptions are omitted because either may contain POSIX paths
- Submits only scheme-checked `dm://` downloads to a local file URL; the authenticated App session now starts/stops its observation and uses scheduler-authoritative state rather than synthetic rows

**DirectoryListing / DirectoryBrowserPolicy / DirectoryBrowserModel** (`DirectoryListing.swift`, `DroidMatchPresentation/DirectoryBrowser*.swift`)
- Sends the complete path/page-size/sort/direction query while returning Android's opaque token unchanged; Presentation never imports generated protobuf types
- Maps embedded provider errors into stable categories without retaining message/details, and validates logical row identity, supported kind, page-local uniqueness, and immediate token repetition
- Mirrors browser ownership in tests: eight pagination/navigation/lifecycle cases live in a 258-line suite, nine mutation/media/presentation cases live in a 243-line suite, and one 157-line test-only support boundary owns their shared actor probe and fixtures
- 中文：浏览测试按职责拆为 258 行的八项分页/导航/生命周期证据、243 行的九项 mutation/media/展示证据；共享 actor probe 与 fixture 只由一个 157 行测试 support 边界持有
- Represents provider-unknown size/time as nil, including virtual roots and SAF/provider metadata gaps
- Keeps stable phase/failure/item values and UI-only bidi/control-safe display names in an 87-line declaration boundary; the raw name and canonical identity remain unchanged for explicit operations
- Keeps direct-child name/path validation, loaded-item mutation admission, stable batch ordering, media thumbnail/preview eligibility, and Core-to-UI error mapping in a 150-line pure policy that owns no client, task, generation, token, cache, or published state
- Serializes load/refresh/load-more on MainActor, rejects stale non-cooperative responses by generation, atomically replaces a successful refresh, and retains rows/token after a failed next page so the user can retry
- Filters duplicate logical paths across offset-backed page boundaries and stops a cross-page token cycle before appending its suspect page
- Leaves the 573-line model as the only owner of browser clients, tasks, generation, navigation, pagination, media cache, mutations, and published state; the authenticated SwiftUI file page consumes only this boundary
- Exercises create/rename/delete plus item/album thumbnail RPCs through the real async client and a local TCP server, including capability gates, bounded embedded errors, malformed responses, pre-wire path validation, and post-error session reuse
- Rejects bare `dm://` mutation endpoints and media thumbnail paths without a non-negative decimal signed 64-bit item ID before allocating a request ID or writing to the socket

中文：浏览 mutation 与缩略图现有真实本地 TCP/RPC 边界测试；能力不足、provider 失败或畸形响应不会污染后续会话，裸 `dm://` 与非法 MediaStore item ID 会在发包前被拒绝。

**ProductDeviceSessionContracts / ProductDeviceSessionCoordinator / ProductTransferPersistenceLocation / ProductTransferSchedulerAssembly / ProductTransferSchedulerLifecycle / ProductDeviceSessionResources / DeviceSessionModel**
- Keeps product-facing values, coordinator/client protocols, and concrete client conformances in a declaration-only contract file; the actor remains the sole owner of session lifecycle state
- Keeps exact fingerprint-bound credential reload, opaque local-access owner derivation, persistence-store construction, invalidatable retry gate, and access-leased download/upload executors in one immutable 136-line assembly; it owns no generation, build task, published scheduler, or teardown decision
- 中文：136 行不可变 assembly 负责精确指纹凭据重载、匿名本地授权 owner、持久化 store、不可复活 gate 与带 lease 的双向执行器；不持有 generation、build Task、已发布 scheduler 或 teardown 决策
- Keeps the 140-line persistence-location boundary limited to a domain-separated private route plus atomic no-clobber migration from the pre-M1 raw-fingerprint filename; it preserves and rejects collisions, symlinks, and non-regular nodes rather than guessing
- 中文：140 行持久队列位置边界只负责域分离的私有路由与旧原始指纹文件名的原子无覆盖迁移；冲突、符号链接和非普通文件会原样保留并拒绝继续
- Covers missing credentials, post-list fingerprint drift, persistence validation before local-authority construction, authenticated-owner transient/persistent modes, and assembly-level legacy restoration with five direct assembly tests; four location tests cover byte/mode-preserving migration plus collision and symlink rejection, raising the current Swift inventory to 310
- Keeps the retry gate, current scheduler, and generation-bound single-flight build in one 118-line actor-confined lifecycle value; only matching build IDs and object identities may clear published resources, while the coordinator alone validates authentication generation and performs async cleanup
- 中文：118 行 actor-confined 生命周期值原子管理 retry gate、当前 scheduler 与单飞 build；旧 build 只有在 ID 和对象身份仍匹配时才能清理，认证 generation 与异步释放仍由 coordinator 独占
- Detaches one generation's clients, scheduler, tasks, and forward into a value that preserves the audited teardown order without retaining or mutating the coordinator; the same file owns the invalidatable transfer-client gate captured by retry coordinators
- Keeps the coordinator's ten behavior tests in a 359-line narrative file and its connection, credential, pairing, diagnostics, and local-access probes in a 347-line test-support boundary; the split changes only test-target visibility and leaves production access unchanged
- 中文：coordinator 的 10 项行为测试与连接、凭据、配对、诊断和本地授权 probe 分文件维护；拆分只调整测试 target 内部可见性，不扩大生产访问边界
- Resolves an opaque discovery UUID back to a private ADB serial only inside the discovery actor, creates a dynamic forward lease, and removes it exactly once on teardown
- Uses a Hello-only connection solely to select Keychain metadata by the 32-byte device fingerprint; the fingerprint remains untrusted until the fresh authenticated connection proves the stored key
- Runs first pairing on its own fresh session with visible six-digit Mac approval, rejects an identity change between preflight and pairing, and never exposes pairing keys, ports, serials, or raw transport errors to Presentation
- Builds one device-isolated persistent scheduler only after file-read/resume capabilities are authenticated; every transfer attempt receives a fresh paired client from an invalidatable private gate
- Covers lifecycle generation lookup, guarded publication, stale-build cleanup, and complete detach with four direct state-transition tests; the two coordinator concurrency tests continue to prove single-flight restore and no old-session revival
- Exercises that gate at the real TCP/authentication boundary and deterministically covers rejection before connection plus closure when invalidation races a completed connection; the injected connector remains internal and the product default still opens the lease endpoint with the fixed 10-second timeout
- Serializes disconnect-before-reconnect, cancels pending approval continuations, generation-gates non-cooperative stale results, and tears down in the order gate invalidation → queue settlement → browsing client close → forward release
- Buffers one terminal liveness event per authenticated session so Presentation cannot miss a failure between ready and observer setup; only the matching generation leaves ready, clears ready-only surfaces, preserves trust/device selection, and waits for explicit reconnect

中文：transfer retry-client gate 现以真实 TCP/配对认证覆盖正常建连，并用无 sleep 的确定性竞态覆盖失效前拒绝和建连完成后关闭，旧队列不能复活到后续会话。

**ProductDeviceDiagnostics / DeviceDiagnosticsModel**
- Fetches device-info and diagnostics concurrently only after the paired session is ready
- Drops Android device ID, raw events/errors, thread names, arbitrary counter keys, and invalid numeric ranges before creating product state
- Exposes three known permissions, coarse service health, recent error count, fixed counters, and bounded device/system metadata; refresh failure keeps the last snapshot explicitly stale

### SwiftUI Product Shell

**DroidMatchApp** (`DroidMatchApp/`)
- Uses a macOS 13 `NavigationSplitView` with localized device, file, transfer, and diagnostics sections
- Exposes a native Settings scene whose AppStorage-backed media-layout preference is shared with the authenticated file browser
- Keeps optional transfer notifications in an App-owned coordinator; a pure Presentation transition policy suppresses initial history, cancellation, and duplicate terminal snapshots before the App requests macOS delivery
- Activates device selection, secure connection state, visible SAS confirmation, live authenticated directory navigation, structured device health, native download/upload file panels, and a persistent device-isolated bidirectional queue with progress/actions
- Keeps file-browser search, selection, native panels, and queue submission in the 582-line parent view; the 190-line chrome component owns only the authenticated header, empty/error/drop visuals, edit sheets, and bounded submission-failure copy, while the toolbar remains a separate stateless state/actions component
- Displays model/product labels and coarse readiness without serials, raw ADB output, protobuf, or harness text
- Shows a stale badge and warning when refresh fails after a successful snapshot
- Reuses the Android mark through a code-generated multi-resolution Mac `.icns`

**Local app/DMG assembler** (`tools/build-mac-app.sh`, `tools/build-mac-dmg.sh`, `tools/render-mac-icon.swift`)
- Embeds the full Git source revision, source-dirty boolean, and debug/release configuration before signing; source state is rechecked after assembly and after signing so an attended gate cannot accept a stale clean marker
- Builds the `DroidMatch` SwiftPM product and localized resource bundle
- Creates a standard `.app`, renders all icon sizes, applies an ad-hoc signature, and runs strict `codesign` verification
- Can package the sandbox App into a compressed DMG with Applications link and checksum, mount it read-only, and revalidate the contained App
- Remains a developer artifact; Developer ID signing and notarization require a configured release environment

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

**Harness command files** (`DroidMatchHarness/main.swift`, `DroidMatchHarness/HarnessCLI.swift`, `DroidMatchHarness/HarnessHelp.swift`, `DroidMatchHarness/HarnessDirectoryCommands.swift`, `DroidMatchHarness/HarnessTransferCommands.swift`, `DroidMatchHarness/HarnessUploadCommands.swift`)
- `main.swift` owns only command dispatch and ADB/control probes
- `HarnessCLI.swift` owns option parsing and stable user-facing failure descriptions
- `HarnessHelp.swift` owns the help/examples contract checked by device scripts
- `HarnessDirectoryCommands.swift` owns ordinary, aggregate-paginated, and expected-error listing probes; aggregate traversal never prints provider cursors or entry identity
- `HarnessTransferCommands.swift` owns download/error-boundary probes and `HarnessUploadCommands.swift` owns upload/error-boundary probes; both remain Core consumers
- Completed harness transfers report both requested and server-negotiated chunk sizes. The strict `m1-adb-throughput-v2` evidence wrapper uses those fields to reject a run unless both directions requested and negotiated exactly 1 MiB chunks; after each timed transfer it also requires the managed payload, committed download, and committed remote upload SHA-256 digests to match. The log validator retains v1 compatibility, while the current runner emits only v2.
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
