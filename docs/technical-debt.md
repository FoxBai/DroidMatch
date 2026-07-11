# Structural Debt Baseline

Last updated: 2026-07-11

This page records structural risks that are easy to hide behind feature progress.
Passing tests does not by itself mean these risks are closed.

本文记录容易被功能进度掩盖的结构性风险；测试通过不代表这些风险已经收口。

## Current Truth

| Risk | Status | Evidence |
|---|---|---|
| Large source files | **Unified budget enforced** | Every handwritten production and test Swift/Java/Kotlin file is at most 1,000 lines, with no exception. The former 2,526-line Mac frame/RPC fixture, 1,288-line multiplexer test, 1,173-line Android provider test, and 1,977-line dispatcher test are split by behavior/fixture ownership; the largest current handwritten file is a 993-line scheduler test. |
| Synchronous Mac networking | **Removed** | Every product and CLI operation uses the async session/router. The semaphore transport, synchronous RPC client, and implementation-specific tests are deleted; stable errors/results live in transport-independent files. |
| Single-maintainer risk | **Mitigated, not eliminated** | `AGENTS.md`, bilingual live docs, deterministic gates, 202 Swift tests, Android tests/lint, and the model-verified review wrapper reduce undocumented knowledge. Ownership, release authority, and several complex state machines are still concentrated. |
| macOS product App target | **Implemented; release evidence incomplete** | SwiftPM exposes a SwiftUI `DroidMatch` product with localized discovery, authentication, trusted-device revoke, browsing/transfers, a device-isolated queue, App-owned bookmark leases, ordinary/sandbox bundle assembly, and a mount-verified local DMG with checksum. The sandbox build embeds/signs adb with NOTICE and has locally discovered two physical devices without denial logs. Physical-device product-auth/transfer/revocation and sandbox file-transfer evidence, Developer ID signing, and notarization remain open. |
| Android product entry | **Secure onboarding and trust/authorization management implemented** | Product launcher `DroidMatchActivity` controls the paired-required endpoint, pairing approval, notification permission, paired-Mac list/revoke, and SAF root list/add/revoke. Revoking trust closes the active USB service before it can be reused. CI assembles an unsigned release APK, verifies the product launcher, and rejects the debug harness in its merged manifest. It is not yet a local file browser or complete device-management UI. |

中文结论：生产与测试代码现已统一执行 1000 行门禁，四个存量测试巨石也已按行为和 fixture 所有权拆分；双下载并发证据已迁移到产品 async router，剩余单传输证据命令与单人维护风险仍只有部分治理；Mac 已接通认证会话、文件浏览、结构化诊断、持久双向队列和 bookmark 租约，带 entitlement 的实包也已通过两台真机只读发现，但仍缺产品认证/传输与 sandbox 文件传输证据；Android 已升级为安全连接 onboarding/status 与 SAF 授权管理入口，但完整本地文件浏览体验仍未完成。

## Source-size Guardrail

`python3 tools/check-source-size.py` applies one 1,000-line ceiling to handwritten
production, unit-test, and instrumentation-test Swift/Java/Kotlin files. Generated
protobuf/build outputs are excluded.

No legacy ceilings remain. The gate applies the same default limit to every
handwritten source file in its production and test roots. Structural boundaries
and behavior tests remain necessary; line count alone does not prove good
architecture.

## Decomposition Order

1. **Android provider facade (default-budget reached):** upload writers,
   download readers, shared helpers, app-sandbox, MediaStore, and SAF catalogs
   are separate. `ProviderPathRouter` now owns logical path/target validation and
   opaque SAF token routing; `ProviderPagePolicy` owns pure pagination/token
   validation; `ProviderDirectoryListings` owns root and provider-specific list
   response assembly. The 790-line facade retains the bounded SAF identity cache,
   catalog contracts, and transfer/mutation dispatch.
   Its legacy exception has been removed.
2. **Android RPC dispatcher (default-budget reached):**
   `RpcTransferHandler` owns open/chunk/ACK/cancel/pause routing;
   `RpcTransferRegistry` owns session-scoped handle identity and teardown;
   `RpcTransferStreams` owns ACK-bounded stream state; `RpcAuthenticationHandler`
   owns reconnect/first-pairing exchanges; and `RpcSessionState` owns provisional
   secret clearing. The 574-line dispatcher now owns only envelope/session-phase/
   capability routing and its legacy exception has been removed.
3. **Mac harness commands (split complete):** the 611-line `main.swift` owns
   command dispatch and control probes; the 746-line
   `HarnessTransferCommands.swift` owns download/upload probes; and the small
   `HarnessCLI.swift` / `HarnessHelp.swift` files own parsing, typed failures,
   and usage text. All remain consumers of Core and no source-size exception is
   required.
4. **Mac async router (default-budget reached):** `AsyncRpcRoutingState` owns
   route records, request-ID rotation, and pure transfer/window validation. It
   owns no actor, task, waiter resolution, or socket. `AsyncRpcDeadlines` owns
   wall-clock deadline tasks without routing mutation. The 845-line multiplexer
   retains exactly one reader plus network send, deadline, routing mutation, and
   termination ownership; its legacy exception has been removed.
   `AsyncTransferSchedulerPolicy` similarly owns pure persisted-state,
   checkpoint, metadata, and resume-request decisions; the scheduler actor is
   now 851 lines and retains runtime queue/task/waiter/timer ownership.
5. **Legacy synchronous removal (complete):** product, control, pairing, and
   transfer evidence paths use the async session and single-reader router. The
   old semaphore transport and synchronous RPC implementation are deleted; no
   blocking network call is hidden in a detached task.

## Product-surface Gate

The macOS SwiftUI target enters through `DeviceDiscovering` and
`DeviceDiscoveryModel`: its private queue owns blocking ADB commands, and raw
serials are replaced by process-local UUIDs before Presentation. The same actor
now owns dynamic forward leases; `ProductDeviceSessionCoordinator` owns identity
selection, Keychain credentials, pairing/authentication, socket teardown, and
lease release. `DeviceSessionModel` publishes only bounded state and unlocks the
live directory browser after proof. Raw ADB, protobuf, credentials, and
Network and filesystem ownership remain off MainActor. Developer ID signing, notarization, DMG
packaging, lifecycle-owned transfer persistence, and physical product-auth evidence
remain product work.

Android may evolve its authorization activity into a product onboarding/status
surface, but transport access must remain separate from media/storage permission and
pairing approval. A richer launcher is not evidence that the Mac product or M1 device
matrix is complete.
