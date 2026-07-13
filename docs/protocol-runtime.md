# Protocol Runtime

This document records M1 runtime limits and scheduling rules that are not obvious from Protobuf schemas alone.

## Envelope Limits

- ADB M1 frames use `uint32_be envelope_length` followed by serialized `RpcEnvelope`.
- Android emits the four-byte big-endian header with one bulk output write,
  followed by one payload write. This removes four per-byte Java/native calls on
  older releases without changing framing or envelope limits.
- `envelope_length` must be greater than `0`.
- Maximum `envelope_length` is 4 MiB.
- Receivers must reject oversized or truncated envelopes with `ERROR_CODE_PROTOCOL_ERROR`.
- `payload_crc32` is optional for ADB M1 and recommended for AOA before it moves beyond experimental.
- Mac async clients share `RpcEnvelopeCodec`: they require `frame_version = 1`, validate `payload_crc32` when flag bit 0 is present, and correlate response/error frames by request ID before accepting payloads.
- Every Mac handshake uses a fresh 32-byte ClientHello nonce. Android validates 16...32 bytes and echoes it; Mac rejects a mismatched ServerHello. This is session correlation, not proof of peer identity.

## Authentication State

- `CORRELATED`: explicit M1-only mode; nonce echo completes setup with a reduced capability set. It does not authenticate identity.
- `REQUIRED`: paired mode has issued a fresh 32-byte server challenge. Android accepts only `AuthenticateSessionRequest` next; any other request clears provisional key material and closes the session.
- `AUTHENTICATED`: both role-separated proofs have been verified. Final capabilities come from `AuthenticateSessionResponse`, not the provisional ServerHello.
- `PAIRING_REQUIRED`: no usable pairing ID was supplied to `ClientHello`. The response is sent and that session closes. First pairing instead starts with `PairingStartRequest` as the first frame and succeeds only during the user-opened Android pairing window.
- Unknown pairing IDs are challenged with an ephemeral fake key so response shape does not enumerate pairing records. Proof failure is generic and closes the connection.
- The service currently selects `NONCE_ONLY` for ordinary control sessions, while injecting the visible pairing controller, stable device identity, Keystore-backed repository, and process-local authentication limiter needed by first-pairing RPCs. `PAIRED_REQUIRED` will not be product-enabled until on-device storage/reconnect evidence exists.
- The Android pairing window is closed by default, lasts 120 seconds when opened, and admits one pending attempt. Confirm waits at most 60 seconds for explicit Android approval. The one-shot Mac client should use a transport timeout longer than that interval (for example 90 seconds), never automatic retry with reused ephemeral keys.
- Three admitted first-pairing or per-ID reconnect failures start exponential backoff at one second; admitted failures after expiry double it to a 60-second cap. Ten admitted reconnect failures across identifiers trigger a separate global bucket so rotating random IDs cannot bypass the policy. Buckets expire after five idle minutes, are capped at 256 IDs, and are process-local.
- A rate-limited reconnect still receives the normal challenge and generic authentication failure. The wire does not reveal whether the identifier was unknown, the proof was bad, or an otherwise-correct proof arrived during backoff.
- Ready state does not bypass authorization: device info/diagnostics require `DIAGNOSTICS`, listing requires `FILE_LIST`, download/upload require `FILE_READ`/`FILE_WRITE`, and resume/cancel/pause require `RESUMABLE_TRANSFER`. Missing capability returns `UNSUPPORTED_CAPABILITY` before provider access.

## Request Scheduling

M1 has one control-plane queue and one data-plane queue per active session.

- Handshake, heartbeat, cancel, pause, diagnostics, and permission-state requests have control priority.
- Directory listing and file mutation are normal control-plane work.
- Transfer chunks are data-plane work and must not block control-plane reads.
- Receivers should process cancel and pause requests even when transfer data is queued.

Control-plane starvation is a bug. If the Mac harness cannot get a heartbeat or cancel response while a transfer is active, M1 should fail that run.

The product async Mac path selects multiplexed transport mode before ClientHello.
`AsyncRpcMultiplexer` owns the only reader, serializes writes, routes control by
`request_id`, and routes transfer frames by both request and stream IDs. Idle reads
have no transport timeout; the 16 control requests, transfer opens, and upload ACK
waits each carry their own deadline. FIFO `roundTrip` calls cannot share that session.
The product coordinator sends a heartbeat every 10 seconds while its authenticated
control/browser client is ready, so normal time spent reading the UI does not cross
Android's 30-second ordinary idle boundary. Transfer attempts continue to use fresh
authenticated clients. During `PAIRING_AWAITING_CONFIRM`, Android instead extends
the socket read timeout to 125 seconds so the visible 120-second SAS window, rather
than the ordinary idle timeout, remains authoritative.

