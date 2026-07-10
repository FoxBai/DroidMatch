# Decision Log

## 2026-06-26

| Decision | Rationale |
|---|---|
| Project name is DroidMatch | Establish a new identity independent from HandShaker and Smartisan. |
| Build a modern replacement, not a clone | Preserve valuable workflows while avoiding old brand, UI assets, and binary implementation. |
| Use a new monorepo at `/Users/baizhiming/Documents/DroidMatch` | Keep the new product separate from the existing binary-maintenance repository. |
| Main route is Mac + Android dual-end rewrite | Control protocol, permissions, diagnostics, transfer recovery, and AOA/ADB behavior. |
| ADB is the stable v1 path | It is the fastest reliable route for M1 and early v1.0. |
| AOA is a PoC-gated consumer path | It can reduce USB debugging friction, but it does not solve Android permissions by itself. |
| Old HandShaker Android compatibility is a timeboxed research line | It may reduce migration cost, but must not block the new product architecture. |
| Protobuf is the protocol schema; gRPC is not mandatory | AOA bulk transport benefits from lightweight framing. |
| v1.0 scope is intentionally narrow | Connection, files, basic media, transfer recovery, diagnostics, and distribution come first. |

## 2026-06-27

| Decision | Rationale |
|---|---|
| HandShaker relationship is workflow-level replacement only | DroidMatch can learn from user-visible workflows, but must not reuse old brand, assets, code, binaries, signing material, or UI implementation. See `docs/handshaker-relationship.md`. |
| Minimum macOS version is macOS 13 Ventura | Keeps the first native Mac implementation modern while avoiding unnecessary macOS 14+ lock-in. |
| Minimum Android API is API 26, Android 8.0 | Keeps the Android service broad enough for older devices while using a modern foreground-service and provider baseline. |
| Android 11+ scoped storage is the primary permission model | v1.0 must degrade around current Android storage rules instead of assuming broad filesystem access. |
| M1 protocol uses a lightweight `RpcEnvelope` instead of gRPC | Keeps ADB and AOA harnesses aligned while leaving room for lower-overhead AOA framing later. |
| File get/put use unified `OpenTransfer` semantics | One transfer state machine covers download, upload, pause, cancel, retry, and resume. |
| API 26-29 uses the same SAF/MediaStore-first storage model | Avoids a second primary file model while still allowing gated legacy optimizations outside the default Play path. |
| M1 real-device matrix gates product UI work | The first implementation phase should prove ADB, AOA, permissions, reconnect, transfer resume, and diagnostics on physical devices. |
| Protocol paths are logical DroidMatch provider paths | Keeps Mac code independent from Android SAF URIs, vendor filesystem paths, and provider implementation details. |
| M1 transfer resume uses optional source fingerprints | Allows resume validation without requiring expensive full-file hashing for every transfer. |
| M1 starts with explicit local trust boundaries | ADB forward, AOA, Android permissions, and support bundles need security rules before product UI work. |

## 2026-06-29

| Decision | Rationale |
|---|---|
| M1 Mac harness starts as a SwiftPM package | Gives a fast command-line validation loop before product UI or Xcode project complexity. |
| M1 Android skeleton starts in Java with `javac` + `android.jar` validation | Keeps the first service skeleton dependency-light until Gradle, Kotlin, and generated protobuf wiring are needed. |
| M1 Mac socket I/O should use Network.framework before considering SwiftNIO | macOS 13+ provides native async networking and avoids adding a large dependency before transport measurements justify it. |
| M1 frame reader uses cursor-based buffering | Avoids repeated buffer compaction on streaming frame reads while keeping the first harness small. |
| Android 14 selected visual media access counts as granted media access for M1 diagnostics | Keeps the four-state permission model stable while provider roots and capabilities still expose the narrower accessible surface. |

## 2026-06-30

