# Protocol

## Baseline

DroidMatch uses Protobuf for schema definitions. Transports may choose different carriers, but the semantic model must stay shared.

M1 messages live in `proto/v1/`:

- `error.proto`
- `rpc.proto`
- `session.proto`
- `device.proto`
- `file.proto`
- `transfer.proto`

M1 does not require gRPC. The first harness should use a lightweight framed Protobuf envelope so ADB and AOA can share request, response, stream, error, timeout, and cancellation semantics.

## Frame Envelope

The canonical M1 envelope is `RpcEnvelope` in `proto/v1/rpc.proto`.

For the ADB M1 harness, encode each envelope as:

```text
uint32_be envelope_length
bytes     serialized RpcEnvelope
```

`envelope_length` must be greater than `0` and no larger than 4 MiB. M1 receivers must reject oversized envelopes with `ERROR_CODE_PROTOCOL_ERROR`.

AOA may later use a fixed binary header for lower overhead, but it must preserve the same semantic fields:

| Field | Purpose |
|---|---|
| `frame_version` | Envelope format version. M1 uses `1`. |
| `kind` | Request, response, event, stream, error, or cancel. |
| `flags` | Reserved bitset. M1 senders must write `0`; receivers must ignore unknown bits. |
| `request_id` | Correlates request, response, error, and cancel frames. |
| `stream_id` | Correlates data-plane stream frames, especially transfer chunks. |
| `payload_type` | Identifies the serialized Protobuf message in `payload`. |
| `payload` | Serialized Protobuf message named by `payload_type`. |
| `timeout_millis` | Request deadline budget. `0` means use the operation default. |
| `error` | Populated on `RPC_FRAME_KIND_ERROR` or typed responses that need an embedded error. |
| `payload_crc32` | Optional CRC32 over `payload`, enabled by flag bit 0. |

`PayloadType` is the registry for M1 messages. Unknown payload types must produce `ERROR_CODE_UNSUPPORTED_CAPABILITY` if the capability is absent, or `ERROR_CODE_PROTOCOL_ERROR` if the sender violated the negotiated protocol.

M1 flag bits:

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `payload_crc32_present` | Receiver validates `payload_crc32` before parsing `payload`. |

ADB M1 may omit `payload_crc32` and rely on TCP plus transfer chunk CRCs. AOA should set `payload_crc32_present` before it moves beyond experimental, because control-plane messages do not all carry their own chunk checksum.

Receivers must ignore `payload_crc32` when `payload_crc32_present` is not set. Senders should write `payload_crc32 = 0` when the flag is absent.

## Request IDs and Stream IDs

- `request_id = 0` is invalid for request, response, error, and cancel frames.
- Each side generates monotonically increasing `request_id` values for requests it sends during a session.
- A response, error, or RPC cancel response must reuse the target request ID.
- Events that are not responses may use `request_id = 0` unless they belong to a specific request.
- `stream_id = 0` means no data-plane stream.
- Each active transfer stream uses a non-zero `stream_id` unique within the session.
- M1 transfer streams default to `stream_id = request_id` from the `OpenTransferRequest`; `OpenTransferResponse.stream_id` echoes the chosen value.
- Transfer payloads also carry `transfer_id`; `stream_id` routes bytes, while `transfer_id` identifies the durable transfer across pause, retry, and resume.
- A non-empty `transfer_id` may identify only one active stream in a session at a time, across both directions. A second open with the same active ID returns `ERROR_CODE_ALREADY_EXISTS`; this keeps transfer-level cancel/pause unambiguous.

## Handshake and Versioning

Handshake is the first control-plane request after the transport is reachable:

1. Mac sends `ClientHello`.
2. Android returns `ServerHello`.
3. Both sides require matching `protocol_major`.
4. The effective `protocol_minor` is the lower of both sides' minor versions.
5. In correlation-only M1 mode, capabilities are the reduced intersection of requested and supported capabilities.
6. Unsupported major versions return `ERROR_CODE_UNSUPPORTED_VERSION`.
7. Mac sends a fresh 32-byte `ClientHello.session_nonce`; Android validates and echoes it, and Mac rejects a mismatched `ServerHello.session_nonce`.

M1 protocol version is `1.0`.

`ClientHello` is valid only as the first request on a session. A request received before handshake completion returns `ERROR_CODE_UNAUTHORIZED`; a repeated `ClientHello` on an already-handshaken session returns `ERROR_CODE_PROTOCOL_ERROR`.