## Concurrency Limits

M1 defaults:

| Resource | Limit |
|---|---:|
| Concurrent transfer streams | 2 |
| Concurrent directory listings | 2 |
| In-flight control requests | 16 |
| Default page size | 200 entries |
| Maximum page size | 1,000 entries |
| Default transfer chunk size | 256 KiB |
| Maximum transfer chunk size | 1 MiB |

The ordinary download/upload commands remain single-transfer flows. The dedicated
`dual-download-smoke` exercises two downloads through the product async
multiplexer, while `mixed-transfer-smoke` exercises one product-async download, one product-async
upload, and heartbeat without changing the ordinary commands' established behavior.

Current M1 ADB harness state:

- `download` opens one download transfer on the existing framed TCP session.
- `dual-download-smoke` opens two download transfers before consuming either one,
  routes open responses and chunks by request/stream ID, then services one buffered
  chunk per stream in turn. A heartbeat must complete after both streams open and
  before either first chunk is acknowledged, proving that active data streams do
  not starve the control plane.
- `mixed-transfer-smoke` owns a fresh async session, opens the download and upload
  handles first, and requires heartbeat before download has ACKed or upload has
  sent a chunk. It then concurrently runs atomic receive and shared windowed file
  upload through the single reader. Success requires both final ACKs, a stable-source
  recheck, local/report byte agreement in the device script, and the echoed
  heartbeat. Like the ordinary product/harness upload
  paths, its inactive-side upload `source_path` is the shared opaque label
  `mac-local-upload`, not a Mac path or personal file name.
- Android permits at most two active transfer streams per session across download
  and upload directions. A third valid open receives
  `ERROR_CODE_UNSUPPORTED_CAPABILITY`; invalid direction and missing capability
  errors are resolved before the concurrency limit is considered.
- Active transfer IDs are unique within a session across both directions. A duplicate
  ID receives `ERROR_CODE_ALREADY_EXISTS` before the concurrency limit, so cancel
  and pause never select an arbitrary stream.
- Android replies with `OpenTransferResponse` followed by one `TransferChunk` on `stream_id = request_id`.
- The Mac harness validates the stream id, chunk offset, transfer id, and CRC32, writes the chunk, then sends one `TransferChunkAck`.
- Each non-final ACK advances the receiver checkpoint. Android keeps a small per-stream
  send window filled after the first ACK, up to the M1 backpressure cap of 4 chunks
  or 2 MiB in flight, whichever limit is reached first.
- `download-open-expect-error` opens a download path and requires a typed remote open error, so matrix runs can record stable missing-source or permission failures without writing local files.
- `download-cancel` validates the same open + first chunk path, then sends `CancelTransferRequest`; Android closes the active reader, removes the transfer state, and returns `CancelTransferResponse.ok = true`. The same handler also releases an active upload writer; resumable providers retain their partial according to provider policy.
- `download-pause` validates open + first chunk, then sends `PauseTransferRequest`; Android closes the active reader, removes the transfer state, and returns `PauseTransferResponse.ok = true` with the last ACKed offset. Sent-but-unacknowledged window data never advances this safe resume boundary.
- `upload` opens a `TRANSFER_DIRECTION_UPLOAD` transfer to `dm://app-sandbox/<file>`, a MediaStore destination, or a writable `dm://saf-.../` destination, then the Mac harness sends windowed `TransferChunk` frames and uses Android `TransferChunkAck` frames to refill the send window. Android app-sandbox upload writes to a hidden partial file and replaces the destination only after the final chunk is accepted; fresh MediaStore upload inserts a pending image/video row and deletes it on non-final close; fresh SAF upload creates a document in the target directory and deletes it on non-final close.
- Android keeps the provider read stream open across ACK-driven chunks, so sequential download chunks do not repeatedly reopen the source. When the provider exposes a seekable file descriptor, Android positions it once at the accepted resume offset; otherwise it falls back to opening an input stream once and skipping to that offset before streaming forward.
- `download --resume` reads a sidecar source fingerprint and requests the current local file size as `requested_offset_bytes`.
- Android rejects non-zero resume requests without a source fingerprint or when size, modified time, provider etag, or SHA-256 no longer match.
- `upload --resume` reads a local sidecar for source path, destination path, source modified time, total size, transfer id, and next offset, then requests that offset. Android accepts the offset only when the destination provider can reconcile its hidden partial file to the requested offset.
- Android passes `OpenTransferRequest.transfer_id` into the upload provider layer. SAF upload resume keys hidden partial documents by this transfer id rather than a user-visible display name.
- `download --retry-on-transport-loss` and app-sandbox/SAF `upload --retry-on-transport-loss` wrap the same sidecar resume path with automatic reconnect after transport close/timeout or remote `transportLost`/`timeout`. The default remains one retry for backward compatibility; `--max-retry-attempts N` and `--retry-backoff-ms M` enable the configurable recovery queue.
- The device smoke script can route the retrying transfer through `tools/m1-fault-proxy.py`, which drops the first proxied transfer connection after the third server frame and requires the harness to finish with `recovered=true`. It forwards `--max-retry-attempts` and `--retry-backoff-ms` to the harness so real-device logs record the retry policy used.
- The same frame-aware proxy can run a one-shot hook after the first proxied server frames. `tools/run-m1-device-smoke.sh --media-permission-revoked-during-download-check` uses that hook to revoke Android media read permission during a MediaStore download, accepts either a completed download or an expected transport loss, records the outcome, and restores the prior media grants.
- App-sandbox upload resume can also tolerate an ACK-loss window: if Android's partial file is ahead of the Mac sidecar offset, Android truncates the partial back to `requested_offset_bytes` and accepts the resent chunk.
- Seekable SAF providers use the same durable-ACK reconciliation rule for their
  transfer-ID-keyed hidden partial. If the provider partial is ahead, Android
  opens a writable descriptor and truncates it to `requested_offset_bytes`
  before append/replay. A non-seekable provider fails with
  `UNSUPPORTED_CAPABILITY` instead of duplicating bytes. Slot C archives both
  the pre-fix mismatch and a recovered 10MiB rerun.
