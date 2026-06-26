# M0 Checklist

M0 is complete only when the following items are answered in writing.

Status as of 2026-06-27: M0 specification items are answered. M1 may start with harness work, but full product UI work stays blocked until M1 passes on real devices.

## Product

- [x] Confirm v1.0, v1.1, v1.5 scope in `docs/product-scope.md`.
- [x] Confirm feature matrix in `docs/feature-matrix.md`.
- [x] Confirm non-goals and legal isolation rules in `docs/product-scope.md` and `docs/handshaker-relationship.md`.
- [x] Decide minimum macOS version: macOS 13 Ventura.
- [x] Decide minimum Android API: API 26, Android 8.0.

## Architecture

- [x] Define Mac modules and M0 public interface boundaries in `docs/architecture.md`.
- [x] Define Android modules and M0 public component boundaries in `docs/architecture.md`.
- [x] Define control-plane and data-plane responsibilities in `docs/architecture.md` and `docs/protocol.md`.
- [x] Define diagnostics ownership in `docs/architecture.md` and `docs/diagnostics.md`.
- [x] Define cache ownership and invalidation rules in `docs/architecture.md`.

## Protocol

- [x] Define handshake and version negotiation in `proto/v1/session.proto`.
- [x] Define capability negotiation in `proto/v1/session.proto`.
- [x] Define error code policy in `docs/protocol.md` and `proto/v1/error.proto`.
- [x] Stabilize transfer IDs, request IDs, and the top-level RPC/frame envelope in `docs/protocol.md` and `proto/v1/rpc.proto`.
- [x] Define cancellation and timeout behavior in protocol-level detail in `docs/protocol.md`.
- [x] Decide whether any v1 path needs gRPC: no v1.0 path requires gRPC; AOA starts with lightweight framing, while ADB may adopt gRPC later only if it adds clear value.

## USB Transport

- [x] Define ADB discovery, authorization, forward, reconnect, and teardown in `docs/transport-usb.md`.
- [x] Define AOA discovery, permission, endpoint setup, reconnect, and teardown in `docs/transport-usb.md`.
- [x] Define M1 throughput targets in `docs/transport-usb.md`.
- [x] Define failure reasons shown to the user in `docs/transport-usb.md`.

## Android Permissions

- [x] Map each v1.0 feature to permissions in `docs/android-permissions.md`.
- [x] Define degradation paths for Android 11+ and Android 8-10 storage behavior in `docs/android-permissions.md`.
- [x] Define Play and non-Play build differences in `docs/android-permissions.md`.
- [x] Define package visibility policy in `docs/android-permissions.md`.

## M1 Gate

- [x] Stabilize `ListDir`, download, and upload schemas for PoC. M1 uses `ListDir`, `OpenTransfer`, `TransferChunk`, and `TransferChunkAck`; product-level get/put map to transfer direction.
- [x] ADB and AOA harnesses have clear acceptance metrics in `docs/transport-usb.md`.
- [x] Real-device test matrix is listed in `docs/m1-device-matrix.md`.
- [x] No full product UI work starts before M1 passes.
