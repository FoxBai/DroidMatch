# Protocol Runtime

This document records M1 runtime limits and scheduling rules that are not obvious from Protobuf schemas alone.

## Envelope Limits

- ADB M1 frames use `uint32_be envelope_length` followed by serialized `RpcEnvelope`.
- `envelope_length` must be greater than `0`.
- Maximum `envelope_length` is 4 MiB.
- Receivers must reject oversized or truncated envelopes with `ERROR_CODE_PROTOCOL_ERROR`.
- `payload_crc32` is optional for ADB M1 and recommended for AOA before it moves beyond experimental.

## Request Scheduling

M1 has one control-plane queue and one data-plane queue per active session.

- Handshake, heartbeat, cancel, pause, diagnostics, and permission-state requests have control priority.
- Directory listing and file mutation are normal control-plane work.
- Transfer chunks are data-plane work and must not block control-plane reads.
- Receivers should process cancel and pause requests even when transfer data is queued.

Control-plane starvation is a bug. If the Mac harness cannot get a heartbeat or cancel response while a transfer is active, M1 should fail that run.

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

The harness may run a single-transfer mode first. Multiple streams are included so the scheduler shape is clear before product UI work begins.

Current M1 ADB harness state:

- `download` opens one download transfer on the existing framed TCP session.
- Android replies with `OpenTransferResponse` followed by one `TransferChunk` on `stream_id = request_id`.
- The Mac harness validates the stream id, chunk offset, transfer id, and CRC32, writes the chunk, then sends one `TransferChunkAck`.
- Each non-final ACK advances the receiver checkpoint. Android keeps a small per-stream
  send window filled after the first ACK, up to the M1 backpressure cap of 4 chunks
  or 2 MiB in flight, whichever limit is reached first.
- `download-open-expect-error` opens a download path and requires a typed remote open error, so matrix runs can record stable missing-source or permission failures without writing local files.
- `download-cancel` validates the same open + first chunk path, then sends `CancelTransferRequest`; Android closes the active reader, removes the transfer state, and returns `CancelTransferResponse.ok = true`.
- `download-pause` validates open + first chunk, then sends `PauseTransferRequest`; Android closes the active reader, removes the transfer state, and returns `PauseTransferResponse.ok = true` with the next resumable offset.
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
- The Mac harness reports transfer-local `elapsed_ms` and `throughput_mib_per_sec` for completed download/upload commands. `list-dir` also reports harness `elapsed_ms` for the handshake + ListDir RPC inside the already-launched harness process; `tools/run-m1-device-smoke.sh --max-list-ms` gates on that value and records command wall time separately. Throughput assertions use `--min-download-mib-per-second` or `--min-upload-mib-per-second`; matrix throughput runs should pass `--chunk-size-bytes 1048576` to request Android's current 1MiB negotiated chunk cap. These are matrix evidence fields, not wire-protocol fields.
- This mode proves provider read path, app-sandbox write path, fresh MediaStore write path, fresh/resumable SAF write path, windowed download, multi-chunk wire shape in both directions, active cancel, active pause, download resume validation, app-sandbox/SAF upload resume, sidecar-backed transport retry with local fault injection, app-sandbox upload ACK-loss replay, and media permission revocation during listing and MediaStore download. The configurable recovery queue is covered by unit tests and exposed in real-device scripts; multi-stream scheduling remains part of the M1 device matrix.

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
This raised Slot D download throughput from ~19 MiB/s (stop-and-wait) to
48.95 MiB/s.

### Upload Windowing (Mac sender)

The Mac `RpcControlClient.upload` previously used stop-and-wait (send one chunk,
block for ACK, repeat), capping throughput at `chunkSize / RTT` and yielding only
11.49 MiB/s on Slot D. Windowed upload is now archived at 33.51 MiB/s on the
same Slot D class with the 20 MiB/s gate enabled. It uses `UploadWindow` (in
`mac/Sources/DroidMatchCore/UploadWindow.swift`), a pure value type symmetric to
Android's `DownloadTransfer`:

- `maxInFlightChunks = 4`, `maxInFlightBytes = 2 MiB`.
- `canSendMore(chunkSizeBytes:remainingBytes:)` gates further sends.
- `recordSent` enqueues an outstanding chunk and advances `nextSendOffsetBytes`.
- `recordAck` pops the queue head, verifying `nextOffsetBytes` matches the head
  and `finalAck` is consistent with the head's `finalChunk` flag.

The upload loop runs in a single thread: it fills the window with synchronous
`sendTransferChunk` calls (each returns once the bytes are in the kernel send
buffer), then blocks for one ACK, then refills. No send/receive concurrency is
needed because `FramedTcpSession.sendPayload` is synchronous.

Android's `handleTransferChunk` only requires `chunk.offsetBytes ==
transfer.nextOffsetBytes` (in-order arrival), so it accepts windowed upload
without modification — the Mac sender emits chunks in offset order and Android
ACKs each one in sequence.

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
- The device-script flag `--media-permission-revoked-during-download-check` routes a MediaStore download through the fault proxy, revokes media read permission after the first proxied server frames, then restores the prior grants. Slot D NIO N2301 currently records this as `transport_lost_after_revoke`, which is accepted because runtime permission mutation can tear down the Android endpoint.
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
- Android media read permission revoked during MediaStore download; Slot D observed expected `transport_lost_after_revoke` and restored grants.
- Android dispatcher unit tests reject download resume when the source fingerprint is missing, changed, or the source is no longer available.

Still to exercise:

- USB unplug during download.
- USB unplug during upload.
- Permission mutation during SAF/provider variants beyond MediaStore download.
- Real-device source deletion before resume.
- Real-device source modification before resume.
- Destination becomes read-only.
- Destination runs out of space.
- Invalid page token.
- Oversized envelope.
- Bad payload CRC.