- The Mac harness reports transfer-local `elapsed_ms` and `throughput_mib_per_sec` for completed download/upload commands. `list-dir` also reports harness `elapsed_ms` for the handshake + ListDir RPC inside the already-launched harness process; `tools/run-m1-device-smoke.sh --max-list-ms` gates on that value and records command wall time separately. The device runner builds and invokes the harness with Swift's release configuration. Throughput assertions use `--min-download-mib-per-second 20` and `--min-upload-mib-per-second 20`; matrix runs should pass `--chunk-size-bytes 1048576` to request Android's current 1MiB negotiated chunk cap. A debug/Onone measurement is diagnostic only, and archived Slot A measurements made before the current transfer optimizations are not current-tip gate evidence. These are matrix evidence fields, not wire-protocol fields.
- This mode proves provider read path, app-sandbox write path, fresh MediaStore write path, fresh/resumable SAF write path, windowed download, multi-chunk wire shape in both directions, active cancel, active pause, download resume validation, app-sandbox/SAF upload resume, sidecar-backed transport retry with local fault injection, app-sandbox upload ACK-loss replay, and media permission revocation during listing and MediaStore download. The configurable recovery queue is covered by unit tests, exposed in real-device scripts, and wired into the Mac product UI with private per-device persistence and bookmark-backed file access. Dual-download routing remains opt-in through `--dual-download-check`; mixed-direction routing is independently runnable through `--mixed-transfer-check` plus a distinct `--mixed-upload-destination-path`. Local TCP coverage proves the full mixed command contract, but physical-device dual/mixed and sandboxed product-queue runs still need redacted archived evidence.

## Backpressure

- Senders must not exceed the negotiated `OpenTransferResponse.chunk_size_bytes`.
- Receivers may use `TransferChunkAck.next_offset_bytes` as a checkpoint and backpressure signal.
- M1 senders may have at most 4 chunks or 2 MiB of unacknowledged transfer data in flight per active transfer stream, whichever limit is reached first.
- A receiver should acknowledge at least every 4 chunks and must send a final `TransferChunkAck` before completion.
- A sender should pause chunk emission when the receiver stops acknowledging progress.
- A receiver that cannot persist data fast enough should return `ERROR_CODE_TIMEOUT` or a typed transfer error instead of buffering unbounded data.

`TransferChunk.data` is capped at 1 MiB even though the whole `RpcEnvelope` can be up to 4 MiB; the larger envelope limit exists for protobuf overhead and future non-chunk payloads.

## Transfer Windowing

M1 transfer windowing is symmetric to the backpressure limits above: the sender
may keep up to 4 chunks or 2 MiB of unacknowledged data in flight per stream,
whichever is reached first.

### Download Windowing (Android sender)

The Android `RpcDispatcher` pre-sends download chunks to fill the window on the
sender side (`fillDownloadWindow` + `DownloadTransfer`). The Mac client remains a
stop-and-wait receiver — it consumes one chunk, ACKs, and the server refills.
Each Android provider read now fills one exact negotiated-chunk buffer directly;
only an EOF-short final chunk is copied into a trimmed array. This removes the
old 64 KiB accumulator growth/copy loop without changing chunk size, CRC, offset,
or window semantics.
This raised Slot D download throughput from ~19 MiB/s (stop-and-wait) to
48.95 MiB/s.

