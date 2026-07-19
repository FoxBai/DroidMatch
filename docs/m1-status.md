# M1 Status Summary

Last updated: 2026-07-19

## Current Implementation Status

### ✅ Completed Features

**Mac Side:**
- ADB client (discovery, forward, device listing)
- Frame codec (4 MiB max, length-prefixed)
- Framed TCP client/session (Network.framework)
- Handshake smoke client (ClientHello/ServerHello)
- M1 smoke client (full control-plane test)
- RPC control client (request/response handling)
- Product-facing async TCP/RPC actors with lifetime-selected I/O mode, one multiplexed reader, request deadlines, and admission-aware cancellation: admitted mutation/transfer-control cancellation is session-fatal, while admitted read-only heartbeat/device-info/listing/diagnostics/thumbnail cancellation retains and validates/drains the pending response under its original deadline
- SwiftUI `DroidMatch` product target with English/Chinese device dashboard, independent Media sidebar, canonical-path localization for built-in provider roots, readable navigation titles instead of opaque paths, async ADB discovery, process-local opaque device IDs, stale-snapshot disclosure, generated native icon, and a verified ad-hoc local `.app` bundle. Files hides the Images, Image Albums, and Videos roots; Media is the sole product media entry, where Images, Albums, and Videos retain separate browser state while reusing the authenticated paging/search/sort/grid/preview/transfer surface. The native Help menu now opens a local bilingual SwiftUI guide instead of the system's missing-Help-Book alert; its checked source has no network URL, device-session, or Keychain dependency. A nonce-only debug endpoint is surfaced as `secureEndpointRequired` with an actionable Secure USB instruction rather than a generic transport failure.
- Product session lifecycle with anonymous dynamic forward leases, stable-identity Keychain selection, visible SAS approval, paired reconnect proof, authenticated paginated file and media browsing, and privacy-bounded structured diagnostics with schema-v1 allowlisted JSON export including bounded product/macOS versions and snapshot freshness. Keeping media roots out of Files makes the Media surface's live capability check authoritative for every product media entry. Media root metadata is refreshed from live Android capabilities; a root already marked unreadable is not listed, and explicit access recheck clears/reloads every loaded media query even if Android 14 selected-media scope changes while the root remains readable. Permission failure blocks only its stable section without automatic catalog/list loops. Independent write capability still permits direct upload, with exact filename-type validation on Mac and Android plus pre-upload fresh-only UI disclosure. Trusted-device display metadata uses a non-interactive `LAContext`, bounds its busy UI to five seconds, suppresses duplicate work while Security.framework remains blocked, and still applies a late successful Keychain result. Its unavailable surface distinguishes a still-outstanding system request from a retryable failure: while pending it explains that this passive check will not open authentication UI and suggests reopening DroidMatch, and it exposes Try Again only after the prior request has actually retired. The explicit-connection card and credential-free local Help explain that a possible macOS Keychain prompt authorizes access to the saved device-pairing key rather than requesting Apple signing material, and that DroidMatch itself has no password field; a credential-read failure first offers system-dialog retry guidance before destructive re-pairing. Locally tested heartbeat transport failure and echo mismatch tear down the current gate/scheduler/client/forward before a buffered stable event removes all ready-only UI; explicit disconnect remains failure-free and paired trust is retained.
- External-name presentation hardening now uses one bounded Mac projection for ADB model/product, pairing, trusted-device, ready-session, diagnostics, and remote-entry labels, while Android applies its equivalent projection to peer names and SAF grant rows/confirmation. Mac defaults to 120 Unicode scalars (240 for remote entries), Android uses 120 code points, and both reserve an in-bound ellipsis for real visible truncation. Action identity remains an opaque device ID, pairing record, logical path, or stable SAF root. The Mac Published pairing decision contains only a safe Android label and six-digit SAS; Core's identity fingerprint is not Presentation state.
- Mac discovery now enriches device cards with a display-only retail name while retaining raw model/product as secondary technical context. Concrete aliases are not model-specific Swift logic: they live in one versioned, 128 KiB/128-record-bounded JSON resource sealed into the App. Its generic loader requires the exact schema and rejects the whole table if any normalized identity, display string, locale tag, or credential-free HTTPS source is invalid. An assembled App reads only that signed main-bundle resource and fails closed if it is missing or damaged; only SwiftPM tests and command-line products may use the module bundle, so the generated build-machine absolute fallback never enters the product path. The resulting source-auditable local alias catalog follows Mac preferred languages through exact-tag/region/script/base-language fallback, requires exact device identity, rejects duplicate matches, and persists only canonical names. SHARP 704SH resolves offline to Sharp's sole reviewed Japanese `シンプルスマホ4`; Chinese and English safely retain that name rather than receiving an invented translation. Another cache miss schedules an ephemeral no-cookie/no-redirect streamed request to Google's one exact public full-device catalog URL. A dedicated catalog-loader actor enforces 8 MiB/UTF-16LE/header/row/field limits and builds a bounded index, while the resolver actor caps pending tuples at 64. Matching/cache identity uses complete accepted 512-scalar identifiers, not the 120-scalar UI projection, and only an unambiguous raw name is projected. No serial or per-device search term leaves Core; at most 512 safe canonical names persist under SHA-256 tuple keys. Google-derived names now carry source plus bounded verification time in cache v3: a fresh entry is fully offline, while only an expired, previously verified v3 value is returned immediately and revalidated against the same complete catalog in the background. A source-unknown v2 entry migrates as unverified and stays hidden until a current reviewed alias or complete catalog validates it; malformed v3 entries are scrubbed during resolver initialization. The in-memory catalog carries its original verification time, so a later query cannot mint false freshness from an old download. A valid refresh updates renamed matches and removes missing/ambiguous ones; failure retains only a previously verified stale safe value under the existing throttle. Current reviewed aliases always win, and a removed alias cannot survive as an unverified cached fallback. The resolved name enters the anonymous connection lease through one credential-byte-bounded projection shared by the authenticated session title, fresh pairing record, trusted row, and diagnostics overview. Diagnostics keeps de-duplicated manufacturer/model text as secondary context; this display-only preference cannot retarget protocol or storage identity. A successful reconnect gives a pre-existing record a process-local pairing-ID-to-name display override and refreshes the secret-free trusted list without another Keychain read or write. The pairing-ID/cache mapping never enters Presentation or persistence; only its safe name is projected to the trusted row. A generation check after the cache actor hop prevents a concurrent disconnect from reviving stale ready state, and a confirmed-revoke tombstone rejects any later reordered remember. Five strict resource-loader regressions bring the then-current Swift inventory to 483; three direct diagnostics identity tests cover retail-name preference, fallback/de-duplication, and re-projection. This is local automated evidence only and does not claim a new current-tip 704SH physical pass.
- Cross-platform envelope validation (`frame_version` and optional payload CRC), with Mac response/error request correlation and Android pre-handler rejection plus correlated transfer-route cleanup
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
  - Atomic download writer with a pinned authorized directory, no-follow
    single-link regular partial, and non-blocking exclusive `flock` retained
    through publication. Final, partial, sidecar, sidecar `.pending`/`.removing`,
    fixed commit marker, and fixed replaced entry form one conflict namespace;
    product execution adds an in-process parent-inode/case-aware registry plus
    sorted cross-process advisory locks, a security-scope lease, and directory
    FD. The pinned parent contains private `0700`
    `.droidmatch-download-locks`, a bound `0600`
    `.droidmatch-download-lock-root` identity anchor, and persistent empty `0600` lock files named by
    domain-separated SHA-256 rather than raw destination names. Fresh work locks without truncating,
    removes the sidecar, resets that same FD, and only then connects. Commit
    synchronizes a fixed `0600` marker, publishes with `RENAME_EXCL` or validated
    `RENAME_SWAP`, and retains any displaced old target until sidecar removal
    succeeds. Finalization then removes the old target, synchronizes the directory,
    and retires the marker. Earlier failure/cancellation restores the old target
    and candidate partial while retaining the marker, republishes the sidecar,
    and retires the marker only after that checkpoint is durable. A failed
    checkpoint restore leaves the marker for interrupted recovery; unprovable restoration returns non-retryable
    `commitUncertain`. Crash-left marker/replaced entries restore as
    `interrupted`. Required directory `fsync` narrows process-crash recovery
    without claiming complete power-loss durability or malicious same-UID defense.
    Each previously unseen destination can add at most seven zero-byte lock
    inodes. Persistent hashed lock names are pseudonymous metadata, not encryption, and
    an uncooperative same-UID process can ignore advisory locks.
  - Upload v2 checkpoints bind size, nanosecond mtime, nanosecond ctime,
    filesystem number, and inode to one `O_NOFOLLOW` source descriptor retained
    for the attempt. The path and descriptor are revalidated around every read;
    restore checks only v2 structure/path until AppSupport holds the bookmark
    lease, then the coordinator rejects a mismatched exact snapshot before its
    client factory. Same-size/same-millisecond replacements are rejected, and a
    non-zero legacy v1 checkpoint fails before any reconnect.
