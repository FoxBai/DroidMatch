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
- `upload` opens a `TRANSFER_DIRECTION_UPLOAD` transfer to `dm://app-sandbox/<file>`, then the Mac harness sends receiver-paced `TransferChunk` frames and waits for Android `TransferChunkAck` frames before sending the next chunk. Android writes to a hidden app-sandbox partial file and replaces the destination only after the final chunk is accepted.
- Android keeps the provider read stream open across ACK-driven chunks, so sequential download chunks do not repeatedly reopen the source. When the provider exposes a seekable file descriptor, Android positions it once at the accepted resume offset; otherwise it falls back to opening an input stream once and skipping to that offset before streaming forward.
- `download --resume` reads a sidecar source fingerprint and requests the current local file size as `requested_offset_bytes`.
- Android rejects non-zero resume requests without a source fingerprint or when size, modified time, provider etag, or SHA-256 no longer match.
- `upload --resume` reads a local sidecar for source path, destination path, source modified time, total size, transfer id, and next offset, then requests that offset. Android accepts the offset only when the hidden partial file exists and its length equals the requested offset.
- This mode proves provider read path, app-sandbox write path, multi-chunk wire shape in both directions, active cancel, active pause, download resume validation, and app-sandbox upload resume; SAF/MediaStore upload, automatic retry, and multi-stream scheduling remain part of the M1 device matrix.

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