### Upload Windowing (Mac sender)

The early Mac upload path used stop-and-wait (send one chunk,
block for ACK, repeat), capping throughput at `chunkSize / RTT` and yielding only
11.49 MiB/s on Slot D. Windowed upload is now archived at 33.51 MiB/s on the
same Slot D class with the 20 MiB/s gate enabled. It uses `UploadWindow` (in
`mac/Sources/DroidMatchCore/UploadWindow.swift`), a pure value type symmetric to
Android's `DownloadTransfer`:

The ACK-driven continuous-refill path is also archived on Slot C with an
incompressible 100 MiB source: 32.73 MiB/s at 256 KiB, 35.29 MiB/s at 512 KiB,
and 22.77 MiB/s at 1 MiB, all without changing the 4-chunk / 2 MiB bound.

- `maxInFlightChunks = 4`, `maxInFlightBytes = 2 MiB`.
- `canSendMore(chunkSizeBytes:remainingBytes:)` gates further sends.
- `recordSent` enqueues an outstanding chunk and advances `nextSendOffsetBytes`.
- `recordAck` pops the queue head, verifying `nextOffsetBytes` matches the head
  and `finalAck` is consistent with the head's `finalChunk` flag.

The async upload sender fills a bounded window from its serial file-source
boundary. After the oldest ACK is validated and its durable checkpoint callback
finishes, it reads and admits exactly one replacement chunk before awaiting the
next ACK. This keeps the same 4-chunk / 2 MiB limit continuously occupied instead
of draining a whole batch and leaving a refill bubble. No synchronous network
session remains.

The product-async path reuses the same `UploadWindow` limits. Its
`AsyncUploadTransfer.sendWindow` still preflights a fixed bounded batch before
sending any prefix. The file sender uses its refilling counterpart: initial
chunks are preflighted together, then each replacement is validated only after
one ordered ACK frees capacity. The multiplexer's sole reader retires ACK
waiters; a serial source cursor prevents competing reads. All multiplexed writes
share a cancellation-aware FIFO admission gate. After waiting for that gate but
before admitting bytes to the socket, a download ACK or upload chunk revalidates
the live route/window and consults the handle-shared first terminal error. A late
write therefore cannot survive route teardown, and recovery sees the original
retryable transport failure or typed remote failure rather than a secondary
inactive-route error. A checkpoint, source, validation, or send failure closes
the session because other frames may still be in flight. One handle owns one send
operation at a time, so correctness does not depend on sibling Swift task
scheduling. Protocol `cancelTransfer` wakes admitted ACK waiters after remote
confirmation; direct task cancellation after admission also closes the ambiguous
session.

Android parses the nested upload `TransferChunk` directly from the envelope's
protobuf `ByteString`, avoiding a second full chunk-sized `byte[]`. Its handler
still requires only `chunk.offsetBytes == transfer.nextOffsetBytes` (in-order
arrival), so the Mac sender emits chunks in offset order and Android ACKs each
one in sequence. This allocation change does not alter the wire format or the
strict 4-chunk / 2 MiB backpressure limit.

### Windowing Test Coverage

- `UploadWindowTests.swift`: 16 pure-logic tests covering `canSendMore` chunk
  and byte caps, zero-byte final chunks, negative remaining-byte rejection,
  `recordSent` offset advancement, `recordAck` queue-head matching and the four
  error paths (no outstanding, offset mismatch, final without final_ack,
  final_ack before final), and `finalChunkSent` gating.
- `FrameCodecTests.swift`: end-to-end tests using a generalized upload echo
  server verify that a payload larger than `maxInFlightChunks` fills four chunks
  before the first ACK, an empty upload still sends a zero-byte final chunk, and
  resume from a non-zero offset initializes the window correctly.
- `AsyncRpcMultiplexerTests.swift`: one local TCP session withholds upload ACKs
  until four chunks arrive, then releases only the oldest ACK and requires the
  sender to refill that single slot before the remaining ACKs are released. It
  also rejects a five-chunk batch during preflight, routes download and heartbeat
  traffic, then cancels a pending upload and proves session reuse.
- `AsyncUploadFileSenderTests.swift`: verifies the source cursor emits exactly
  one empty final chunk and limits initial read-ahead to 2 MiB before advancing
  one ACK-freed slot.

### Product-Async Atomic Download Receive

`AsyncDownloadTransfer.receive(to:resume:)` owns the product download
chunk/write/ACK loop. It creates a sibling `.droidmatch-part` through
`AsyncAtomicDownloadWriter`, whose blocking Foundation operations run on one
private serial Dispatch queue rather than a cooperative Swift executor.

- The scheduler reads `AtomicDownloadWriter.requestedOffsetBytes` before open and
  supplies that offset plus the saved source fingerprint to `openDownload`.