- CLI harness with commands: devices, forward, handshake-smoke, m1-smoke, dual-download-smoke, mixed-transfer-smoke, list-dir, download, upload, etc.
- Throughput measurement (elapsed_ms, throughput_mib_per_sec)
- Opt-in versioned transfer-queue manifest with atomic writes, stable job/FIFO identity, private file permissions, sidecar-gated scheduler reconstruction, and non-replayable `interrupted` state. Untrusted recovery input is bounded to 10,000 jobs, 10,000 configured retries, one-day delays, and cumulative attempt number 1,000,000. Queued and ordinary paused jobs must retain full retry headroom; resumable pauses may continue only from the consumed attempt or an actually announced retry, while active work without headroom becomes interrupted. Runtime retry/resume/terminal arithmetic uses the same checked ceiling, and a retry that cannot cross its manifest write boundary cancels the executor and disables persistent execution. Only structurally/path-valid checkpoints with a known non-conflicting total and `0 <= offset < total` restore paused; `offset == total`, `0 / 0`, unknown/conflicting totals, and other unsafe active work restore interrupted. A repaired product manifest is retried only while execution remains held: AppSupport reloads bookmarks, obtains every checkpoint security scope and download directory capability, canonicalizes the whole queue, verifies target readiness, and then activates. Any failure keeps the scheduler reload-required for another retry. Session suspension likewise delays completion settlement for a cancelling unsafe executor; ordinary unwind stays interrupted, while only a download already beyond its local rollback boundary may truthfully complete. Download/upload sidecars and private queue/bookmark files use pinned-parent, no-follow, single-link boundaries plus fixed `.<name>.pending`/`.<name>.removing` recovery entries, complete stat and parent-rebinding checks, and required file/directory `fsync`. Every used parent keeps one permanent zero-byte `0600` `.droidmatch-private-atomic-lock`; exact no-follow owner/type/link/mode and named-inode checks around exclusive `flock` serialize read/save/remove across cooperating processes and separate same-process opens. Unsafe locks and crash-left markers fail closed. Mutation failure proves rollback or reports `commitUncertain` with the scene preserved. A malicious same-UID process can still ignore advisory locking and retain the narrow final stat-to-unlink race; this is not a power-loss guarantee.
- Protobuf-free product directory domain types plus paged `AsyncRpcControlClient` listing and embedded-error/row/token validation; optional provider MIME is canonicalized to a restricted lowercase ASCII value of at most 127 bytes, while malformed metadata degrades to nil without changing row identity, capability, or authorization. `DirectoryBrowserPresentationTypes` keeps UI-only bidi/control-safe names plus independent browse/upload projections without changing remote identity, `DirectoryBrowserPolicy` keeps direct-child/mutation/media/error decisions pure, and the MainActor `DirectoryBrowserModel` alone owns clients/tasks/generations, atomic refresh, retryable load-more, stale-generation rejection, cross-page deduplication, and sanitized published state. A pure `DirectoryBrowserThumbnailState` owns only thumbnail generation/FIFO/active-key/failure/cache transitions; it retains draining old-generation requests against the four-request limit while rejecting their publication, and bounds cached images to 64 entries/8 MiB without owning a client, Task, permission decision, or Published value. Navigation cancels only the old listing and queued old-generation row thumbnails, not an admitted mutation; same-path completion refreshes the current search/sort query, while another path suppresses the stale result/error. Hiding the browser clears queued work, preview, and cache without losing listing/query/navigation. The 512-pixel preview is outside the thumbnail queue and may be the fifth control request. Listing pagination uses separate preview/thumbnail validity, so load-more cannot strand the current preview in a loading state. Unreadable roots no longer trigger a list request, while an independently writable root retains a direct upload action. Native picker and Finder drop batches share one tested admission policy: 1–100 ordered non-symlink regular files, normalized-name uniqueness, and exact destination/media filename validation.
- Create, rename, single-delete, and batch-delete failures use operation-specific fixed guidance. A synchronous create/rename admission rejection remains visible in its edit sheet, while an admitted asynchronous failure is shown by the browser; neither path exposes an item name, logical path, or raw exception. 中文：创建、重命名、单删与批删按操作使用固定脱敏说明；同步准入拒绝留在编辑 sheet 内，已准入后的异步失败回到浏览器提示，两者都不携带条目名、逻辑路径或原始异常。
- Selected downloads reject normalized duplicate names and existing local targets before any queue submission. Their subsequent jobs persist independently, so zero/partial admission has distinct fixed guidance, accepted tasks remain visible in Transfers, and only unaccepted files remain selected for a safe retry instead of the result being misreported as a rolled-back batch.
- Separate `DroidMatchPresentation` library with a MainActor `TransferQueueModel`: ordered full-snapshot observation, explicit idempotent start/stop/restart, non-optimistic pause/resume/cancel/remove forwarding, per-job duplicate-action suppression, precise post-unwind removal capability, and safe-local-basename-only row state. `ProductDisplayText` bounds and removes spoofing controls before the basename reaches either SwiftUI or opt-in system notifications; unused full remote paths no longer enter the Published item, and actions remain UUID-addressed. One model-wide single-flight serializes single/batch download and upload admission across file and media surfaces before data-source side effects; already admitted jobs still execute concurrently under the scheduler. The App binds the whole file/media interaction surface to that busy lifetime, including search, selection, row/context actions, navigation, and section switching; batch completion removes only accepted request indices from current selection. Unhealthy or retrying persistence and stable-order bulk cleanup are mutually exclusive with submission, disable every file/media transfer entry point before a native panel opens, and show an in-place recovery warning while browsing and remote mutations remain usable. Bulk cleanup admits only settled successful rows, retains failed/cancelled/interrupted/pending/unwinding work, and discloses partial removal with exact counts. Retry/failure/interruption guidance comes from coarse typed categories parsed only from exact Core labels; unknown or extended text is rejected and raw failure descriptions never enter Presentation.
- Product transfer affordances and transfer-page pause/resume/cancel/remove/cleanup remain closed until the first authoritative persistence-status read, so the initial `.disabled` placeholder cannot be mistaken for verified recovery health. Unknown or retrying storage is shown as pending rather than green/healthy, failed storage blocks row mutations, and a late backend rejection produces fixed localized feedback without exposing a path or raw error; browsing and remote mutations remain available.
- Authenticated persistent bidirectional product queue: readable files use a native save panel; writable app-sandbox/SAF/MediaStore directories use a native picker for up to 100 independently persisted files, with accurate partial-admission disclosure instead of a false all-or-nothing claim. Private manifests are device-isolated through a domain-separated route derived after authenticated proof rather than a raw-fingerprint filename. Pre-M1 raw-fingerprint filenames migrate by an atomic no-clobber rename, while collisions and non-regular files remain untouched and fail closed. Every attempt creates a fresh paired RPC client behind a session gate; app-sandbox/SAF retries resume while MediaStore remains fresh-only; disconnect pauses recoverable work and interrupts unsafe work before releasing the forward
- MainActor `DeviceDiscoveryModel` with atomic refresh, cancellation/generation guards, sanitized failures, and no ADB serial in presentation state

