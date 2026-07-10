# Structural Debt Baseline

Last updated: 2026-07-10

This page records structural risks that are easy to hide behind feature progress.
Passing tests does not by itself mean these risks are closed.

本文记录容易被功能进度掩盖的结构性风险；测试通过不代表这些风险已经收口。

## Current Truth

| Risk | Status | Evidence |
|---|---|---|
| Large source files | **Production budget enforced; test split open** | Every handwritten production Swift/Java/Kotlin file is at most 1,000 lines. `DroidMatchHarness/main.swift` is 828 lines after transfer commands moved to a 676-line extension and non-transfer probes gained async teardown. No production exception remains, but `FrameCodecTests.swift` is still a 2,518-line test/fixture concentration. |
| Synchronous Mac networking | **Partially replaced** | Product-facing control, pairing, transfer, and presentation paths use `AsyncFramedTcpSession` and higher async actors. Every non-transfer CLI network probe now does too: `framed-echo`, handshake-only, `m1-smoke`, ordinary listing, and expected-error listing. Synchronous `FramedTcpSession` remains only in transfer evidence commands, including the dedicated dual-download probe. |
| Single-maintainer risk | **Mitigated, not eliminated** | `AGENTS.md`, bilingual live docs, deterministic gates, 171 Swift tests, Android tests/lint, and the model-verified review wrapper reduce undocumented knowledge. Ownership, release authority, and several complex state machines are still concentrated. |
| macOS product App target | **Not implemented** | SwiftPM exposes Core, Presentation, and the M1 harness only. The repository contract blocks claims of a product UI until the required M1 device matrix passes. |
| Android product entry | **Authorization/diagnostics only** | `DiagnosticsActivity` provides visible pairing approval, notification permission, and SAF-root selection. It is not a file manager or complete device-management UI. |

中文结论：生产代码巨石已有强制门禁，但测试夹具仍有 2518 行集中点；非传输网络命令已全部异步化，传输证据命令与单人维护风险仍只有部分治理；Mac 产品 App target 与 Android 完整产品入口还没有完成。

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

The next real macOS App target must enter through DeviceDiscovery/DeviceSession and
the existing Presentation/Core boundaries. It must not run raw ADB, parse protobuf,
or call `FramedTcpSession` on MainActor. Signing, notarization, packaging, English/
Chinese localization, and lifecycle-owned persistence remain part of product work.

Android may evolve its authorization activity into a product onboarding/status
surface, but transport access must remain separate from media/storage permission and
pairing approval. A richer launcher is not evidence that the Mac product or M1 device
matrix is complete.