`ClientHello.session_nonce` must be 16 to 32 bytes; the Mac M1 clients generate 32 cryptographically random bytes for every TCP handshake. Android rejects shorter or longer values with `ERROR_CODE_PROTOCOL_ERROR` and copies the accepted bytes into `ServerHello.session_nonce`. Mac validates the returned length and exact equality. Implementations may log only validation state or byte length, never raw nonce bytes.

Nonce echo provides freshness and response correlation, not peer identity: an unrelated localhost process can create its own nonce and handshake.

Paired reconnection uses a second state transition:

1. Mac adds the non-secret 16-byte `ClientHello.pairing_id` and uses a 32-byte nonce.
2. Android echoes the client nonce, returns a fresh 32-byte `server_nonce` and its 32-byte stable device-identity fingerprint, sets `authentication_state = REQUIRED`, and grants no capabilities. The fingerprint selects a local pairing record; it is untrusted until the later server proof succeeds.
3. Mac sends `AuthenticateSessionRequest(pairing_id, client_proof)` where the proof is role-separated HMAC-SHA256 over the canonical transcript hash.
4. Android validates pairing ID and proof in constant time. Success returns `AuthenticateSessionResponse(authenticated, server_proof, granted_capabilities)`; failure returns one generic unauthorized error and closes the transport.
5. Mac validates the role-separated server proof before marking the session authenticated. Supplying stored credentials but receiving correlation-only state is a downgrade failure.

The explicit `CORRELATED` mode remains for the current M1 endpoint. `PAIRING_REQUIRED` means first pairing must run. The same endpoint accepts `PairingStartRequest` as the first frame only while the Android user has explicitly opened the visible pairing window; a normal background connection cannot create trust. See [Pairing and Session Authentication Design](pairing-auth-design.md) for canonical bytes and lifecycle rules.

First pairing reserves payload types 106...111 for three ordered exchanges:

1. `PairingStartRequest`/`PairingStartResponse` negotiate version 1 and exchange
   display names, 65-byte uncompressed ephemeral P-256 public keys, 32-byte nonces,
   and the server-generated 16-byte pairing ID. The response also carries Android's
   stable 65-byte identity public key and a DER ECDSA signature over the canonical
   transcript; Mac verifies it before presenting the SAS.
2. After both UIs show the same six-digit SAS, `PairingConfirmRequest` carries Mac
   approval and its role-separated confirmation. Android responds only after its
   own user approval with `PairingConfirmResponse` and the server confirmation.
3. Mac provisionally stores the credential, then sends `PairingFinalizeRequest` to
   prove receipt of the server confirmation. Android persists only after validation
   and returns `PairingFinalizeResponse`; rejection rolls back the Mac item.

These messages, cross-platform cryptographic/storage primitives, visible Android
window, Android wire state machine, one-shot async Mac client, Mac approval UI,
and paired-required Android product endpoint are implemented and locally tested.
Revocation UI and physical-device credential-store/product-auth evidence remain
open.

## Control Plane

Responsible for:

- Hello and handshake.
- Capability negotiation.
- Device information.
- Permission state.
- Directory listing.
- Transfer creation/cancel/pause/resume.
- Diagnostics.

Control-plane frames use `RPC_FRAME_KIND_REQUEST`, `RPC_FRAME_KIND_RESPONSE`, `RPC_FRAME_KIND_ERROR`, `RPC_FRAME_KIND_EVENT`, and `RPC_FRAME_KIND_CANCEL`.

## Data Plane

Responsible for:

- File chunks.
- Thumbnail batches.
- Media preview ranges.
- Large transfer backpressure.

Data-plane transfer chunks use `RPC_FRAME_KIND_STREAM` and the `PAYLOAD_TYPE_TRANSFER_CHUNK` payload type. `TransferChunkAck` also uses `RPC_FRAME_KIND_STREAM`; receivers distinguish chunks from acknowledgements by `payload_type`. Transfer acknowledgements must carry the same non-zero `stream_id` as the active transfer stream.

## Payload Kind Matrix

M1 senders must use these frame kinds for registered payloads:

| Payload group | Allowed kind |
|---|---|
| `CLIENT_HELLO`, `HEARTBEAT_REQUEST`, `DEVICE_INFO_REQUEST`, `DIAGNOSTICS_REQUEST`, `LIST_DIR_REQUEST`, file mutation requests, `OPEN_TRANSFER_REQUEST`, `PAUSE_TRANSFER_REQUEST`, `CANCEL_TRANSFER_REQUEST` | `RPC_FRAME_KIND_REQUEST` |
| `SERVER_HELLO`, `HEARTBEAT_RESPONSE`, `DEVICE_INFO_RESPONSE`, `DIAGNOSTICS_RESPONSE`, `LIST_DIR_RESPONSE`, `FILE_MUTATION_RESPONSE`, `OPEN_TRANSFER_RESPONSE`, `PAUSE_TRANSFER_RESPONSE`, `CANCEL_TRANSFER_RESPONSE` | `RPC_FRAME_KIND_RESPONSE` |
| `RPC_CANCEL_REQUEST` | `RPC_FRAME_KIND_CANCEL` |
| `RPC_CANCEL_RESPONSE` | `RPC_FRAME_KIND_RESPONSE` |
| `TRANSFER_CHUNK`, `TRANSFER_CHUNK_ACK` | `RPC_FRAME_KIND_STREAM` |
| `TRANSFER_PROGRESS` | `RPC_FRAME_KIND_EVENT` |
| `DROIDMATCH_ERROR` | `RPC_FRAME_KIND_ERROR` |
| `UNSPECIFIED` | Never valid on the wire |

Any other `kind` and `payload_type` combination is a protocol error. Receivers should return `RPC_FRAME_KIND_ERROR` with `ERROR_CODE_PROTOCOL_ERROR` when the frame can be correlated to a request, then close the session if the peer continues sending invalid combinations.

`TRANSFER_PROGRESS` is registered for the future event surface but is not emitted
by the current M1 runtime. Mac `AsyncTransferScheduler.recentBytesPerSecond` is a
local product snapshot metric derived from ACK-confirmed offsets; it does not
synthesize or imply a wire event.

## Error Channels

M1 uses two error channels:

- Framing, envelope, payload-kind, unsupported-version, unsupported-capability, timeout, and request-cancellation failures use `RPC_FRAME_KIND_ERROR` with `RpcEnvelope.error`.
- Business operation failures use the typed response message's embedded `DroidMatchError` and still return the expected `RPC_FRAME_KIND_RESPONSE` or `RPC_FRAME_KIND_STREAM`.

For example, an invalid `payload_type` returns `RPC_FRAME_KIND_ERROR`; a read-only destination for `OpenTransferRequest` returns `OpenTransferResponse.error`.

`PAYLOAD_TYPE_DROIDMATCH_ERROR` is reserved for top-level `RPC_FRAME_KIND_ERROR`. Top-level error envelopes carry the `DroidMatchError` in `RpcEnvelope.error`; typed business failures must not put `DroidMatchError` in `payload`, and must use the response message's embedded `error` field.

## Device and Diagnostics

`DeviceInfoResponse` is the first M1 control-plane query after handshake. It carries non-secret device identity, Android version, data-partition capacity, battery percentage, and permission state snapshots.

`DiagnosticsResponse` carries the negotiated transport, current Android service state, recent error events, counters, and recent state events. Events must already be redacted by the sender before they are placed on the wire.

## File Transfer Semantics

Product-level "get file" and "put file" operations are represented by one protocol entry point:

- Download from Android to Mac: `OpenTransferRequest.direction = TRANSFER_DIRECTION_DOWNLOAD`.
- Upload from Mac to Android: `OpenTransferRequest.direction = TRANSFER_DIRECTION_UPLOAD`.

`OpenTransferRequest` is used for both new transfers and resume attempts.

- `transfer_id` is generated by the Mac client. Use a UUID-style opaque string.
- `transfer_id` remains stable across retry and resume for the same logical transfer.
- `source_path` is the logical path on the source side.
- `destination_path` is the logical path on the destination side.
- For M1 uploads, Android authorizes only its logical `destination_path`; current
  Mac clients send the non-authoritative label `mac-local-upload` in the inactive
  `source_path`. The real POSIX source remains Mac-local for resume validation.