**Android Side:**
- Foreground connection service
- One-shot ADB endpoint (loopback only, with timeouts, atomic stop/admission, and a fixed four-session worker/socket bound); every rejected pre-ready frame now zeroizes and closes the setup session, so periodic bad frames cannot refresh the first-frame window or monopolize the bound
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
  - ListDirRequest (roots, media, SAF, app-sandbox): exact requests default to
    200 and cap at 1,000 entries, tokens cannot address beyond a 10,000-entry
    exact-query retrieval horizon, a provider that still has rows at that
    boundary returns error-only `unsupportedCapability` rather than an empty
    token, and App Sandbox/SAF scans stop after 25,000 inspected rows with the
    same stable bounded-capability code
  - CreateDirectoryRequest / RenamePathRequest / DeletePathRequest
  - SAF rename tokens retain their listed parent provenance; missing-parent or cross-directory requests fail before the platform name-only rename, while same-parent and direct-root-child renames remain supported
  - ThumbnailRequest
  - OpenTransferRequest (download and upload)
  - TransferChunk/TransferChunkAck
  - CancelTransferRequest
  - PauseTransferRequest
  - DiagnosticsRequest
- File providers:
  - MediaStore (images/videos via content resolver)
  - MediaStore image albums (API 26+ bucket aggregation, strict opaque tokens, lazy latest-image covers, and canonical media paths inside filtered views; physical album evidence currently stops at API 34)
  - SAF (tree URI permissions, directory listing)
  - App sandbox (private files/droidmatch-sandbox)
- Provider features:
  - Download: seekable FD or stream with offset skip
  - App-sandbox download metadata and opaque source identity come from `fstat`
    on the already-open descriptor; same-size/same-mtime atomic replacement
    invalidates resume without a full-file pre-hash
  - Upload: transfer-scoped private staging and fail-closed durable atomic
    commit on final chunk; app-sandbox staging lives in a private sibling
    directory outside the exposed root and binds destination/transfer/size.
    The sibling staging node must be a real directory under no-follow checks;
    an ordinary file or symbolic link is rejected intact. Fresh cleanup also
    preserves and rejects any matching unexpected directory or symbolic-link
    partial instead of deleting it. Resume partials use
    one no-follow channel, force that descriptor before close/replacement, and
    never downgrade a synchronization failure or unsupported atomic replacement.
    The former in-root partial filename shape stays hidden and unaddressable so
    pre-migration incomplete bytes are not exposed after upgrade
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
- Product launcher entry (`DroidMatchActivity`) with a tested next-step readiness summary, paired-required endpoint controls, pairing approval, secret-free paired-Mac list/revoke, notification permission, user-triggered photo/video authorization or reselection with a live full/limited/denied summary, and SAF authorization list/add/revoke. Peer-controlled Mac names now cross one UI-only safe-display projection before pairing approval, trusted-list, or revoke-confirmation rendering: it NFC-normalizes, collapses whitespace, removes control/Unicode-format/surrogate code points, and uses fixed `Mac` when nothing visible remains. The authenticated raw name stays in the transcript and encrypted credential metadata, while pairing ID remains the revoke identity. SAF add/release now re-reads the live persisted-grant snapshot and succeeds only when the selected stable root appears/disappears; system exceptions, missing/malformed snapshots, or a still-present revoked root produce fixed privacy-bounded guidance. An unreadable list marks both the list and top-level folder count unavailable and exposes an explicit retry. Trust revocation closes active USB sessions, while diagnostics harness naming remains confined to debug source. A successful paired reconnect monotonically updates the credential's encrypted last-used timestamp; persistence failure is diagnostic-only and does not invalidate a correct proof. Media root `can_read` now follows live image/video access independently from `can_write`; this product permission flow has local JVM/wiring/assemble/lint evidence but no archived physical UI pass.
- A temporarily unreadable paired-Mac catalog is no longer rendered as zero trusted Macs. The paired-Mac region is a polite live region with an explicit retry, and pure `ProductReadiness` policy independently selects all four paired-catalog/SAF-catalog availability summaries so one unavailable source cannot falsify the other source's count. This is local JVM/wiring/resource evidence only and adds no physical UI claim.
- Explicit no-backup/no-device-transfer rules for private app, pairing, SAF, transfer, and diagnostics state
- Original adaptive-vector launcher mark with Android 13+ monochrome themed-icon support

