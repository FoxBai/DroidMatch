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
- Each non-final ACK triggers the next chunk; only one chunk is in flight in this smoke path.
- `download-cancel` validates the same open + first chunk path, then sends `CancelTransferRequest`; Android closes the active reader, removes the transfer state, and returns `CancelTransferResponse.ok = true`.
- `download-pause` validates open + first chunk, then sends `PauseTransferRequest`; Android closes the active reader, removes the transfer state, and returns `PauseTransferResponse.ok = true` with the next resumable offset.
- `upload` opens a `TRANSFER_DIRECTION_UPLOAD` transfer to `dm://app-sandbox/<file>`, a MediaStore destination, or a writable `dm://saf-.../` destination, then the Mac harness sends receiver-paced `TransferChunk` frames and waits for Android `TransferChunkAck` frames before sending the next chunk. Android app-sandbox upload writes to a hidden partial file and replaces the destination only after the final chunk is accepted; fresh MediaStore upload inserts a pending image/video row and deletes it on non-final close; fresh SAF upload creates a document in the target directory and deletes it on non-final close.
- Android keeps the provider read stream open across ACK-driven chunks, so sequential download chunks do not repeatedly reopen the source. When the provider exposes a seekable file descriptor, Android positions it once at the accepted resume offset; otherwise it falls back to opening an input stream once and skipping to that offset before streaming forward.
- `download --resume` reads a sidecar source fingerprint and requests the current local file size as `requested_offset_bytes`.
- Android rejects non-zero resume requests without a source fingerprint or when size, modified time, provider etag, or SHA-256 no longer match.
- `upload --resume` reads a local sidecar for source path, destination path, source modified time, total size, transfer id, and next offset, then requests that offset. Android accepts the offset only when the hidden partial file exists and its length equals the requested offset.
- Android passes `OpenTransferRequest.transfer_id` into the upload provider layer. SAF upload resume keys hidden partial documents by this transfer id rather than a user-visible display name.
- `download --retry-on-transport-loss` and app-sandbox/SAF `upload --retry-on-transport-loss` wrap the same sidecar resume path with one automatic reconnect attempt after transport close/timeout or remote `transportLost`/`timeout`.
- The device smoke script can route the retrying transfer through `tools/m1-fault-proxy.py`, which drops the first proxied transfer connection after the third server frame and requires the harness to finish with `recovered=true`.
- This mode proves provider read path, app-sandbox write path, fresh MediaStore write path, fresh/resumable SAF write path, multi-chunk wire shape in both directions, active cancel, active pause, download resume validation, app-sandbox/SAF upload resume, and one sidecar-backed transport retry with local fault injection; the full recovery queue and multi-stream scheduling remain part of the M1 device matrix.

## Backpressure

- Senders must not exceed the negotiated `OpenTransferResponse.chunk_size_bytes`.
- Receivers may use `TransferChunkAck.next_offset_bytes` as a checkpoint and backpressure signal.
- M1 senders may have at most 4 chunks or 2 MiB of unacknowledged transfer data in flight per active transfer stream, whichever limit is reached first.
- A receiver should acknowledge at least every 4 chunks and must send a final `TransferChunkAck` before completion.
- A sender should pause chunk emission when the receiver stops acknowledging progress.
- A receiver that cannot persist data fast enough should return `ERROR_CODE_TIMEOUT` or a typed transfer error instead of buffering unbounded data.

`TransferChunk.data` is capped at 1 MiB even though the whole `RpcEnvelope` can be up to 4 MiB; the larger envelope limit exists for protobuf overhead and future non-chunk payloads.

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
- Partial length mismatch rejects the requested offset with `ERROR_CODE_INVALID_ARGUMENT`.
- Fresh upload at offset 0 removes any stale hidden partial before writing new chunks.

MediaStore upload in M1 is fresh-only:

- Image upload destinations use `dm://media-images/<display-name>`.
- Video upload destinations use `dm://media-videos/<display-name>`.
- Android 10+ creates image rows under `Pictures/DroidMatch/` and video rows under `Movies/DroidMatch/` with `IS_PENDING = 1`, then publishes with `IS_PENDING = 0` after the final chunk is committed.
- Non-final close, open failure, or write failure should delete the inserted MediaStore row so failed smoke runs do not leave pending artifacts.
- Non-zero MediaStore upload offsets reject with `ERROR_CODE_UNSUPPORTED_CAPABILITY`.
- The harness command `upload-open-expect-error` and device-script flag `--upload-resume-unsupported-check` exist to record that fresh-only boundary without sending any upload chunks after the rejected open.
- `upload --retry-on-transport-loss` is intentionally rejected for MediaStore destinations because retry depends on a resumable partial destination.

SAF upload in M1 supports fresh and resume:

- Root upload destinations use `dm://saf-<stable-id>/<display-name>`.
- Listed SAF directory upload destinations use `dm://saf-<stable-id>/doc/<directory-token>/<display-name>`.
- RPC fresh upload creates a hidden partial document whose display name is derived from `transfer_id`, parent document id, and requested final display name.
- Non-final close keeps the partial document so a later `upload --resume` can continue at the sidecar offset.
- Non-zero SAF upload offsets require a non-empty `transfer_id`, an existing partial document, and a partial size that equals `requested_offset_bytes`.
- Final chunk renames the partial document to the requested final display name.

## Transport-Loss Retry

The Mac M1 harness retry path is intentionally narrow:

- `--retry-on-transport-loss` retries at most once and only after the first attempt has written a resume sidecar.
- The retry opens a new TCP session, sends a fresh `ClientHello`, reloads the sidecar, and reissues `OpenTransferRequest` with the same durable transfer metadata.
- Download retry uses the current `.droidmatch-part` length as `requested_offset_bytes` and sends the original source fingerprint.
- Upload retry is limited to app-sandbox and SAF destinations. It uses the sidecar transfer id and `next_offset_bytes`; this is the last offset Mac has durably observed from `TransferChunkAck`.
- `tools/run-m1-device-smoke.sh --download-retry-fault-check` and `--upload-retry-fault-check` start a local frame-aware proxy between the harness and the ADB forward. The proxy forwards the first connection through server hello, open response, and first transfer chunk/ack, then closes it so the second harness connection must resume from sidecar state.
- If upload transport loss happens after Android writes a chunk but before Mac receives and saves the ACK, the next retry can still fail with a partial-length mismatch. A later scheduler should reconcile remote and local checkpoints before marking this full cable-unplug recovery complete.

## Harness Cleanup Semantics

`tools/run-m1-device-smoke.sh --cleanup-upload-destination` is a harness convenience, not a protocol mutation:

- App-sandbox upload cleanup removes the app-private destination with `run-as app.droidmatch rm` after the smoke run.
- MediaStore upload cleanup uses Android's `content delete` CLI against the image or video collection. For Android 10+ it matches both `_display_name` and the DroidMatch relative path (`Pictures/DroidMatch/` or `Movies/DroidMatch/`) to avoid deleting unrelated media with the same display name.
- The script only accepts MediaStore cleanup for a single display-name segment under the root and rejects names containing `'`, because the adb `content` tool accepts a SQL-style where clause.
- SAF upload cleanup is intentionally unsupported until DroidMatch has a protocol-level delete/mutation path; the harness must not remove files from a user-selected SAF directory by guessing provider behavior.

## Error Scenarios for M1 Harness

M1 should explicitly exercise:

- USB unplug during download.
- USB unplug during upload.
- Android permission revoked during listing.
- Android permission revoked during transfer.
- Source file deleted before resume.
- Source file modified before resume.
- Destination becomes read-only.
- Destination runs out of space.
- Invalid page token.
- Oversized envelope.
- Bad payload CRC.
