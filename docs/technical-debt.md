# Structural Debt Baseline

Last updated: 2026-07-14

This page records structural risks that are easy to hide behind feature progress.
Passing tests does not by itself mean these risks are closed.

本文记录容易被功能进度掩盖的结构性风险；测试通过不代表这些风险已经收口。

<!-- source-size-max production=mac/Sources/DroidMatchCore/AsyncTransferScheduler.swift:773 test=mac/Tests/DroidMatchCoreTests/AsyncTransferSchedulerTests.swift:751 -->
<!-- test-inventory swift=263 android-unit=157 -->

## Current Truth

| Risk | Status | Evidence |
|---|---|---|
| Large source files | **Unified budget enforced** | Every handwritten production and test Swift/Java/Kotlin file is at most 800 lines, with no exception; the largest production file is the 773-line Mac transfer scheduler and the largest test file is the 751-line Mac scheduler behavior suite. The former 2,526-line Mac frame/RPC fixture, 1,288-line multiplexer test, 1,173-line Android provider test, and 1,977-line dispatcher test are split by behavior/fixture ownership. Mac harness download and upload commands now live in separate 414/342-line files while remaining Core consumers. The Android authentication handler is 719 lines after pure limits/capability/payload policy moved to `RpcAuthenticationPolicy`; the transfer handler is 620 lines after pure wire construction/validation moved to `RpcTransferFrames`; the SAF catalog is 702 lines after MIME/flag/order/partial-name policy moved to `SafDocumentPolicy`. Scheduler request/persistence, coordinator/executor wiring, job execution event ordering, terminal-result calibration, and local-endpoint projection have explicit boundaries; the actor is 773 lines and its reusable execution probe lives with shared fixture construction. Multiplexer inbound response/stream application is grouped in a 236-line same-actor extension, leaving its lifecycle/send/transfer-admission core at 555 lines without copying route state. Product-session public values, protocols, and client seams now live in `ProductDeviceSessionContracts`, leaving the lifecycle actor at 727 lines without moving authentication or teardown state. Mixed-server lock state, framed-server readers/response values, pure transfer fixture helpers, and restored-execution readiness tests are isolated; and the product file-browser toolbar is a stateless action/state boundary. |
| Synchronous Mac networking | **Removed** | Every product and CLI operation uses the async session/router. The semaphore transport, synchronous RPC client, and implementation-specific tests are deleted; stable errors/results live in transport-independent files. |
| Single-maintainer risk | **Mitigated, not eliminated** | `AGENTS.md`, the current-state contribution guide, required PR handoff template, bilingual live docs, deterministic gates, 263 Swift tests, and 157 Android unit tests/lint reduce undocumented knowledge. CI rejects drift of takeover, physical-device, 800-line, PR-evidence, and bilingual-resource contracts. Phase A protection now requires an up-to-date PR, all three hosted skeleton checks, resolved conversations, and linear squash history on `main`; [GitHub Governance Baseline](github-governance.md) records the exact controls and the real second-maintainer Phase B. Ownership and release authority remain concentrated, so protection reduces bypass risk but cannot provide independent review. |
| Provider-specific model tooling | **Removed and guarded** | Model selection and credentials remain operator-owned; the repository ships no provider-specific routing wrapper or local credential reader. `tools/check-maintainer-contract.py` rejects the removed artifacts and provider markers before the normal M0 gate can pass. |
| macOS product App target | **Implemented; release evidence incomplete** | SwiftPM exposes a SwiftUI `DroidMatch` product with localized discovery, authentication, trusted-device revoke, browsing/transfers, persistent media-layout and opt-in privacy-bounded transfer notifications, a device-isolated queue, owner-scoped App-owned bookmark leases, ordinary/sandbox bundle assembly, and a mount-verified local DMG with checksum. Ordinary and sandboxed Slot C product authentication, browsing, bidirectional transfer, revocation, and forced-relaunch upload recovery are archived. Developer ID signing and notarization remain explicitly deferred and unverified. |
| Android product entry | **Secure onboarding and trust/authorization management implemented** | Product launcher `DroidMatchActivity` presents a tested top-level next-step summary and owns the paired-required endpoint, pairing approval, notification permission, paired-Mac list/revoke, and SAF root list/add/revoke. Static hierarchy construction is isolated in `DroidMatchScreen`, which receives action callbacks but cannot perform security-sensitive operations itself. Revoking trust closes the active USB service before it can be reused. CI assembles an unsigned release APK, verifies the product launcher, and rejects the debug harness in its merged manifest. It is not yet a local file browser or complete device-management UI. |