**Tooling:**
- `tools/check-source-size.py`: one 800-line ceiling for every handwritten production, unit-test, and instrumentation-test Swift/Java/Kotlin source plus all shell/Python files under `tools/`, with no exceptions. The discovered 3,277-line physical-device orchestrator is now a 673-line final orchestrator over explicit usage, option/validation, device-control, privacy/evidence, App Sandbox probe, result-log, and cleanup helpers; every helper fits the same default.
- The transfer-time media-permission fault hook is now a self-contained fresh process rather than an undeclared consumer of the parent runner's shell functions. It suppresses the private serial, adb path, command arguments, and platform output and emits only one aggregate command status; offline success/failure execution tests prove both independence and redaction. Existing archived physical permission evidence is unchanged, and this local regression adds no new device claim.
- The former 783-line product file-browser parent now keeps SwiftUI state, native panels, mutations, and queue submission in 682 lines; unchanged list/grid rendering lives in a 140-line stateless state/actions component. A 93-line pure Presentation value owns selection-mode/path reconciliation, capability-gated select-all, row-order projection, and accepted-only batch subtraction without a model, task, panel, or queue. Three direct tests cover that state. A 135-line AppSupport policy separately revalidates native-panel completion against the exact current query/rows/authorization/readiness and gives single/batch downloads one local-file-URL, existing-target, and canonical/case/width duplicate preflight. Five direct tests cover that boundary; this is local evidence only.
- The former 774-line directory-browser MainActor now keeps published/listing/navigation state, derivative Tasks, previews, permission decisions, and path-gated mutation outcomes in 628 lines. A 132-line pure thumbnail state owns generation/FIFO/active-key/failure/cache transitions while preserving draining requests against the four-request limit; three direct tests cover stale-generation concurrency, deduplication/visibility/failure admission, and dual cache bounds. A 157-line MainActor runner separately owns the active remote-mutation Task and operation identity without presentation or refresh policy. Existing directory-browser integration tests pass unchanged; that increment brought the Swift inventory to 437 and added no device evidence.
- The Android app-sandbox catalog now delegates every listing, mutation, download,
  and upload path to one 65-line stateless resolver before provider work. The
  resolver centralizes lexical validation, canonical-root confinement, and
  rejection of each existing symbolic-link component without owning an
  authorization, descriptor, or operation; the catalog falls from 679 to 646
  lines while retaining provider and staging lifecycle ownership. Three direct
  JVM tests cover ordinary/future entries, root/traversal/reserved-name aliases,
  and direct/nested links, bringing the Android inventory to 237. This is local
  evidence only and adds no physical-device claim.
- The lock-backed callback/async one-shot shared by RPC responses, transfer opens,
  upload acknowledgements, bounded download waits, and readiness gates now
  atomically claims its sole consumer before cancellation or continuation setup.
  A second wait returns a typed internal state error rather than replacing an
  active continuation, hanging the first task, or reaching the former
  post-consumption precondition crash. One direct regression brings the Swift
  inventory to 438; no wire behavior or device claim changes.
- `AsyncFramedTcpSession` now reuses that same one-shot for Network.framework
  completion/timeout/cancellation races instead of maintaining a second gate
  with its own trapping missing-result state; its established first-completion
  semantics remain covered by loopback success, timeout, and cancellation tests.
  `AsyncRpcControlClient` now carries the negotiated result inside its `ready`
  state, making a ready-without-handshake cache impossible. A process-local
  scheduler persistence reload now returns the existing stable `ioFailure`
  instead of terminating the process. Scheduler admission now uses Swift typed
  throws, so its compatibility projection has an exhaustive error type and no
  fallback process trap. One direct regression brings the current Swift inventory
  at that point to 439. No wire, device, or release-signing claim changes.
- `AsyncTimeoutPolicy` now rejects non-positive and non-finite durations and
  saturates huge finite values before integer or `DispatchTime` conversion.
  Transport, RPC deadlines, subprocess waits, and every harness
  `--timeout-seconds` path use that boundary; a missing option value also fails
  before connecting or launching a process. Product ADB discovery also maps an
  invalid configured duration to stable `timedOut` without launching ADB. Six
  direct regressions brought the then-current Swift inventory to 445. The real
  login-Keychain round-trip test is now
  explicitly opt-in through `DROIDMATCH_RUN_SYSTEM_KEYCHAIN_TEST=1`; ordinary
  gates use the injected backend and do not request Keychain secrets. Product
  pairing still uses the Keychain. No wire, device, or release-signing claim changes.
- Trusted-device display and credential selection now use separate Keychain
  boundaries. Dashboard listing never requests generic-password data: current
  records use the validated key-free envelope, while pre-envelope records use
  the account, label, and Keychain creation/modification attributes. Its passive
  query uses a non-interactive `LAContext`, so a record requiring authentication
  fails the display snapshot instead of opening UI. An explicit connection loads
  only the fingerprint-matched current credential. A successful reconnect does
  not rewrite the secret-bearing item, so recency bookkeeping cannot open another
  authorization request or invalidate an otherwise correct proof. Legacy items
  cannot use the macOS-incompatible `MatchLimitAll + ReturnData` shape, so their
  bounded per-account reads share one `LAContext`; after all records validate,
  every selector is backfilled and later connections use the current single-item
  path. Fresh pairing atomically add-only publishes its provisional credential,
  treating every duplicate pairing ID as a collision without reading or updating
  the existing item, then returns the newly persisted Core credential directly
  into the immediate proof instead of reading the new item back. The regressions prove
  zero display reads, one current-item read plus zero writes for reconnect, zero
  zero secret reads for first pairing, and one shared legacy authentication context;
  the authenticated coordinator passes that already-proven Core credential
  directly into the same-generation transfer gate, then clears its own reference,
  so scheduler construction does not perform a second Keychain read. Disconnect,
  replacement, and keepalive failure detach/invalidate the gate with the existing
  audited teardown order. The then-current Swift inventory remained 460. This
  changes neither the pairing protocol nor physical-device/release evidence.
