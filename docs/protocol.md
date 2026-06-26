# Protocol

## Baseline

DroidMatch uses Protobuf for schema definitions. Transports may choose different carriers, but the semantic model must stay shared.

M1 messages live in `proto/v1/`:

- `error.proto`
- `session.proto`
- `device.proto`
- `file.proto`
- `transfer.proto`

## Framing Direction

AOA should start with a lightweight binary frame instead of assuming gRPC.

Proposed frame fields:

| Field | Purpose |
|---|---|
| magic | Detect DroidMatch frames. |
| version | Frame format version. |
| flags | Request, response, event, stream, error. |
| request_id | Correlate request and response. |
| stream_id | Correlate transfer chunks. |
| payload_type | Identify Protobuf message type. |
| payload_length | Bound reads. |
| checksum | Optional integrity guard for data-plane chunks. |

## Control Plane

Responsible for:

- Hello and handshake.
- Capability negotiation.
- Device information.
- Permission state.
- Directory listing.
- Transfer creation/cancel/pause/resume.
- Diagnostics.

## Data Plane

Responsible for:

- File chunks.
- Thumbnail batches.
- Media preview ranges.
- Large transfer backpressure.

## Error Policy

Every operation returns either a typed response or a `DroidMatchError`.

Errors must be:

- Stable enough for UI mapping.
- Specific enough for diagnostics.
- Safe to show in logs.
- Versioned when behavior changes.

