# Structural Debt Baseline

Last updated: 2026-07-10

This page records structural risks that are easy to hide behind feature progress.
Passing tests does not by itself mean these risks are closed.

本文记录容易被功能进度掩盖的结构性风险；测试通过不代表这些风险已经收口。

## Current Truth

| Risk | Status | Evidence |
|---|---|---|
| Large source files | **Partially reduced** | `AsyncTransferScheduler.swift` was reduced from 1,074 to 914 lines. `DmFileProvider.java` was reduced from 3,105 to 2,777 lines by extracting provider upload commit/cleanup state machines. Four production files still require explicit debt ceilings. |
| Synchronous Mac networking | **Partially replaced** | Product-facing control, pairing, transfer, and presentation paths use `AsyncFramedTcpSession` and higher async actors. `FramedTcpSession` remains in the M1 CLI/smoke path for archived-evidence compatibility. |
| Single-maintainer risk | **Mitigated, not eliminated** | `AGENTS.md`, bilingual live docs, deterministic gates, 170 Swift tests, Android tests/lint, and the multi-model review contract reduce undocumented knowledge. Ownership and several complex state machines are still concentrated. |
| macOS product App target | **Not implemented** | SwiftPM exposes Core, Presentation, and the M1 harness only. The repository contract blocks claims of a product UI until the required M1 device matrix passes. |
| Android product entry | **Authorization/diagnostics only** | `DiagnosticsActivity` provides visible pairing approval, notification permission, and SAF-root selection. It is not a file manager or complete device-management UI. |

中文结论：巨石文件和同步网络层只做了部分治理；单人维护风险只有工程化缓解；Mac 产品 App target 与 Android 完整产品入口都还没有完成。

## Source-size Guardrail

`python3 tools/check-source-size.py` applies a 1,000-line ceiling to new handwritten
production Swift/Java/Kotlin files. Generated protobuf sources are excluded.

The following legacy ceilings freeze existing debt and may only move downward:

| File | Ceiling |
|---|---:|
| `android/app/src/main/java/app/droidmatch/m1/DmFileProvider.java` | 2,777 |
| `android/app/src/main/java/app/droidmatch/m1/RpcDispatcher.java` | 2,293 |
| `mac/Sources/DroidMatchHarness/main.swift` | 1,457 |
| `mac/Sources/DroidMatchCore/AsyncRpcMultiplexer.swift` | 1,218 |

The guardrail prevents regression; it is not a substitute for decomposition.
When a listed file reaches 1,000 lines or fewer, the gate requires removal of its
stale exception.

## Decomposition Order

1. **Android provider I/O and catalogs (in progress):** upload writers are now
   separate; next extract stream-reader mechanics and app-sandbox/MediaStore/SAF
   catalogs behind the existing `DmFileProvider` contracts. Preserve path,
   permission, atomic-commit, and resume behavior with the full Android gate.
2. **Android RPC routing:** separate pairing/authentication and transfer-session
   routing from envelope dispatch without changing wire schemas or generic failure
   shapes.
3. **Mac harness commands:** separate command parsing, control probes, and transfer
   probes. Keep it a consumer of Core rather than a second product architecture.
4. **Mac async router:** isolate control correlation, transfer routes, and timeout
   bookkeeping while retaining exactly one reader and one lifetime-selected I/O mode.
5. **Legacy synchronous removal:** migrate a smoke path only after async parity and
   archived-device evidence are preserved. Do not wrap blocking calls in detached
   tasks and call that migration complete.

## Product-surface Gate

The next real macOS App target must enter through DeviceDiscovery/DeviceSession and
the existing Presentation/Core boundaries. It must not run raw ADB, parse protobuf,
or call `FramedTcpSession` on MainActor. Signing, notarization, packaging, English/
Chinese localization, and lifecycle-owned persistence remain part of product work.

Android may evolve its authorization activity into a product onboarding/status
surface, but transport access must remain separate from media/storage permission and
pairing approval. A richer launcher is not evidence that the Mac product or M1 device
matrix is complete.