- A process-lifetime monitor now detects when transactional publication replaced
  or removed the running App executable. It captures the vnode backing dyld image
  zero through `proc_pidinfo`, avoiding a launch-to-monitor path race, then compares
  that device/inode identity with the same path every two seconds, including while
  no window is open. One irreversible callback invalidates discovery, trusted-device
  Keychain-list/revoke, and session entry points, cancels or generation-rejects
  late publication, enters the existing safe disconnect, removes the old window
  hierarchy, and disables global refresh. A localized Quit-and-reopen banner
  remains; the monitor itself does not read Keychain state or launch a replacement
  process. An App-lifetime active-window lease set also keeps shared discovery alive
  until the last active window leaves and rejects every future lease after runtime
  invalidation. One monitor lifecycle/replacement/removal/non-regular regression,
  one multi-window lease regression, and three model-gate regressions bring the
  Swift inventory to the then-current 465. App publication now also refuses a live target before
  any stale-transaction recovery and rechecks immediately before install/swap.
  Darwin compares both the current vnode path from `proc_pidpath` and the kernel-
  retained `KERN_PROCARGS2` launch path, so rename, swap, and unlink remain visible;
  inspection failure is fail-closed. Native behavior and interrupted-recovery
  regressions plus the M0 contract bind both guard positions; mac-skeleton runs the
  platform test and the monitor covers the remaining narrow launch race.
  This adds no device or signing evidence. The same source contract binds the
  mapped-vnode capture, App/window ownership, global command guard, and all three
  model gates.
- The schema-v1 diagnostics exporter now revalidates its public snapshot input
  at the export boundary: external text is bounded and control-safe, invalid
  SDK/storage/battery values are omitted, recent-error count is clamped to the
  documented range, and negative counters are discarded. One direct malicious-
  snapshot regression brought the then-current Swift inventory to 446 without adding
  fields, paths, logs, device claims, or release-signing claims.
- The former 768-line transfer scheduler actor now keeps live task/record/queue, persistence effects, timers, and publication in 699 lines. A 120-line pure execution-event policy validates retry attempt accounting, makes retry persistence rollback explicit, accepts only monotonic stable-total progress, and expires only the current running rate generation without owning a task, timer, store, queue, continuation, socket, or broadcast. Four direct tests cover those transitions, bringing the Swift inventory to 431; the existing 68-line completion policy still reconciles executor unwind. This adds no device evidence.
- The former 755-line atomic download writer now keeps descriptor and transaction orchestration in 480 lines; a 274-line stateless partial-file boundary owns no-follow directory opening, single-link validation, non-blocking `flock`, and descriptor/name inode reconciliation without retaining descriptors or writer state. All 18 focused atomic-download tests pass unchanged; the then-427-test Swift inventory was unchanged and this adds no device evidence.
- The private App-owned atomic state writer now keeps read/write/remove transaction orchestration in 371 lines and unchanged pinned-location/snapshot/rollback/recovery helpers in a 425-line same-module extension. Eight focused filesystem and cross-process lock tests pass; syscall ordering, error mapping, and product API are unchanged. That split left the then-420-test Swift inventory unchanged and adds no device evidence.
- The current source inventory is 486 Swift tests and 242 Android JVM tests. Android's pairing countdown remains visual in a separate accessibility-hidden view; a stage-only polite live region changes only for meaningful closed/waiting/approval/approved/rejected transitions, without using Android 16's deprecated explicit announcement API. The pending SAS is exposed as six separately spoken ASCII digits, and unchanged 500 ms stage/client/code writes are suppressed. This is offline evidence, not an attended-device accessibility claim.
- The Android build baseline retains min API 26 while compiling/targeting API 36 with Build Tools 36.0.0, AGP 8.12.2, JDK 17, and a SHA-256-pinned Gradle 8.14.5 wrapper. The product Activity uses a dedicated no-ActionBar theme so its own header does not displace the first secure-USB action on compact legacy screens with accessibility font scaling; side-by-side actions keep equal width and share the taller label's measured height so a scaled/localized second line is neither clipped nor paired with a shorter button. The release merged-manifest check freezes the theme boundary. The opt-in `slot-a-704sh-layout-v2` instrumentation profile skips unless explicitly requested, then fails closed on exact API/model/720×1280 physical display/720×1136 app viewport/320 dpi/en-US/1.3 font-scale prerequisites and a multiline English label before checking initial bounds, both action rows' uniform heights, every visible button's measured text/padding height, scrolling to the end, and final add-folder visibility above system navigation. Its dedicated explicit-serial runner requires the product to pre-exist and the test package to be absent, installs the OEM-sensitive test APK before replacing the product debug APK with `-r`, and then removes only the test package on every later exit while verifying the product remains. Every ADB query/install/instrumentation/cleanup subprocess is now bounded; interactive commands default to 300 seconds with an explicit 600-second ceiling, and a timed-out create-only test install never grants cleanup ownership or advances to product replacement. Its offline failure matrix covers rejection, partial install, test/product/instrumentation timeout, product-replacement failure, instrumentation failure, wrong test counts, and cleanup failure without any product uninstall or clear. An attended v2 run passed on the exact 704SH configuration on 2026-07-19; without a versioned result-log producer/validator or archived log, it remains a focused diagnostic and adds no formal physical UI evidence. A later current-main retry found the OEM install command still pending after the package appeared; it was stopped without claiming the package, Android then rolled the test package back, and the product remained installed. After the bounded runner landed on exact main `317fe7e`, a further attended retry reached its configured 120-second test-install timeout with no test package present; it did not replace the product, and post-run verification found the product installed and the test package absent. Both failed diagnostics add no passing evidence; the latter physically confirms the bounded failure path on 704SH. The launcher applies system-bar/display-cutout insets on API 35+ for mandatory edge-to-edge.
  The test install deliberately omits `-r`: cleanup ownership begins only after an unambiguous create-only success, while a concurrent or ambiguous post-failure package is left untouched. The matrix also rejects skipped, negative-status, statusless, and wrong-count instrumentation results, product disappearance, package-query errors, and temporary-file leaks.
  These counts and the script transaction regressions below are local evidence;
  they add no physical-device, Developer ID, or notarization result.
