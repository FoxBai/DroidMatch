# DroidMatch Protocol

The protocol uses Protobuf as the schema language. M0 should not bind every transport to gRPC.

Baseline:

- Protobuf messages define requests, responses, events, errors, and capabilities.
- ADB TCP can later support gRPC or HTTP/2 if useful.
- AOA bulk transport should start with a lightweight frame protocol.
- Control plane and data plane must stay separable.

