# M0 Closeout

Closed: 2026-06-27

M0 is closed as a specification phase. DroidMatch may move into M1 harness work, but full product UI work remains blocked until M1 passes on real devices.

## Closed Decisions

- Product scope is defined in `docs/product-scope.md` and `docs/feature-matrix.md`.
- DroidMatch's relationship to HandShaker is workflow-level replacement only, defined in `docs/handshaker-relationship.md`.
- Minimum macOS version is macOS 13 Ventura.
- Minimum Android API is API 26, Android 8.0.
- Android storage behavior uses SAF and MediaStore first across API 26+.
- ADB is the stable v1.0 production path.
- AOA is PoC-gated and remains experimental until M1 device data proves it.
- Protobuf is the schema language.
- M1 does not require gRPC.
- M1 uses `RpcEnvelope` for framed request, response, event, stream, error, timeout, and cancellation semantics.
- File download and upload use unified `OpenTransfer` semantics with direction, chunk acknowledgement, pause, cancel, and resume.
- Protocol paths use DroidMatch logical provider paths, not raw Android filesystem paths, SAF URIs, or Mac POSIX paths.
- M1 runtime limits, scheduling, paging, and backpressure are defined before harness implementation.
- M1 security posture is local-first but still treats ADB forward ports, AOA sessions, and support bundles as explicit trust boundaries.

## Required M1 Work

M1 starts with harnesses, not product UI:

- Mac command-line or minimal harness for ADB discovery, forwarding, framing, and transfer tests.
- Android foreground service skeleton with ADB endpoint, RPC dispatcher, file provider, permission reporter, and diagnostics reporter.
- AOA harness only after ADB path can exercise the same protocol surface.
- Real-device runs following `docs/m1-device-matrix.md`.
- Path, runtime, and security behavior following `docs/path-model.md`, `docs/protocol-runtime.md`, and `docs/security-model.md`.
- Result logs under `fixtures/m1-runs/` once harnesses exist.

## M1 Exit Gate

M1 passes only when the required real-device matrix proves:

- ADB handshake reliability.
- Directory listing latency.
- 100MB upload and download throughput.
- Cable unplug/replug recovery.
- Interrupted transfer resume.
- Permission degradation.
- Diagnostics source attribution.
- AOA viability on at least two physical devices before AOA moves beyond experimental.

## Validation

The M0 gate is checked by:

```text
bash tools/check-m0.sh
bash tools/check-proto.sh
```

CI runs both checks on push and pull request.
