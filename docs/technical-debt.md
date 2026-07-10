# Structural Debt Baseline

Last updated: 2026-07-10

This page records structural risks that are easy to hide behind feature progress.
Passing tests does not by itself mean these risks are closed.

本文记录容易被功能进度掩盖的结构性风险；测试通过不代表这些风险已经收口。

## Current Truth

| Risk | Status | Evidence |
|---|---|---|
| Large source files | **Default budget enforced** | Every handwritten production Swift/Java/Kotlin file is at most 1,000 lines. `DroidMatchHarness/main.swift` fell from 1,457 to 786 after transfer commands moved to a 676-line extension. No legacy exceptions remain. |
| Synchronous Mac networking | **Partially replaced** | Product-facing control, pairing, transfer, and presentation paths use `AsyncFramedTcpSession` and higher async actors. The baseline `m1-smoke` control sequence now uses that async path too; legacy handshake-only uses `FramedTcpClient`, while listing, transfer, and error probes still use `FramedTcpSession` for archived-evidence compatibility. |
| Single-maintainer risk | **Mitigated, not eliminated** | `AGENTS.md`, bilingual live docs, deterministic gates, 171 Swift tests, Android tests/lint, and the multi-model review contract reduce undocumented knowledge. Ownership and several complex state machines are still concentrated. |
| macOS product App target | **Not implemented** | SwiftPM exposes Core, Presentation, and the M1 harness only. The repository contract blocks claims of a product UI until the required M1 device matrix passes. |
| Android product entry | **Authorization/diagnostics only** | `DiagnosticsActivity` provides visible pairing approval, notification permission, and SAF-root selection. It is not a file manager or complete device-management UI. |

中文结论：巨石文件规模门禁已完成收口；同步网络层和单人维护风险仍只有部分治理；Mac 产品 App target 与 Android 完整产品入口还没有完成。

## Source-size Guardrail

`python3 tools/check-source-size.py` applies a 1,000-line ceiling to new handwritten
production Swift/Java/Kotlin files. Generated protobuf sources are excluded.

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
3. **Mac harness commands (default-budget reached):** the 786-line `main.swift`
   owns command dispatch, control probes, help, and shared parsing;
   `HarnessTransferCommands.swift` owns the 676-line download/upload CLI probes.
   Both remain consumers of Core and the final legacy exception has been removed.
4. **Mac async router (default-budget reached):** `AsyncRpcRoutingState` owns
   route records, request-ID rotation, and pure transfer/window validation. It
   owns no actor, task, waiter resolution, or socket. The 994-line multiplexer
   retains exactly one reader plus network send, deadline, routing mutation, and
   termination ownership; its legacy exception has been removed.
5. **Legacy synchronous removal (in progress):** the baseline `m1-smoke` sequence
   now runs on `AsyncFramedTcpSession` plus `AsyncRpcControlClient`, with its command,
   capability request, and success output preserved. The remaining handshake-only
   probe uses synchronous `FramedTcpClient`; listing, transfer, and expected-error
   probes still use synchronous `FramedTcpSession`.
   Each later migration needs equivalent local coverage and archived-device evidence;
   wrapping blocking calls in detached tasks does not count as async migration.

## Product-surface Gate

The next real macOS App target must enter through DeviceDiscovery/DeviceSession and
the existing Presentation/Core boundaries. It must not run raw ADB, parse protobuf,
or call `FramedTcpSession` on MainActor. Signing, notarization, packaging, English/
Chinese localization, and lifecycle-owned persistence remain part of product work.

Android may evolve its authorization activity into a product onboarding/status
surface, but transport access must remain separate from media/storage permission and
pairing approval. A richer launcher is not evidence that the Mac product or M1 device
matrix is complete.