- Text and buttons owned by the `DroidMatchScreen` main hierarchy now use simple line breaking with automatic hyphenation disabled across the supported API range. This prevents API 26 from rendering an ordinary localized word such as `system` as `sys- / tem` when the source string contains no hyphen. System-owned dialog views remain outside this main-screen policy. The exact 704SH profile asserts the configured hierarchy in addition to its existing height and full-scroll bounds. A clean exact-commit `45ad705` product-only `adb install -r` update on 704SH preserved one paired Mac and two authorized folders; attended top/end screenshots showed the word-boundary wrap without the invented hyphen, the first action unclipped, and the final add-folder action fully above the restored system navigation area. This has no versioned producer/validator or archived log and did not execute instrumentation, so it remains diagnostic-only rather than formal physical UI evidence.
- The bounded 704SH test install exposed a stricter OEM boundary after the earlier 120-second timeout: an immediate post-run query reported the test package absent, but it later appeared with `firstInstallTime=2026-07-19 09:44:34`, `versionCode=0`, target SDK 36, and `DEBUGGABLE`, matching the authorized instrumentation attempt. After that provenance was established, only `app.droidmatch.test` was removed and the product remained installed. The runner now treats every timed-out create-only test install as unresolved even when the package is currently absent, because a device-side late commit can invalidate an immediate absence check; it never advances to product replacement or cleanup ownership.
- `tools/build-mac-app.sh` assembles and verifies a private same-filesystem
  candidate, then uses a stable private publication transaction. First
  publication uses `RENAME_EXCL`; replacement uses `RENAME_SWAP` with identity
  checks before and after each transition. Transaction ownership binds the PID
  to its boot-scoped process start identity, so PID reuse after a crash or reboot
  is stale rather than falsely active. A following invocation recovers a
  tested `SIGKILL` between swap/state updates or fails closed on active, legacy,
  inconsistent, or unsafe transaction state; this is not a power-loss durability
  claim. A valid embedded adb vendor signature is preserved (only a genuinely
  unsigned custom adb is signed locally, while an invalid existing signature is
  rejected), and the outer ad-hoc App resource seal binds
  its exact bytes. Candidate validation defers only `adb version`, after verifying
  the complete static/signature/entitlement boundary; the published final path is
  then fully verified before completion, with replacement rollback or first-publish
  withdrawal on failure. Only the exact transient `embedded adb is not runnable`
  result receives at most two retries. Offline hard-kill coverage spans first
  install, published-path verification, both sides of the durable verified-state
  write, and `rollback-required`/rollback-swap/`rolled-back`; only a fully verified
  state survives recovery. Output-parent creation
  now preserves the mode of an existing directory
  instead of using `install -d`; an offline regression holds a non-default mode
  across a successful build, and a real release build under `/private/tmp` no
  longer attempts to remove that directory's sticky/world-writable permissions.
  Product builds and Swift tests now share the same writable module-cache,
  outer-sandbox adaptation, and probe-gated arm64e fallback. Ten exact RGBA icon
  renditions are packed into a no-clobber modern ICNS container and reopened by
  the platform decoder before signing, avoiding the locally reproduced macOS 26.5
  `iconutil` encoder rejection. Offline tests cover the packer and both default/
  fallback build arguments; a real dirty release App build passes locally.
- Real release-App UI inspection confirms the device dashboard and all four
  inactive-session surfaces are reachable and accessible. Files and Diagnostics
  now state the current connection/authentication prerequisite instead of the
  obsolete future-wiring placeholders; Media and Transfers already did so. This
  inspection did not connect to or mutate an attached Android device.
- `tools/build-mac-dmg.sh` first writes and synchronizes PID plus boot-scoped
  process-start owner identity, marker, and state in a private initializer, then
  publishes the complete stable transaction
  with `RENAME_EXCL`. Absent canonical nodes publish with
  `RENAME_EXCL`; existing nodes publish with `RENAME_SWAP` and two-way validation,
  while rollback uses EXCL/SWAP according to recorded prior state. Recovery
  validates previous, candidate, and canonical identities before/after each
  transition by device, inode, size, and SHA-256. Offline tests cover every legacy
  and new initialization boundary, active-initializer protection, live-PID/stale-
  process-identity recovery, a real building
  `SIGKILL`, concurrent insertion/replacement fail-closed behavior, recovery after
  the first replacement, recognition of a complete pair, interrupted first
  publication, and preservation of old bytes when rollback is uncertain; this
  does not claim power-loss durability.
- `tools/push-main-with-gates.sh`: explicit-confirmation, no-PR owner integration that requires a clean fast-forward HEAD, rejects known maintainer-contract/inventory drift locally before any remote push, validates Phase A before and after candidate CI, runs the exact SHA through a unique protection-eligible temporary `push` ref, rejects a changing main tip or wrong event/run identity, never force-pushes, cleans its owned ref, and returns success only after the exact `main push` run also passes and protection remains intact; the local preflight does not replace hosted admission, and the offline suite covers preflight rejection, remote-mutation ordering, and every fail-closed boundary
- `tools/run-m1-device-smoke.sh`: comprehensive device test script that builds/invokes the Mac harness in Swift release configuration, maps unreadable Git state to unknown provenance, emits one strict `m1-device-smoke-v1` record binding recorded source/build/APK identity, slot/API, check dependencies and result markers, final offsets, per-attempt measured bytes/rates, result class, and cleanup intent, validates a private staged log, and publishes without following or replacing an existing result path. Only clean rebuilt full-revision runs are `device-evidence`; dirty/unknown/reused passes and failed runs are diagnostic. It includes opt-in `--dual-download-check` and `--mixed-transfer-check` with a distinct fresh upload target, and creates mixed-download atomic destinations under canonical `/private/tmp` rather than the macOS `/tmp` symlink
- Harness download destinations fail with a stable path-free label for user or
  volume ancestor symlinks. The writer maps fixed macOS `/var`, `/tmp`, and
  `/etc` aliases to `/private`, then opens every remaining component no-follow.
  CLI/device evidence keeps canonical `/private/tmp` for comparable archived
  paths; that convention is not a product capability restriction.
