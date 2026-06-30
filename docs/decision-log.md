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
| Protocol paths are logical DroidMatch provider paths | Keeps Mac code independent from Android SAF URIs, vendor filesystem paths, and provider implementation details. |
| M1 transfer resume uses optional source fingerprints | Allows resume validation without requiring expensive full-file hashing for every transfer. |
| M1 starts with explicit local trust boundaries | ADB forward, AOA, Android permissions, and support bundles need security rules before product UI work. |

## 2026-06-29

| Decision | Rationale |
|---|---|
| M1 Mac harness starts as a SwiftPM package | Gives a fast command-line validation loop before product UI or Xcode project complexity. |
| M1 Android skeleton starts in Java with `javac` + `android.jar` validation | Keeps the first service skeleton dependency-light until Gradle, Kotlin, and generated protobuf wiring are needed. |
| M1 Mac socket I/O should use Network.framework before considering SwiftNIO | macOS 13+ provides native async networking and avoids adding a large dependency before transport measurements justify it. |
| M1 frame reader uses cursor-based buffering | Avoids repeated buffer compaction on streaming frame reads while keeping the first harness small. |
| Android 14 selected visual media access counts as granted media access for M1 diagnostics | Keeps the four-state permission model stable while provider roots and capabilities still expose the narrower accessible surface. |

## 2026-06-30

| Decision | Rationale |
|---|---|
| M1 protobuf wire may add fields until the M1 device matrix is accepted | New fields must use fresh field numbers and remain backward compatible; after M1 acceptance, wire changes require an explicit protocol-version decision. |
| Android device identity avoids raw serials | `DeviceInfoResponse.device_id` is derived from non-secret build fields during M1 and must not use `Build.SERIAL`, IMEI, or Android ID without a separate privacy decision. |
| Project license is MPL-2.0 | Keeps the project under file-level copyleft while preserving clear boundaries for app packaging, generated code, and larger-work integration. |
| M1 root listing starts at `dm://roots/` | Gives the harness a protocol-valid directory listing smoke path before real MediaStore and SAF providers are wired. |
| M1 MediaStore roots are flat logical item lists | `dm://media-images/` and `dm://media-videos/` expose read-only media entries with logical item paths first; bucket hierarchy and SAF roots can be layered on without leaking platform URIs. |
| M1 SAF roots use persisted tree permissions and logical paths | Android stores user-selected tree URI permissions, while Mac sees only `dm://saf-.../` paths with opaque Android-local document tokens. |
| M1 transfer starts with a single download chunk smoke | The first transfer implementation validates `OpenTransferResponse` + one `TransferChunk` + final ACK over the same ADB session before adding scheduler, resume, upload, pause, and cancel complexity. |
| M1 ADB download uses receiver-paced chunks first | The Mac harness ACKs each chunk before Android reads and sends the next one, proving multi-chunk correctness without introducing multi-stream scheduling before the real-device matrix. |
