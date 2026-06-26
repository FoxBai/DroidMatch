# Decision Log

## 2026-06-26

| Decision | Rationale |
|---|---|
| Project name is DroidMatch | Establish a new identity independent from HandShaker and Smartisan. |
| Build a modern replacement, not a clone | Preserve valuable workflows while avoiding old brand, UI assets, and binary implementation. |
| Use a new monorepo at `/Users/baizhiming/Documents/DroidMatch` | Keep the new product separate from the existing binary-maintenance repository. |
| Main route is Mac + Android dual-end rewrite | Control protocol, permissions, diagnostics, transfer recovery, and AOA/ADB behavior. |
| ADB is the stable v1 path | It is the fastest reliable route for M1 and early v1.0. |
| AOA is a PoC-gated consumer path | It can reduce USB debugging friction, but it does not solve Android permissions by itself. |
| Old HandShaker Android compatibility is a timeboxed research line | It may reduce migration cost, but must not block the new product architecture. |
| Protobuf is the protocol schema; gRPC is not mandatory | AOA bulk transport benefits from lightweight framing. |
| v1.0 scope is intentionally narrow | Connection, files, basic media, transfer recovery, diagnostics, and distribution come first. |

## 2026-06-27

| Decision | Rationale |
|---|---|
| HandShaker relationship is workflow-level replacement only | DroidMatch can learn from user-visible workflows, but must not reuse old brand, assets, code, binaries, signing material, or UI implementation. See `docs/handshaker-relationship.md`. |
| Minimum macOS version is macOS 13 Ventura | Keeps the first native Mac implementation modern while avoiding unnecessary macOS 14+ lock-in. |
| Minimum Android API is API 26, Android 8.0 | Keeps the Android service broad enough for older devices while using a modern foreground-service and provider baseline. |
| Android 11+ scoped storage is the primary permission model | v1.0 must degrade around current Android storage rules instead of assuming broad filesystem access. |
| M1 protocol uses a lightweight `RpcEnvelope` instead of gRPC | Keeps ADB and AOA harnesses aligned while leaving room for lower-overhead AOA framing later. |
| File get/put use unified `OpenTransfer` semantics | One transfer state machine covers download, upload, pause, cancel, retry, and resume. |
| API 26-29 uses the same SAF/MediaStore-first storage model | Avoids a second primary file model while still allowing gated legacy optimizations outside the default Play path. |
| M1 real-device matrix gates product UI work | The first implementation phase should prove ADB, AOA, permissions, reconnect, transfer resume, and diagnostics on physical devices. |