中文结论：生产与测试代码现已统一执行 800 行门禁；最大生产文件是 773 行的 Mac transfer scheduler，最大测试文件为 751 行的 Mac scheduler behavior suite。Mac harness 的下载/上传命令已拆成 414/342 行两个文件且仍只消费 Core。Android authentication handler 为 719 行，transfer handler 为 620 行，SAF catalog 为 702 行。scheduler 的请求/持久化、coordinator/executor 装配、job execution 事件排序、终态结果校准和本地 endpoint 投影均已有明确边界，actor 已降至 773 行；共享 execution probe 也已归入 fixture 支持文件。multiplexer 的入站 response/stream 应用现归入 236 行的同 actor extension，生命周期、发送与传输 admission 核心降至 555 行且没有复制 route 状态。产品会话的公开值、协议与 client 测试接缝现已归入 `ProductDeviceSessionContracts`，生命周期 actor 降至 727 行且认证与 teardown 状态仍由其独占；恢复执行 readiness 测试已拆入独立文件。存量巨石已按行为和 fixture 所有权拆分。单人维护风险仍只有部分治理；Mac 已接通认证会话、文件浏览、结构化诊断、持久双向队列和按认证 owner 隔离的 bookmark 租约，普通与 sandbox Slot C 产品认证、浏览、双向传输、撤销及强退后上传恢复均已有归档证据；Developer ID 签名与公证按当前决策暂缓且未验证。Android 已升级为安全连接 onboarding/status 与 SAF 授权管理入口，但完整本地文件浏览体验仍未完成。

模型选择与凭据由操作者负责，仓库不再提供 provider-specific 路由或本地凭据读取；维护者契约门禁会在 M0 前阻止其回流。

## Source-size Guardrail

`python3 tools/check-source-size.py` applies one 800-line ceiling to handwritten
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
   response assembly; `ProviderTransfers` owns stateless download/upload argument
   validation and provider selection; `ProviderUploadLeases` owns process-wide
   canonical upload-destination exclusion across sessions. The 673-line facade retains the bounded SAF
   identity cache, catalog contracts, shared lease registry, and public composition/delegation surface.
   Its legacy exception has been removed.
2. **Android RPC dispatcher (default-budget reached):**
   `RpcTransferHandler` owns open/chunk/ACK/cancel/pause routing;
   `RpcTransferFrames` owns pure protobuf/CRC/fingerprint/chunk-size policy;
   `RpcTransferRegistry` owns session-scoped handle identity and teardown;
   `RpcTransferStreams` owns ACK-bounded stream state; `RpcAuthenticationHandler`
   owns reconnect/first-pairing exchanges; and `RpcSessionState` owns provisional
   secret clearing. `RpcControlHandler` owns already-admitted control payload
   parsing/provider execution without session or socket state. The 486-line
   dispatcher now owns only envelope/session-phase/capability routing and its
   legacy exception has been removed.
3. **Mac harness commands (split complete):** the 516-line `main.swift` owns
   command dispatch and control probes; the 159-line
   `HarnessDirectoryCommands.swift` owns listing probes and privacy-bounded
   aggregate pagination; the 414-line
   `HarnessTransferCommands.swift` owns download probes; the 342-line
   `HarnessUploadCommands.swift` owns upload probes; and the small
   `HarnessCLI.swift` / `HarnessHelp.swift` files own parsing, typed failures,
   and usage text. All remain consumers of Core and no source-size exception is
   required.
4. **Mac async router (default-budget reached):** `AsyncRpcRoutingState` owns
   route records, request-ID rotation, and pure transfer/window validation. It
   owns no actor, task, waiter resolution, or socket. `AsyncRpcDeadlines` owns
   wall-clock deadline tasks without routing mutation, and
   `AsyncRpcTransferFrames` owns pure transfer protobuf construction. The
   Download-frame parsing and limit/checksum/offset validation now return an
   immutable result from the same pure boundary. Upload producer/ACK sequencing
   lives in a 118-line same-actor extension that owns no copied state;
   inbound response/stream parsing, waiter resolution, route mutation, and
   bounded-queue yield are grouped in a 236-line same-actor extension. The
   555-line core retains the only reader plus lifecycle, send admission,
   transfer admission, socket, and termination ownership. Neither extension
   copies actor state, and the legacy exception remains removed.
   `AsyncTransferSchedulerPolicy` similarly owns pure persisted-state,
   checkpoint, metadata, and resume-request decisions;
   `AsyncTransferSchedulerPersistence` owns manifest/runtime conversion, while
   `AsyncTransferSchedulerJobRunner` owns stateless executor dispatch and the
   retry/progress/terminal ordering bridge. The 773-line scheduler actor retains
   runtime queue/task/waiter/timer plus persistence-write ownership.
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
live directory browser after proof. Raw ADB, protobuf values, and credentials
remain outside the UI; network and filesystem ownership remain off MainActor.
Local DMG packaging and
lifecycle-owned transfer persistence are implemented. Ordinary and sandboxed
Slot C product authentication and transfer evidence is archived; Developer ID
signing, notarization, and release automation remain deferred product work.

Android now has a product onboarding/status summary, but transport access remains
separate from media/storage permission and pairing approval. A richer launcher is
not evidence that the Mac product or M1 device matrix is complete; local browsing
and broader device-management UI remain open product work.
