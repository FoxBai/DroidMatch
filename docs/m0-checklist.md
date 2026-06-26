# M0 Checklist

M0 is complete only when the following items are answered in writing.

## Product

- [ ] Confirm v1.0, v1.1, v1.5 scope in `docs/product-scope.md`.
- [ ] Confirm feature matrix in `docs/feature-matrix.md`.
- [ ] Confirm non-goals and legal isolation rules.
- [ ] Decide minimum macOS version.
- [ ] Decide minimum Android API.

## Architecture

- [ ] Define Mac modules and public interfaces.
- [ ] Define Android modules and public interfaces.
- [ ] Define control-plane and data-plane responsibilities.
- [ ] Define diagnostics ownership.
- [ ] Define cache ownership and invalidation rules.

## Protocol

- [ ] Define handshake and version negotiation.
- [ ] Define capability negotiation.
- [ ] Define error code policy.
- [ ] Define transfer IDs and request IDs.
- [ ] Define cancellation and timeout behavior.
- [ ] Decide whether any v1 path needs gRPC.

## USB Transport

- [ ] Define ADB discovery, authorization, forward, reconnect, and teardown.
- [ ] Define AOA discovery, permission, endpoint setup, reconnect, and teardown.
- [ ] Define M1 throughput targets.
- [ ] Define failure reasons shown to the user.

## Android Permissions

- [ ] Map each v1.0 feature to permissions.
- [ ] Define degradation paths for Android 11+ storage behavior.
- [ ] Define Play and non-Play build differences.
- [ ] Define package visibility policy.

## M1 Gate

- [ ] `ListDir`, `GetFile`, and `PutFile` schemas are stable enough for PoC.
- [ ] ADB and AOA harnesses have clear acceptance metrics.
- [ ] Real-device test matrix is listed.
- [ ] No full product UI work starts before M1 passes.