- The receiver rechecks local partial length against
  `OpenTransferResponse.acceptedOffsetBytes` before consuming a queued chunk.
  A mismatch cancels that transfer, preserves both files, and leaves the session
  usable for later control requests.
- Each validated chunk is written before its ACK. The existing destination is
  untouched until the final chunk ACK has been sent and the partial file commits.
- Protocol cancellation closes the writer and retains the partial file. Direct
  task cancellation before ACK closes the ambiguous session, so a later attempt
  resumes from the actual on-disk partial length.
- A commit failure after final ACK returns the file error without poisoning the
  already-correlated multiplexed session; the prior destination remains protected
  by `AtomicDownloadWriter` semantics.

Local TCP coverage places a barrier after the first download ACK and verifies the
old destination plus one-chunk partial before releasing refill. It also verifies
cancelled partial retention, post-cancel heartbeat reuse, changed resume-offset
rejection, and that buffered chunks are not observable after cancellation.

## Directory Listing Runtime

- M1 smoke starts with `ListDirRequest.path = "dm://roots/"`, a virtual
  read-only directory that returns available provider roots.
- The Mac harness can also run `ListDirRequest` against `dm://media-images/`
  and `dm://media-videos/`; these roots return flat MediaStore item pages.
- User-selected SAF roots appear as `dm://saf-.../` paths after Android has a
  persisted tree URI permission. SAF child paths use Android-local opaque
  tokens and never place raw `content://` values or document IDs on the wire.
- `ListDirRequest.page_size = 0` means provider default.
- Providers should default to 200 entries and cap at 1,000 entries.
- `page_token` is opaque, tied to query parameters, and invalidated by permission changes or mutations.
- Large directories should return partial pages instead of trying to sort or materialize every entry at once when the provider API allows it.
- Recursive tree walking is out of scope for `ListDir`; future search/index APIs should own recursion.
- Mac product code uses `DirectoryListingQuery` rather than protobuf types. It
  always sends an explicit 1...1,000 page size, returns provider tokens unchanged,
  maps embedded provider errors without retaining their message/details, and
  validates stable `dm://` row identity, supported kind,
  page-local path uniqueness, and immediate token repetition. Negative provider
  size, non-file size (including proto-default zero), zero timestamp, and an
  empty provider name are unknown metadata (`nil`), not protocol errors.
- `DirectoryBrowserModel` serializes page requests on MainActor. Navigation clears
  the previous directory immediately; refresh preserves old rows until the first
  replacement page succeeds; load-more failure preserves rows and its token for
  retry. A generation guard rejects non-cooperative late responses after path or
  refresh changes. Cross-page duplicate paths are filtered because offset-backed
  providers may mutate at a page boundary, while a token cycle fails without
  appending the suspect page. Device names remain display state and never enter
  structured failure values or logs.

## Resume Validation

Resume is allowed only when the source fingerprint still matches the original source.

- Size mismatch rejects resume.
- Modified-time mismatch rejects resume unless an opaque provider etag still matches.
- Optional SHA-256 mismatch rejects resume.
- If no fingerprint is available, providers may resume only when the destination offset is zero or when the source provider can otherwise prove stability.

Resume rejection should use `ERROR_CODE_INVALID_ARGUMENT` for stale offsets or `ERROR_CODE_NOT_FOUND` when the source disappeared.

For app-sandbox upload resume, Android validates the destination partial state instead of a remote source fingerprint:

- Missing partial file rejects non-zero upload resume with `ERROR_CODE_NOT_FOUND`.
- Partial length shorter than the requested offset rejects with `ERROR_CODE_INVALID_ARGUMENT`.
- Partial length longer than the requested offset is truncated back to the requested offset so a chunk that was written but not ACKed to Mac can be replayed.
- Fresh upload at offset 0 removes any stale hidden partial before writing new chunks.

MediaStore upload in M1 is fresh-only:

- Image upload destinations use `dm://media-images/<display-name>`.
- Video upload destinations use `dm://media-videos/<display-name>`.
- Android 10+ creates image rows under `Pictures/DroidMatch/` and video rows under `Movies/DroidMatch/` with `IS_PENDING = 1`, then publishes with `IS_PENDING = 0` after the final chunk is committed.
- Non-final close, open failure, or write failure should delete the inserted MediaStore row so failed smoke runs do not leave pending artifacts.
- Non-zero MediaStore upload offsets reject with `ERROR_CODE_UNSUPPORTED_CAPABILITY`.
- The harness command `upload-open-expect-error` and device-script flag `--upload-resume-unsupported-check` exist to record that fresh-only boundary without sending any upload chunks after the rejected open.
- The harness command `list-dir-expect-error` and device-script flags `--list-expect-error-path` / `--list-expect-error-code` exist to record stable listing failures such as permission-required roots or missing SAF roots without treating the run as a harness failure.
- The device-script flag `--media-permission-revoked-check` revokes media read permission after baseline `m1-smoke`, restarts the debug harness endpoint because Android may kill the app process on runtime permission changes, requires a media root `ListDir` permission error, and restores the media runtime grants that were present before the check. This records "permission revoked during listing" without requiring manual Settings navigation on a debug device.
- The device-script flag `--media-permission-revoked-during-download-check` routes a MediaStore download through the fault proxy, revokes media read permission after the first proxied server frames, then restores the prior grants. Provider stream readers normalize chunk-time `SecurityException` to `ERROR_CODE_PERMISSION_REQUIRED` for MediaStore/SAF and `ERROR_CODE_INTERNAL` for app-sandbox without leaking provider details. This mapping is used when the dispatcher can return an error frame; runtime permission mutation may instead tear down the Android endpoint first, so `transport_lost_after_revoke` remains valid rather than being promoted to a cross-device typed-error guarantee. Slot D and the post-fix Slot C 10MiB rerun both archive transport loss; Slot C restored grants, and a subsequent archived cleanup check found zero rows for the exact disposable upload name and zero default local download/partial/sidecar artifacts.
- The harness command `download-open-expect-error` and device-script flags `--download-open-expect-error-path` / `--download-open-expect-error-code` exist to record stable download-open failures such as missing sources or permission-required provider files without treating the run as a harness failure.
- `upload --retry-on-transport-loss` is intentionally rejected for MediaStore destinations because retry depends on a resumable partial destination.

SAF upload in M1 supports fresh and resume:

- Root upload destinations use `dm://saf-<stable-id>/<display-name>`.
- Listed SAF directory upload destinations use `dm://saf-<stable-id>/doc/<directory-token>/<display-name>`.
- RPC fresh upload creates a hidden partial document whose display name is derived from `transfer_id`, parent document id, and requested final display name.
- Non-final close keeps the partial document so a later `upload --resume` can continue at the sidecar offset.
- Non-zero SAF upload offsets require a non-empty `transfer_id`, an existing partial document, and a partial size that equals `requested_offset_bytes`.
- Final chunk renames the partial document to the requested final display name.

## Transport-Loss Retry

The Mac M1 harness retry path is driven by a `RecoveryPolicy` value type in
`DroidMatchCore`. The policy decides *whether* to retry and *how long* to wait;
the harness download/upload loops perform the reconnect, reload the sidecar, and
reissue `OpenTransferRequest` on each attempt.

- `--retry-on-transport-loss` without further flags reproduces the legacy
  "retry at most once" behaviour via `RecoveryPolicy.defaultSingleRetry`
  (`maxAttempts = 1`, `baseDelayMs = 500`, no jitter).
- `--retry-on-transport-loss --max-retry-attempts N` enables the full recovery
  queue: up to `N` additional reconnect attempts, each preceded by exponential
  backoff `baseDelayMs * 2^(attempt - 1)` capped at 30 s.
- `--retry-backoff-ms M` overrides the base backoff (default 500 ms). Harness
  backoff is jitter-free so matrix `backoff_ms` values are reproducible; jitter
  is reserved for future concurrent multi-stream retries.
- `--max-retry-attempts 0` is equivalent to not passing `--retry-on-transport-loss`.
- A retry is allowed only when (a) the policy still permits attempts, (b) the
  error is a retryable transport condition (`connectionClosed`/`connectionFailed`/
  `timedOut`, or remote `transportLost`/`timeout`), and (c) a resume sidecar is
  still present on disk.
- The retry opens a new TCP session, sends a fresh `ClientHello`, reloads the
  sidecar, and reissues `OpenTransferRequest` with the same durable transfer
  metadata.
- Download retry uses the current `.droidmatch-part` length as
  `requested_offset_bytes` and sends the original source fingerprint.
- Upload retry is limited to app-sandbox and SAF destinations. It uses the
  sidecar transfer id and `next_offset_bytes`; this is the last offset Mac has
  durably observed from `TransferChunkAck`.
- `tools/run-m1-device-smoke.sh --download-retry-fault-check` and
  `--upload-retry-fault-check` start a local frame-aware proxy between the
  harness and the ADB forward. The proxy forwards the first connection through
  server hello, open response, and first transfer chunk/ack, then closes it so
  the second harness connection must resume from sidecar state.
- Add `--max-retry-attempts N` to the smoke script to record a non-default
  retry cap in the device log; add `--retry-backoff-ms M` to override the
  base exponential backoff used between reconnect attempts.
