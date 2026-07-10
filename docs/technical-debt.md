# Structural Debt Baseline

Last updated: 2026-07-11

This page records structural risks that are easy to hide behind feature progress.
Passing tests does not by itself mean these risks are closed.

本文记录容易被功能进度掩盖的结构性风险；测试通过不代表这些风险已经收口。

## Current Truth

| Risk | Status | Evidence |
|---|---|---|
| Large source files | **Production budget enforced; test split open** | Every handwritten production Swift/Java/Kotlin file is at most 1,000 lines. `DroidMatchHarness/main.swift` is 828 lines after transfer commands moved to a 676-line extension and non-transfer probes gained async teardown. No production exception remains, but `FrameCodecTests.swift` is still a 2,518-line test/fixture concentration. |
| Synchronous Mac networking | **Partially replaced** | Product-facing control, pairing, transfer, and presentation paths use `AsyncFramedTcpSession` and higher async actors. Every non-transfer CLI network probe now does too: `framed-echo`, handshake-only, `m1-smoke`, ordinary listing, and expected-error listing. Synchronous `FramedTcpSession` remains only in transfer evidence commands, including the dedicated dual-download probe. |
| Single-maintainer risk | **Mitigated, not eliminated** | `AGENTS.md`, bilingual live docs, deterministic gates, 194 Swift tests, Android tests/lint, and the model-verified review wrapper reduce undocumented knowledge. Ownership, release authority, and several complex state machines are still concentrated. |
| macOS product App target | **Authenticated read-only product path implemented** | SwiftPM exposes a SwiftUI `DroidMatch` product with localized discovery, anonymous forward leases, Keychain credential selection, SAS approval, paired proof, live paginated file browsing, privacy-bounded structured diagnostics, an ad-hoc `.app` assembler, and macOS CI coverage. Physical-device product-auth evidence, live transfer UI, sandbox lifecycle, Developer ID signing, notarization, and DMG remain open. |
| Android product entry | **Secure onboarding/status implemented** | `DiagnosticsActivity` explicitly enables/disables a paired-required loopback endpoint, exposes coarse lifecycle state, gates the visible pairing window on readiness, requests notification permission, and selects SAF roots. It is not a file manager or complete device-management UI. |

中文结论：生产代码巨石已有强制门禁，但测试夹具仍有 2518 行集中点；非传输网络命令已全部异步化，传输证据命令与单人维护风险仍只有部分治理；Mac 已接通认证会话、只读文件浏览和结构化诊断，但尚缺产品认证真机证据与传输页面；Android 已从纯诊断入口升级为安全连接 onboarding/status 入口，但完整文件管理体验仍未完成。

## Source-size Guardrail

`python3 tools/check-source-size.py` applies a 1,000-line ceiling to new handwritten
production Swift/Java/Kotlin files. Generated protobuf sources are excluded.
Tests are also excluded from this production gate; the oversized shared Mac test
fixture is tracked here explicitly instead of being mislabeled as resolved.

No legacy ceilings remain. The gate now applies the same default limit to every
handwritten production source file. Structural boundaries and behavior tests
remain necessary; line count alone does not prove good architecture.

## Decomposition Order

1. **Android provider facade (default-budget reached):** upload writers,
   download readers, shared helpers, app-sandbox, MediaStore, and SAF catalogs
   are separate. `ProviderPathRouter` now owns logical path/target validation and
   opaque SAF token routing; the 972-line facade owns the bounded cache and
   provider dispatch. Its legacy exception has been removed.
2. **Android RPC dispatcher (default-budget reached):**
   `RpcTransferHandler` owns open/chunk/ACK/cancel/pause routing and registries;
   `RpcTransferStreams` owns ACK-bounded stream state; `RpcAuthenticationHandler`
   owns reconnect/first-pairing exchanges; and `RpcSessionState` owns provisional
   secret clearing. The 574-line dispatcher now owns only envelope/session-phase/
   capability routing and its legacy exception has been removed.
3. **Mac harness commands (default-budget reached):** the 828-line `main.swift`
   owns command dispatch, control probes, help, and shared parsing;
   `HarnessTransferCommands.swift` owns the 676-line download/upload CLI probes.
   Both remain consumers of Core and the final legacy exception has been removed.
4. **Mac async router (default-budget reached):** `AsyncRpcRoutingState` owns
   route records, request-ID rotation, and pure transfer/window validation. It
   owns no actor, task, waiter resolution, or socket. The 994-line multiplexer
   retains exactly one reader plus network send, deadline, routing mutation, and
   termination ownership; its legacy exception has been removed.
5. **Legacy synchronous removal (in progress):** all non-transfer network probes now
   run on `AsyncFramedTcpSession`; RPC probes use `AsyncRpcControlClient`, while the
   handshake-only probe deliberately stays below authentication so it can return a
   legal `pairingRequired` Hello result. Dead synchronous heartbeat/device-info/
   diagnostics/listing APIs were removed from `RpcControlClient`. Transfer evidence
   probes still use `FramedTcpSession`; each later migration needs equivalent local
   coverage and archived-device evidence. Wrapping blocking calls in detached tasks
   does not count as async migration.

## Product-surface Gate

The macOS SwiftUI target enters through `DeviceDiscovering` and
`DeviceDiscoveryModel`: its private queue owns blocking ADB commands, and raw
serials are replaced by process-local UUIDs before Presentation. The same actor
now owns dynamic forward leases; `ProductDeviceSessionCoordinator` owns identity
selection, Keychain credentials, pairing/authentication, socket teardown, and
lease release. `DeviceSessionModel` publishes only bounded state and unlocks the
live directory browser after proof. Raw ADB, protobuf, credentials, and
`FramedTcpSession` remain off MainActor. Developer ID signing, notarization, DMG
packaging, lifecycle-owned transfer persistence, and physical product-auth evidence
remain product work.

Android may evolve its authorization activity into a product onboarding/status
surface, but transport access must remain separate from media/storage permission and
pairing approval. A richer launcher is not evidence that the Mac product or M1 device
matrix is complete.