- `tools/run-m1-throughput-gate.sh`: fail-closed Slot A wrapper whose pass-only `m1-adb-throughput-v2` profile requires a validated clean/rebuilt `m1-device-smoke-v1` producer record, exact full-SHA/check-plan/metric producer binding, command-error-aware current-main provenance, one exact selected-serial match on a hub-free macOS host-controller USB path before build/device writes, 0.5-second revalidation for the complete child runner, post-run and pre-publication rechecks, API 26–29, exact fresh 100MiB download/upload, raw ADB baseline, requested/negotiated 1MiB chunks, formula-consistent observed rates, both ≥20 MiB/s thresholds, the fixed managed-zero payload hash and matching download/upload SHA-256 values outside the timed product-transfer windows, privacy-bounded output, verified cleanup, staged single-log validation, and atomic no-clobber fixture publication. The registry reader stops before allocating more than 16 MiB. Missing, duplicate, malformed, non-macOS, hubbed, or mid-run-unverifiable topology terminates the child and cannot publish a failed diagnostic. After strict preflight, a non-topology wrapper failure can instead publish the separate fail-only `m1-adb-throughput-diagnostic-v1` only when the private `m1-device-smoke-v1` producer first passes standalone validation; the combined archive embeds that validated producer record and preserves its available metrics, fixed failure stage, source/expected/origin binding, post-run provenance, producer exit/result, recorded digests, and aggregate cleanup state while the command remains non-zero. Invalid/missing producers, privacy or validator failures, and no-clobber races publish no diagnostic. Throughput v1 remains rejected, and only a passing v2 can satisfy Slot A
- `tools/run-product-usb-insertion-smoke.sh`: attended `m1-product-usb-insertion-v1` profile with a pre-signal absence check, monotonic-before-signal boundary, exact discovery-card AX identifier, verified running release bundle provenance, explicit physical-action attestation, and no-clobber pinned-descriptor validated fixture publication
- `tools/check-product-usb-insertion-logs.sh`: strict dedicated product-insertion fixture schema, provenance, privacy, timing, and count validation
- `tools/m1-fault-proxy.py`: local frame proxy for fault injection
- `tools/check-m1-skeleton.sh`: CI validation
- `tools/check-m1-run-logs.sh`: quiet privacy rejection plus strict directory or staged single-log semantic validation for ordinary, throughput-pass, and throughput-diagnostic profiles; new ordinary logs require `m1-device-smoke-v1`, while the 89 unprofiled historical fixtures are accepted only at the byte-exact paths frozen by `legacy-v0.sha256`
- The throughput failed-diagnostic path still has offline tooling coverage only; no physical `m1-adb-throughput-diagnostic-v1` fixture is archived. The later clean Slot A media-permission record is ordinary device evidence and does not close either remaining M1 blocker
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
- Mac and Android both expose secret-free trust management. Mac revocation waits for active-session teardown before deleting the Keychain record; a failed/false deletion retains the trusted row, marks the snapshot unavailable, and presents only fixed privacy-bounded guidance. An already-running Keychain list may finish after its visible deadline, but an intervening revoke invalidates that result so stale metadata cannot republish a removed row. Android revocation closes active USB sessions. Slot C ordinary-App first pairing, paired reconnect, sandboxed product authentication, and attended real Android Keystore behavior are archived.

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
  - Resumable upload creation now has a strict double write-ahead boundary: the
    v2 sidecar and schema-v2 queue both persist the exact destination/transfer/
    expected-size cleanup tuple before the first client factory call. Permanent
    cancellation, terminal-history removal, and shutdown preserve a retryable
    cleanup record; a fresh paired client with `FILE_WRITE` and
    `RESUMABLE_TRANSFER` deletes only the exact App Sandbox/SAF private partial,
    treats missing as success, never touches the final destination, and settles
    or removes the row only afterward. Restored cleanup runs before ordinary
    queue work, while pause/session suspension still retains resume state. Local
    Swift/JVM/wire tests cover write-ahead failure, schema-v1 compatibility,
    cancellation/removal/shutdown restoration, authentication/capabilities,
    destination exclusion, exact tuple routing, idempotency, and final-file
    preservation; this adds no physical-device evidence.
  - `AsyncTransferScheduler` provides FIFO admission, a two-job cap, buffering-newest queued/running/retrying/pausing/paused/interrupted/terminal snapshots, monotonic receiver-confirmed bytes/total across retries, a two-second time-weighted recent-throughput sample, retry visibility, completion waiting, cancellation, and checkpoint pause/resume. It remains process-local by default; `restoring(...)` opts into a versioned atomic manifest, writes queued-to-active intent before starting an executor, and can hold every start path behind product authorization readiness. It restores only matching download/app-sandbox/SAF sidecars and keeps unsafe active work (including MediaStore) visible as non-replayable `interrupted`; a repaired corrupt manifest now re-enters that same lease/readiness transaction instead of requiring process restart. Session suspension keeps unsafe running work unsettled until executor unwind, so an irreversible locally committed download can complete without manufacturing a resumable interrupted row. Queued pause is a hold; running checkpoint pause closes only that coordinator session and requeues the same job/transfer identity. This local policy does not claim Android wire upload pause.
  - Dual/mixed probes are both script-invocable; download and provider-aware upload scheduling are wired into the authenticated visual target with device-isolated persistence, App-owned security-scoped bookmark leases, and lifecycle-ordered suspension. Slot C archives ordinary-App pairing/reconnect/download and sandbox-App pairing/browsing/download/upload. Sandbox uploads keep checkpoints in the App-owned device queue directory rather than beside a read-only-authorized source.

**Testing Coverage:**
- Slot D device (NIO N2301, API 34): extensive coverage
- Slot A (SHARP 704SH, API 26): required-slot handshake/list and clean current-tip media-permission revocation evidence are archived; the two functional 100MiB resume probes used the old debug/Onone Mac harness and predate the current transfer optimizations, so their sub-20 MiB/s results are historical diagnostics rather than current-tip gate evidence
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
| Permission-denied mapping | ✅ Slot C/D provider behavior passing; product media UI needs physical archive | Media listing revoke returns `permissionRequired`. Android now proactively re-checks image/video-specific MediaStore access and exact SAF tree access before each active provider chunk, plus SAF once more before final publication. Android 14+ selected-media access also verifies the exact item remains visible, and local tests cover deselecting the current item while another stays selected. The product launcher now requests/reselects media only after an explicit user action and publishes live media-root read capability; Mac blocks unreadable navigation without discarding a valid root upload. These UI/root-capability changes have local automated evidence only. Denied routes/leases close while control and replacement work remain usable. Provider `SecurityException` races are normalized to `permissionRequired` for MediaStore/SAF and `internal` for app-sandbox. An OS permission change may still tear down the endpoint before a typed error reaches Mac; Slot C/D archive that valid transport-loss outcome and restored grants. Physical product permission/reselection and SAF mid-transfer revocation remain unarchived. |
| Diagnostics attribution | ✅ Implemented | Service/permission/transfer state |
| Three-device coverage | ❌ Throughput and insertion gates incomplete | Required Slot A/C/D devices are represented, but Slot A lacks current-tip release-configured download/upload throughput evidence and every required device still needs archived attended product USB insertion ≤5s evidence |
| AOA viability (2 devices) | ❌ Blocked | Waiting for ADB path completion |

## Immediate Next Steps

### High Priority (M1 Blockers)