- `requested_offset_bytes = 0` starts a fresh transfer.
- `requested_offset_bytes > 0` requests resume from an existing partial destination.
- `expected_size_bytes = -1` means unknown size.
- `preferred_chunk_size_bytes = 0` asks the receiver to choose the default chunk size.
- `source_fingerprint` is optional for fresh transfers and recommended for resume attempts.
- `OpenTransferResponse.accepted_offset_bytes` is the offset both sides must use for the next chunk.
- `OpenTransferResponse.chunk_size_bytes` is the maximum chunk size the sender should use.
- `OpenTransferResponse.stream_id` identifies the data-plane stream for chunks and acknowledgements.
- `OpenTransferResponse.accepted_source_fingerprint` records the source identity the receiver accepted for this transfer attempt.

M1 default transfer chunk size is 256 KiB. The maximum allowed `TransferChunk.data` length is the negotiated `OpenTransferResponse.chunk_size_bytes`, and it must never exceed 1 MiB in M1.

`TransferChunk.offset_bytes` must equal the write offset for `data`. A receiver that detects a gap, duplicate chunk, checksum mismatch, or wrong final offset must return `ERROR_CODE_CHECKSUM_MISMATCH`, `ERROR_CODE_INVALID_ARGUMENT`, or `ERROR_CODE_PROTOCOL_ERROR` as appropriate.

`TransferChunkAck.next_offset_bytes` is the next byte offset the receiver expects. M1 senders should require a final ack before marking a transfer complete.

Resume must validate `TransferFingerprint` when the source provider can supply one. Providers should reject resume if size, modified time, provider etag, or optional SHA-256 no longer matches the original accepted source fingerprint.

Pause is control-plane state, not a separate data format:

- `PauseTransferRequest` asks the active sender to stop after a chunk boundary.
- `PauseTransferResponse.resumable_offset_bytes` is the last receiver-acknowledged boundary, not the last byte merely sent into the transport. Before any chunk ACK it remains the accepted open offset, even if later chunks have already arrived at the receiver.
- Resume is another `OpenTransferRequest` with the same `transfer_id` and the safe offset.
- The current Android M1 handler implements this wire request for active downloads
  only. It does not pause an active upload writer.
- Mac product scheduler checkpoint pause is a separate local policy: after a
  durable checkpoint exists, it cancels the coordinator's exclusive session and
  later reopens with `resume = true`. It must not be presented as wire upload pause.

Cancel is destructive for the active transfer attempt but not necessarily for partial data:

- `CancelTransferRequest` stops an active download or upload by `transfer_id`.
- `CancelTransferResponse.ok = true` confirms that the active reader or writer released the runtime transfer state.
- Receivers should keep partial data if it can be resumed safely.
- Once the protocol progress-event surface is explicitly enabled on both peers, a
  cancelled transfer should also emit
  `TransferProgress.state = TRANSFER_STATE_CANCELLED`. The current process-local
  Mac scheduler does not by itself enable that wire behavior.

## Cancellation and Timeouts

There are two cancellation paths:

- `RpcCancelRequest` targets any in-flight request by `target_request_id`.
- `CancelTransferRequest` targets a durable transfer by `transfer_id`.

Only `RpcCancelRequest` uses `RPC_FRAME_KIND_CANCEL`. Transfer-level cancel and pause messages are normal control-plane requests because they target transfer state rather than an envelope-level request slot.

If a request is cancelled before completion, the receiver should return `ERROR_CODE_CANCELLED` on the original request ID or acknowledge cancellation with `RpcCancelResponse`.

M1 default timeouts:

| Operation | Default |
|---|---:|
| Handshake | 5 seconds |
| Device info, diagnostics, directory listing | 10 seconds |
| File mutation | 15 seconds |
| Open transfer | 10 seconds |
| Cancel or pause transfer | 5 seconds |
| Heartbeat interval | 15 seconds |
| Transfer idle timeout | 30 seconds |

Large transfers do not have a single whole-transfer deadline. They use the transfer idle timeout and progress events instead.

When a sender-side timeout fires, the sender should mark the operation as `ERROR_CODE_TIMEOUT` and send `RpcCancelRequest` if the peer may still be working.

## Error Policy

Every operation returns either a typed response or a `DroidMatchError`.

Errors must be:

- Stable enough for UI mapping.
- Specific enough for diagnostics.
- Safe to show in logs.
- Versioned when behavior changes.

Protocol framing errors use `ERROR_CODE_PROTOCOL_ERROR`. Unsupported protocol major versions use `ERROR_CODE_UNSUPPORTED_VERSION`. Unsupported negotiated features use `ERROR_CODE_UNSUPPORTED_CAPABILITY`.