| Decision | Rationale |
|---|---|
| M1 protobuf wire may add fields until the M1 device matrix is accepted | New fields must use fresh field numbers and remain backward compatible; after M1 acceptance, wire changes require an explicit protocol-version decision. |
| Android device identity avoids raw serials | `DeviceInfoResponse.device_id` is derived from non-secret build fields during M1 and must not use `Build.SERIAL`, IMEI, or Android ID without a separate privacy decision. |
| Project license is MPL-2.0 | Keeps the project under file-level copyleft while preserving clear boundaries for app packaging, generated code, and larger-work integration. |
| M1 root listing starts at `dm://roots/` | Gives the harness a protocol-valid directory listing smoke path before real MediaStore and SAF providers are wired. |
| M1 MediaStore roots are flat logical item lists | `dm://media-images/` and `dm://media-videos/` expose listed media items as stable `media/<id>` paths, while fresh upload appends a display-name segment to the root. Bucket hierarchy and SAF roots can be layered on without leaking platform URIs. |
| M1 SAF roots use persisted tree permissions and logical paths | Android stores user-selected tree URI permissions, while Mac sees only `dm://saf-.../` paths with opaque Android-local document tokens. |
| M1 transfer starts with a single download chunk smoke | The first transfer implementation validates `OpenTransferResponse` + one `TransferChunk` + final ACK over the same ADB session before adding scheduler, resume, upload, pause, and cancel complexity. |
| M1 ADB download uses receiver-paced chunks first | The Mac harness ACKs each chunk before Android reads and sends the next one, proving multi-chunk correctness without introducing multi-stream scheduling before the real-device matrix. |
| M1 ADB download may fill a small per-stream window | Once basic receiver-paced correctness was proven, Android can keep up to 4 chunks or 2 MiB in flight on a single download stream. This preserves ACK backpressure while removing the per-chunk round-trip bottleneck seen on Slot D. |
| M1 resume starts with sidecar fingerprint validation | The Mac harness stores Android's accepted source fingerprint next to the partial file and sends it with non-zero offset requests, letting Android reject stale resumes before transfer scheduling is added. |
| SAF upload resume uses transfer-id partial documents | Android writes SAF uploads to hidden partial documents derived from `OpenTransferRequest.transfer_id`, then validates partial length on resume and renames to the requested display name only after the final chunk. |
| M1 transport-loss retry starts as a sidecar-backed harness retry | The first reconnect slice retries once after transport close/timeout only when download or app-sandbox/SAF upload metadata is already durable, leaving full scheduler reconciliation for the later recovery queue. |
| M1 fault injection uses a local frame proxy before cable unplug automation | Dropping the first proxied transfer connection proves protocol/session retry on real Android data while keeping ADB visibility, service restart, and physical USB churn as separate matrix cases. |
| App-sandbox upload resume may truncate duplicate partial bytes | If Android wrote a chunk but Mac missed the ACK, the next app-sandbox resume should roll back to Mac's requested offset and replay rather than fail on a longer partial file. |

## 2026-07-10