- `--upload-retry-ack-loss-check` uses the same proxy but reads and drops the
  first upload ACK instead of forwarding it. For app-sandbox uploads this proves
  Android can truncate its partial file to the Mac sidecar offset and accept the
  resent chunk.
- SAF upload still requires exact partial length on resume because Android's SAF
  write APIs do not expose a portable truncate primitive in this harness. A
  later scheduler should reconcile remote and local checkpoints before marking
  full SAF cable-unplug recovery complete.

The product download path uses the async counterpart of the same policy:

- `AsyncDownloadCoordinator` receives a client factory; each attempt therefore
  gets a fresh TCP session and repeats the configured handshake/authentication.
- `DownloadResumeRecord` and `UploadResumeRecord` are shared Core schemas. Their
  camelCase JSON keys remain compatible with sidecars written by the CLI.
- Before each open, `AsyncTransferResumeStore` serially reloads the sidecar and
  actual `.droidmatch-part` length. Resume sends the same transfer ID and accepted
  source fingerprint; changed fingerprint/total size, corrupt sidecar, or an
  orphaned non-empty partial is terminal.
- After transport loss, the cancellable async recovery executor applies the same
  attempt cap and exponential backoff. The local TCP test drops the first session
  after offset 2 and verifies the second open resumes at 2, commits `recover`, and
  removes both checkpoint files.
- `AsyncUploadCoordinator` applies the same injected-client boundary to uploads.
  `AsyncUploadFileSource` owns blocking reads and validates size, mtime, filesystem,
  and inode around each read. Four-chunk/two-MiB windows expose every ordered ACK
  to the coordinator, which atomically advances `nextOffsetBytes` before refilling.
- The upload fault test sends offsets 0...8 in the first window, forwards only the
  ACK for offset 2, and closes the connection. The second open must reuse the
  transfer ID at offset 2; replay plus app-sandbox rollback produces the original
  ten bytes, then removes the sidecar. Direct task cancellation instead keeps the
  offset-2 checkpoint and does not start another attempt.
- Product automatic upload recovery remains limited to app-sandbox and SAF. SAF
  still needs an exact remote partial checkpoint, while app-sandbox can truncate
  sent-but-unacknowledged bytes to the Mac sidecar offset. MediaStore stays fresh-only.

### Product Transfer Scheduler

`AsyncTransferScheduler` is the queue layer above both coordinators. Its ordinary
initializer is process-local; persistence is explicitly opt-in and does not
change wire semantics:

- Requests are admitted FIFO with two running jobs by default; a third job stays
  queued until a slot is released.
- A buffering-newest `AsyncStream` publishes ordered full snapshots for
  queued/running/retrying/pausing/paused/completed/failed/cancelled/interrupted state. Retry snapshots expose
  the next attempt number, backoff, and last failure description. Each snapshot
  also exposes absolute `confirmedBytes`, optional `totalBytes`, and a fraction
  when the total is positive; terminal state identifies a completed empty file.
  `canPause`, `canResume`, `canCancel`, and `canRemove` keep action policy out
  of views. `canRemove` stays false until a terminal outcome is settled and any
  cancelled executor has actually unwound.
- Progress never means merely sent or buffered bytes. Download progress follows
  partial write + ACK, and upload progress follows remote ACK plus the local
  sidecar commit for resumable targets. Final 100% follows destination/source
  validation and obsolete-sidecar cleanup.
- Progress is monotonic across reconnects and must retain one total size. Retry
  delivery is ordered before immediate reconnect progress, while stale, regressing,
  changed-total, out-of-range, and post-cancellation updates are ignored.
- `recentBytesPerSecond` is a local two-second, time-weighted window over those
  confirmed offsets using monotonic uptime. Retry clears it, a confirmation gap
  longer than the window starts a new baseline, an active stall publishes nil,
  and a terminal transition retains any still-valid sample. It is not the
  unimplemented wire `TransferProgress` event.
- Cancelling queued work never invokes a coordinator. Cancelling running/retrying
  work cancels the owning Swift task, so coordinator cancellation rules preserve
  the appropriate download partial or upload ACK checkpoint.
- Pausing queued work is a pure hold. Running checkpoint pause is accepted only
  after trusted progress exists and before 100% for downloads and resume-capable
  app-sandbox/SAF uploads. It enters `pausing`, cancels the coordinator's exclusive
  session, retains the partial/sidecar, and becomes `paused` only after unwind.
  Resume keeps the scheduler job and transfer IDs, converts the request to
  `resume = true`, preserves monotonic attempt numbering, and appends it to the
  FIFO tail. Completion waiters span the pause. MediaStore upload is fresh-only
  and cannot use this path.
- Scheduler checkpoint pause does not send `PauseTransferRequest`: the current
  Android wire implementation remains download-only, while the local close/reopen
  policy is symmetric only where durable resume is already supported.