1. **Re-establish current-tip Slot A throughput on SHARP 704SH (API 26):** the archived 16.63 MiB/s download and 15.70 MiB/s upload rerun used the old debug/Onone Mac harness and predates the current transfer optimizations. Re-run through a direct host port/cable with `tools/run-m1-throughput-gate.sh --serial <serial> --expected-main-sha <40-hex>` so one versioned profile records the raw ADB baseline, exact fresh 100MiB download/upload, actual negotiated chunks, thresholds, managed/download/upload SHA-256 equality, provenance, privacy boundary, and cleanup verification. Digest verification runs after the timed product transfers and does not dilute their throughput measurement. A second API 26-29 device is a recommended non-gating cross-check before changing protocol assumptions or the threshold. Do not claim failure or success from the stale numbers.

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
   - ✅ Clean commit `9ea1804` reran the combined Slot C regression after fixing
     the runner's mixed-download `/tmp` symlink path: 20/20 handshakes, dual
     download, concurrent 10MiB download/upload plus heartbeat, 59 ms warm list,
     download resume/cancel/pause, and upload resume passed; owned remote
     final/partial paths, forward, and local temporary files were verified clean
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
- **The unified source-size debt is closed; broader governance debt remains:** all handwritten Swift/Java/Kotlin production and test files plus shell/Python tooling fit the default 800-line budget with no exceptions, and every product/CLI network path uses the async transport. The former 3,277-line physical runner is now a 673-line final orchestrator over bounded helpers. The file-browser toolbar, transfer persistence mapping, transfer-frame construction, scheduler test support, and framed-server state/readers/response values have explicit boundaries; contribution and PR handoff evidence is CI-enforced, but single-owner release authority remains concentrated; see [Structural Debt Baseline](technical-debt.md)
- **Scoped multi-stream support:** ordinary CLI download/upload commands remain single-transfer; `dual-download-smoke` and `mixed-transfer-smoke` are explicit probes. The mixed path and its preflighted 4 chunk / 2 MiB upload windows have local TCP evidence, a device-script entry, and archived Slot C physical-device results.
- **Default single retry:** `--retry-on-transport-loss` keeps the legacy single retry unless `--max-retry-attempts N` is supplied
- **Resumable SAF partial lifecycle:** Non-final non-resumable uploads are
  deleted, while paused or retryable transfer-ID uploads deliberately retain
  their hidden partial. Permanent product cancellation, terminal-history
  removal, and shutdown persist an authenticated exact-tuple cleanup that
  idempotently removes only the owned App Sandbox/SAF private partial after the
  same device reconnects; the final destination is never eligible. The Android
  provider performs no speculative orphan scan, so legacy harness partials,
  irrecoverably corrupt queue state, or work whose Mac never reconnects still
  needs explicit cleanup. The smoke runner separately cleans direct-root
  single-file SAF destinations through the protocol delete mutation; nested
  process-local document-token targets remain explicit/manual.
- **MediaStore fresh-only:** Upload resume not supported (returns unsupportedCapability)
- **Initial album index cost:** Consistent API 26+ behavior requires one streaming scan of MediaStore bucket columns while memory grows only with album count. A bounded LRU prevents per-cover rescans; resolving an old token after service restart may perform one fallback scan. API 35/36 remain locally built rather than physically archived for this UI.
- **ADB loopback only:** Android endpoint rejects non-127.0.0.1 clients
- **Debug harness Activity required by legacy device evidence scripts:** Some OEM devices freeze the service `accept()` thread without a foreground Activity. This limitation describes the nonce-only smoke workflow, not the Android product launcher's paired-required policy.
- **Android 15 background service budget:** the ADB loopback endpoint uses the `dataSync` foreground-service type and is limited to six background hours per 24-hour window. Timeout closes the endpoint and stops the non-sticky service; a future AOA path can use `connectedDevice` only after obtaining a real USB accessory grant.

## Test Result Summary

As of 2026-07-19, `fixtures/m1-runs/` contains:
- 90 test result logs
- SHARP 704SH (Slot A, API 26) handshake/list, current-tip media-permission revocation, and historical 100MiB throughput diagnostics; NIO N2301 (Slot D, API 34) broad matrix coverage; MEIZU M20 (Slot C, API 34) handshake/list, app-sandbox throughput/resume, permission, expected-error, MediaStore, and recovery evidence; and an unclassified Pixel 9 Pro Fold (API 37) two-device ADB routing smoke
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
- Passing: MEIZU M20 Slot C clean commit `9ea1804` exposed then fixed the device runner's mixed-download `/tmp` symlink regression without weakening `O_NOFOLLOW`; the rerun passed 20/20 handshakes, dual download, one-session 10MiB mixed download/upload with responsive heartbeat, 59 ms warm list, download resume/cancel/pause, and upload resume. Download/upload resume measured 30.72/20.27 MiB/s, and owned remote final/partial paths, ADB forward, Mac temporary files, and product-launcher restoration were verified.
- Passing: MEIZU M20 Slot C isolated Android Keystore instrumentation on exact then-main commit `aaf332a8`; both non-exportable identity/signing and AES wrapping/reopen/revoke tests passed (`OK (2 tests)`), the test package was removed, and the product package/data boundary was preserved
- Passing: SHARP 704SH Slot A handshake stability passed 20/20 attempts and warm `dm://media-images/` listing measured `elapsed_ms=165`
- Passing: SHARP 704SH Slot A clean rebuilt current-tip `m1-device-smoke-v1` revoked API 26 `READ_EXTERNAL_STORAGE`, observed stable `permissionRequired` for `dm://media-images/`, restored the prior grant, and archived the result from exact source `39d7f85`
- Historical diagnostic only: SHARP 704SH Slot A app-sandbox 100MiB download resume completed at 16.64 and 16.63 MiB/s, with raw ADB baselines of 7.19 and 11.21 MiB/s
- Historical diagnostic only: SHARP 704SH Slot A app-sandbox 100MiB upload resume completed at 15.20 and 15.70 MiB/s
- Those Slot A runs used the old debug/Onone Mac harness and predate the current transfer optimizations; they neither pass nor fail current-tip throughput and must be rerun with the release-configured runner
- Passing: Pixel 9 Pro Fold API 37 unclassified smoke passed 20/20 attempts with explicit serial routing while two ADB devices were connected
- Unit-covered abnormal paths: stale download resume source fingerprints, invalid page tokens, oversized envelopes, flagged envelope-payload CRC mismatch, bad transfer-chunk CRC32, terminal malformed chunk/ACK/provider/capability cleanup, bounded late-window draining, direction mismatch, crossed request/stream IDs, active MediaStore/SAF read-grant loss, SAF write-grant loss before a chunk or final publication, and the resulting route/lease recovery
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