| Decision | Rationale |
|---|---|
| Product-facing Mac transport starts as a separate `AsyncFramedTcpSession` actor while the M1 CLI keeps its synchronous session | Preserves the verified harness behavior while preventing future SwiftUI/MainActor code from blocking a cooperative thread. |
| Async session operations use an explicit cancellation-aware FIFO lease | Swift actors are re-entrant across `await`; actor isolation alone does not prevent two request/response exchanges from interleaving on one TCP connection. |
| M1 multi-stream proof uses a bounded two-download router before changing product async RPC | The dedicated smoke client can prove stream-ID routing, fair chunk service, Android's two-active-transfer cap, and heartbeat responsiveness without destabilizing verified single-transfer commands or prematurely defining UI cancellation semantics. |
| Active transfer IDs are session-unique and pause returns only an ACKed boundary | Transfer-level controls address `transfer_id`, so duplicates are ambiguous; similarly, bytes sent into a window are not safe to skip on resume until the receiver acknowledges them. |
| Product async RPC uses one lifetime-selected multiplexed mode and one reader | A single reader can safely route concurrent control, download, and upload frames by IDs; allowing round-trip code or a second reader on the same TCP byte stream would reintroduce response theft and actor re-entrancy races. |
| Product async upload windows are preflighted and submitted by one handle operation | A deterministic 4 chunk / 2 MiB batch avoids relying on sibling Swift task scheduling, prevents an invalid suffix from leaving a valid prefix on the wire, and reuses the verified `UploadWindow` ACK-order rules. |
| Mixed-direction device evidence uses an isolated product-async smoke session | Ordinary CLI transfers remain stable single-transfer flows. `mixed-transfer-smoke` opens download and upload handles, requires heartbeat while neither transfer can yet finish, then concurrently runs atomic receive and the shared windowed file sender; the session closes after the proof. The device script requires a distinct fresh upload target, compares reported/local byte counts, and records no Mac path or personal upload file name on the wire. |
| Upload wire metadata and normal success output never expose Mac local paths | Android authorizes upload by logical `destination_path`; inactive-side `source_path` is diagnostic only. Product and harness clients send `mac-local-upload`, while Mac-only sidecars retain the real POSIX path for source identity checks. Success lines use local-artifact placeholders so direct harness and CI stdout are safe even without the device script's second redaction pass. |
| Product async download handles own atomic file receive while schedulers own sidecars | Chunk/write/ACK order and destination commit are transfer invariants, so UI code must not reproduce them. Sidecar/retry decisions span sessions and remain scheduler policy. Rechecking partial length after open detects filesystem races before accepting bytes. |
| Product download recovery injects an authenticated-client factory and keeps the legacy camelCase sidecar schema | A transfer scheduler should own checkpoint/retry policy without also owning ADB/pairing setup. Injecting a fresh client per attempt preserves that boundary, while shared Core records let CLI-created checkpoints remain readable without migration. |
| Product upload checkpoints advance per ordered ACK, while source reads validate inode and nanosecond mtime | A sent window may be only partially durable when transport drops. Persisting every ACK gives the safest replay boundary, and validating identity around serial reads prevents one transfer from silently combining bytes across a replaced or rapidly modified local file. |
| Product transfer scheduling defaults to a process-local FIFO actor capped at two running jobs, with explicit opt-in persistence | Coordinator correctness stays independent of UI lifetimes. The buffering-newest snapshot stream, receiver-confirmed progress, monotonic throughput, pause/cancel, and terminal rules remain scheduler-owned. An app-owned, versioned atomic manifest can preserve stable UUID/FIFO intent across reconstruction, but executor admission is allowed only after the active transition is written. Active jobs without a matching resumable sidecar—including MediaStore uploads—become persistent `interrupted` rows instead of being replayed. Corrupt manifests are preserved for product-level recovery decisions, and coarse persistence health reaches presentation without leaking local paths. |
| Product directory browsing consumes provider-owned pagination through a protobuf-free domain boundary | Android tokens remain opaque and bound to the exact query; Mac sends them back unchanged rather than decoding offsets. Core maps provider errors and validates row/token identity, while MainActor owns one request at a time, atomic refresh, retryable load-more, cross-page deduplication, and generation-based stale-response rejection. Unknown provider metadata becomes optional instead of rejecting virtual/SAF rows. Device names are view data but never failure/log data. |
| Android provider transfer-I/O state machines live outside the provider facade | `DmFileProvider` should remain the logical-path, permission, and catalog router. Package-private download readers own seekable/sequential offset positioning, bounded reads, EOF, and teardown. Provider writers own ordered chunk boundaries plus app-sandbox atomic replacement, SAF temporary-document rename/cleanup, and MediaStore pending-row publication/cleanup. Neither parses RPC or authorizes paths; both ceilings move only downward as the provider monolith is decomposed. |
| The app-sandbox catalog owns canonical local filesystem behavior outside the provider facade | The facade selects the `dm://app-sandbox/` root and passes only a relative path. `AndroidAppSandboxCatalog` canonicalizes beneath the app-owned root, rejects traversal, hides resumable partials, and owns listing/sort/page plus reader/writer creation. Shared opaque-ID hashing prevents provider etags and future logical IDs from exposing local paths. |
| The MediaStore catalog owns live permission checks and platform row lifecycle outside the provider facade | The facade selects an image/video logical root and validates its logical target shape. `AndroidMediaCatalog` re-checks media read permission per list/open, owns query sorting/pagination and seekable/stream fallback, and creates fresh-only pending rows. Extracted writers publish or delete those rows; non-zero upload offsets remain explicitly unsupported. |
| The SAF catalog owns persisted tree/document operations but not logical-token exposure | `AndroidSafCatalog` enumerates persisted permissions, performs document queries, validates metadata, and owns transfer-ID partial create/reopen/rename/delete behavior. `DmFileProvider` retains the bounded process-local mapping from opaque `dm://saf-.../doc/<token>` identities to raw document IDs, so platform identifiers never cross the wire. |
| Native transfer queue state lives in a separate MainActor presentation target | Core snapshots retain exact paths for transfer ownership and raw errors for diagnostics, while views need ordered, privacy-bounded values and action affordances. `TransferQueueModel` strips local paths to basenames, omits raw error descriptions, keeps scheduler updates authoritative, and uses explicit idempotent observation so UI lifetime never changes transfer lifetime. A cancelled job becomes removable only after its executor has actually unwound. |
| Product pause is a checkpointed coordinator close/reopen policy, not a symmetric wire claim | Android M1 `PauseTransferRequest` currently stops only an active download reader. The product scheduler can still offer safe pause for downloads and resume-capable app-sandbox/SAF uploads once an incomplete durable checkpoint exists: cancel the job's exclusive coordinator session, retain partial/sidecar state, and requeue the same job/transfer identity with `resume = true`. MediaStore stays fresh-only, and completion waiters span the pause. |
| Blocking download file I/O uses one private serial Dispatch queue | Wrapping `FileHandle` in a detached Swift task would still obscure ownership and could consume cooperative executor threads. A dedicated queue keeps the writer single-owner and lets multiplexed control/other transfer actors continue. |
| Timeout, direct task cancellation, or ambiguous I/O closes the async session | Once a frame outcome is uncertain, reusing the byte stream could associate a late response with the wrong request. Explicit protocol cancellation is different: after the remote confirms it, pending transfer waiters may stop while the session remains reusable. |
| Synchronous and async Mac RPC clients share one pure envelope codec | Frame-version, optional payload-CRC, request-correlation, error, kind, and payload-type rules must not drift during the incremental migration. |
| Product control RPC requires a successful cached handshake state | Prevents business requests before capability negotiation and avoids duplicate ClientHello frames when multiple UI consumers ask for connection state. |
| M1 enforces nonce freshness/correlation but does not call it identity authentication | A random ClientHello value echoed by Android detects stale or mismatched responses, but any localhost process can generate its own challenge without a paired secret. |
| Product authentication requires an explicit pairing credential or pinned key | Destructive capabilities need a proof over fresh nonces backed by Keychain/Keystore state (or a mutually authenticated encrypted channel), including revocation and re-pairing. |
| First pairing uses ephemeral P-256 ECDH plus a user-compared six-digit SAS | P-256 is available through macOS CryptoKit and Android API 26 platform providers; transcript confirmation detects an active substitution without a cloud account or pre-shared password. |
| First pairing has an explicit final-confirmation round | Android commits only after Mac proves receipt of the server confirmation; Mac writes provisionally before finalize and rolls back on rejection, avoiding one-sided pairing after a lost response. |
| Pairing SAS uses rejection sampling | Reducing an arbitrary 32-bit value modulo one million introduces a small bias; rejecting values above 4,294,000,000 keeps every six-digit code equally likely. |
| Android signs the first-pairing transcript with a stable Keystore P-256 identity | The user-approved SAS authorizes first contact; thereafter the stored public-key fingerprint gives the pairing record a stable device identity without using Android ID, IMEI, or raw serials. |
| Authentication backoff is process-local with per-ID and global buckets | Per-ID exponential delay protects a credential while a global bucket stops random-ID rotation; bounded, idle-expiring memory avoids turning attacker traffic into durable lockout state. |
| Reconnection authentication is a second challenge-response step after ServerHello | Client and server HMAC proofs cover both fresh nonces with role separation, preventing replay that a ClientHello-only proof cannot prevent. |