- Terminal outcomes remain awaitable and may be removed. A running task that has
  been marked cancelled cannot be removed until its executor actually unwinds.
- `TransferQueuePersistenceStore` writes a schema-versioned full manifest
  atomically. It assigns 0600 to the manifest and 0700 only to directories it
  creates; it never changes an existing parent directory. Local paths remain
  necessary recovery data but never appear in public store errors.
- `AsyncTransferScheduler.restoring(...)` reconstructs stable UUID/FIFO intent,
  then writes the normalized manifest before admitting queued executors. Every
  queued-to-active transition is also committed before the task starts. A write
  failure keeps the task stopped or rejects pause/cancel before their task-side
  effects and publishes coarse `writeFailed` health for presentation/diagnostics.
- An active download or app-sandbox/SAF upload restores as paused only when its
  sidecar decodes and matches the persisted paths. Missing/corrupt checkpoints
  and all active fresh-only MediaStore uploads restore as persistent
  `interrupted`; that state cannot resume and requires remove/re-submit, so a
  stale manifest can never silently duplicate a completed or fresh-only upload.
- Corrupt or unknown-version queue files are preserved and make restoration
  throw. Core does not guess whether product code should quarantine or discard
  user recovery state. The existing app target must supply its owned file URL and
  reacquire sandboxed local-file access; Core does not fabricate bookmarks.
- `DroidMatchPresentation.TransferQueueModel` now maps this stream on MainActor,
  keeps scheduler order and action authority, and strips local paths to basenames.
  It does not expose the raw failure description because Core file errors may
  contain absolute paths. It separately publishes the coarse persistence health.
  The visual app target exists, but queue/session lifecycle wiring is still separate product work.

### Recovery Policy Test Coverage

`RecoveryPolicy` and the `runTransferWithRecovery` executor are unit-tested in
`RecoveryPolicyTests.swift`:

- Pure-logic tests: attempt counting, exponential backoff doubling, `maxDelayMs`
  cap, jitter bounds, legacy single-retry default, disabled policy.
- Executor tests: multi-attempt recovery until success with backoff timing,
  attempt-cap exhaustion throwing the last error, non-retryable error
  short-circuit, `canResume == false` short-circuit, `onRetry` callback
  visibility.
- End-to-end tests in `FrameCodecTests.swift`: a `LocalFrameTestServer` that
  drops the first N connections after `ServerHello` proves the recovery queue
  completes a multi-chunk download after two transport losses, and that
  attempt-cap exhaustion surfaces the final transport error.

## Harness Cleanup Semantics

`tools/run-m1-device-smoke.sh --cleanup-upload-destination` is a harness convenience, not a protocol mutation:

- App-sandbox upload cleanup removes the app-private destination with `run-as app.droidmatch rm` after the smoke run.
- MediaStore upload cleanup uses Android's `content delete` CLI against the image or video collection. For Android 10+ it matches both `_display_name` and the DroidMatch relative path (`Pictures/DroidMatch/` or `Movies/DroidMatch/`) to avoid deleting unrelated media with the same display name.
- The script only accepts MediaStore cleanup for a single display-name segment under the root and rejects names containing `'`, because the adb `content` tool accepts a SQL-style where clause.
- SAF upload cleanup is intentionally unsupported until DroidMatch has a protocol-level delete/mutation path; the harness must not remove files from a user-selected SAF directory by guessing provider behavior.

## Error Scenarios for M1 Harness

Already exercised:

- Android permission revoked during listing.
- Android media read permission revoked during MediaStore download; Slot D and the post-fix Slot C 10MiB regression observed expected `transport_lost_after_revoke` and restored grants. Slot C preserves the earlier failed run where a secondary inactive-route error masked the first failure, plus the passing rerun after send-admission revalidation.
- Android dispatcher unit tests reject download resume when the source fingerprint is missing, changed, or the source is no longer available.
- Android provider unit tests reject invalid or query-mismatched page tokens.
- Mac `FrameCodec` and Android `FramedIo` unit tests reject oversized envelopes before payload processing.
- Mac download and Android upload unit tests reject transfer chunks with bad CRC32.

Still to exercise:

- USB unplug during download.
- Physical USB unplug during upload is archived on Slot C: the original ADB
  forward disappeared, the Mac retained its durable sidecar, and a newly
  authorized device session plus new dynamic forward resumed the same 2GiB
  transfer to completion. This is a two-session recovery workflow; retrying the
  dead local forwarded port alone cannot survive physical USB removal.
- Permission mutation during SAF/provider variants beyond MediaStore download.
- Real-device source deletion before resume.
- Real-device source modification before resume.
- Destination becomes read-only.
- Destination runs out of space.
